# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Sources.WordPress.ElementorTest do
  @moduledoc """
  Entries laid out with Elementor, against what the seeded WordPress answered for them
  (`elementor-pages`, `elementor-posts` and the `elementor.xml` export, recorded by
  `dev/wordpress/record_elementor.sh`): a page as the page builder's own elements, a post as the
  Blog's HTML, and the widgets the CMS has no equivalent for named, with what Elementor drew for
  them in their place. The entries' links and files are asked of the site's other recordings.

  Content is read for what it means, with LazyHTML: which elements hold which text and which
  addresses, and which of the builder's classes they carry, not its markup as a string. The
  stylesheet Elementor's global colours and fonts become (`elementor-globals`, recorded by the same
  script) is read with the CSS parser, for the tokens it declares and the fonts it loads.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0, stub!: 1, recorded: 1]

  alias MishkaCmsCore.Runtime.Authoring.{Elements, Tree}
  alias MishkaCmsCore.Runtime.Authoring.Tree.Styles
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Sources.{WordPress, WordPressFile}
  alias MishkaCmsMigration.Sources.WordPress.ElementorKit

  @connection %{"url" => "http://localhost:8089", "user" => "admin"}
  @context %{site_id: nil, run_id: nil, source_host: "localhost:8089", options: %{}}
  @export Path.expand("../../fixtures/wordpress/wxr/elementor.xml", __DIR__)
  @unsupported ["form", "google_maps", "image-carousel", "slides"]
  @uploads "http://localhost:8089/wp-content/uploads/2026/11/"
  @globals_route "/wp-json/elementor/v1/globals"
  @elementor_site %{"/wp-json/" => "elementor-index", @globals_route => "elementor-globals"}

  defp items!(kind, recording) do
    stub!(@elementor_site)
    {:ok, conn} = WordPress.connect(@connection, "app password")
    recording |> recorded() |> normalized(kind, conn)
  end

  defp exported!(kind) do
    {:ok, conn} = WordPressFile.connect(%{"file" => @export}, nil)
    {:ok, rows, nil} = WordPressFile.list(conn, kind, nil)
    normalized(rows, kind, conn)
  end

  defp normalized(rows, kind, conn),
    do:
      Map.new(rows, fn row ->
        assert {:ok, item} =
                 row |> WordPress.normalize(kind, Map.put(@context, :conn, conn)) |> built(kind)

        {item.attrs["slug"], item}
      end)

  defp built({:ok, attrs}, kind), do: attrs |> Map.put(:kind, kind) |> Item.build()

  defp html(item), do: item |> Item.html() |> LazyHTML.from_fragment()

  defp texts(html, selector),
    do: html |> LazyHTML.query(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

  defp attribute(html, selector, name),
    do: html |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

  defp classes(html, selector),
    do: html |> attribute(selector, "class") |> Enum.map(&MapSet.new(String.split(&1)))

  defp builder(id) do
    [{_tag, attrs, _children} | _] =
      id
      |> Elements.get()
      |> Map.fetch!(:template)
      |> LazyHTML.from_fragment()
      |> LazyHTML.to_tree()

    attrs
    |> List.keyfind("class", 0)
    |> elem(1)
    |> String.split()
    |> Enum.reject(&(&1 =~ "slate"))
    |> MapSet.new()
  end

  defp drawn_as?(classes, id), do: MapSet.subset?(builder(id), classes)

  defp laid_out!(elements, kind \\ "page") do
    [row] = Enum.filter(recorded("elementor-pages"), &(&1["slug"] == "elementor-landing"))
    stub!(@elementor_site)
    {:ok, conn} = WordPress.connect(@connection, "app password")

    assert {:ok, item} =
             row
             |> put_in(["meta", "_elementor_data"], JSON.encode!(elements))
             |> put_in(["content", "rendered"], "")
             |> WordPress.normalize(kind, Map.put(@context, :conn, conn))
             |> built(kind)

    item
  end

  defp widget(type, settings),
    do: %{
      "id" => "w" <> Integer.to_string(System.unique_integer([:positive])),
      "elType" => "widget",
      "widgetType" => type,
      "settings" => settings,
      "elements" => []
    }

  defp stylesheet_from_site! do
    stub!(@elementor_site)
    {:ok, conn} = WordPress.connect(@connection, "app password")
    assert {:ok, [row], nil} = WordPress.list(conn, "stylesheet", nil)
    stylesheet!(row, conn)
  end

  defp stylesheet!(row, conn) do
    assert {:ok, attrs} = WordPress.normalize(row, "stylesheet", Map.put(@context, :conn, conn))
    assert {:ok, item} = attrs |> Map.put(:kind, "stylesheet") |> Item.build()
    item
  end

  defp tokens(css) do
    assert {:ok, [theme]} = IgniterCss.get_at_rules(css, "theme")
    Map.new(theme.declarations)
  end

  defp fonts_loaded(css) do
    assert {:ok, imports} = IgniterCss.get_at_rules(css, "import")

    for %{target: url} <- imports,
        %URI{host: "fonts.googleapis.com", query: query} = URI.parse(url),
        family <- query |> URI.decode_query() |> Map.fetch!("family") |> String.split("|"),
        [name, weights] = String.split(family, ":"),
        into: %{},
        do: {name, String.split(weights, ",")}
  end

  describe "Elementor's global colours and fonts" do
    test "are read once, as the source connects, and become a stylesheet of theme tokens, each colour with a dark twin" do
      item = stylesheet_from_site!()

      assert_received {:wordpress_request, %{request_path: @globals_route}}
      refute_received {:wordpress_request, %{request_path: @globals_route}}

      assert {item.source_id, item.attrs["name"]} == {"elementor", "elementor-globals"}
      tokens = tokens(item.attrs["content"])

      for {id, %{"value" => value}} <- recorded("elementor-globals")["colors"] do
        assert tokens["--color-el-#{id}"] == String.downcase(value)
        assert tokens["--color-el-#{id}-dark"] == String.downcase(value)
      end

      for {id, %{"value" => %{"typography_font_family" => family}}} <-
            recorded("elementor-globals")["typography"] do
        assert tokens["--font-el-#{id}"] == ~s("#{family}", sans-serif)
      end

      assert fonts_loaded(item.attrs["content"]) == %{
               "Poppins" => ["400", "700"],
               "Lora" => ["400", "700"],
               "Inter" => ["400", "600", "700"]
             }
    end

    test "are not asked of a site without Elementor, which has no stylesheet to import" do
      stub!()
      {:ok, conn} = WordPress.connect(@connection, "app password")

      assert WordPress.list(conn, "stylesheet", nil) == {:ok, [], nil}
      refute_received {:wordpress_request, %{request_path: @globals_route}}
    end

    test "from an export are the same stylesheet, read from the kit it carries" do
      from_site = stylesheet_from_site!()
      {:ok, conn} = WordPressFile.connect(%{"file" => @export}, nil)

      assert {:ok, [row], nil} = WordPressFile.list(conn, "stylesheet", nil)
      assert stylesheet!(row, conn).attrs == from_site.attrs
    end

    test "of a kit that never saved them are Elementor's own, Roboto and its four colours" do
      css =
        %{}
        |> ElementorKit.from_settings()
        |> ElementorKit.stylesheet(nil)
        |> Map.fetch!("content")

      assert %{
               "--color-el-primary" => "#6ec1e4",
               "--color-el-accent-dark" => "#61ce70",
               "--font-el-secondary" => ~s("Roboto Slab", sans-serif)
             } = tokens(css)

      assert fonts_loaded(css) == %{
               "Roboto" => ["400", "500", "600", "700"],
               "Roboto Slab" => ["400", "700"]
             }
    end

    test "leave out an id, a colour or a family a stylesheet could not hold as it is" do
      globals = %{
        "colors" => %{
          "good" => %{"value" => "#ABC"},
          "rgb" => %{"value" => "rgba(0, 0, 0, 0.5)"},
          "Bad-Id" => %{"value" => "#000000"},
          "broken" => %{"value" => "red;} body { display: none"},
          "script" => %{"value" => "url(javascript:alert(1))"}
        },
        "typography" => %{
          "fine" => %{"value" => %{"typography_font_family" => "Open Sans"}},
          "quoted" => %{"value" => %{"typography_font_family" => ~s(X", serif; } a { color: red)}}
        }
      }

      css = globals |> ElementorKit.stylesheet(nil) |> Map.fetch!("content")

      assert tokens(css) |> Map.keys() |> Enum.sort() ==
               ~w(--color-el-good --color-el-good-dark --color-el-rgb --color-el-rgb-dark
                  --font-el-fine)

      assert tokens(css)["--color-el-good"] == "#abc"
      assert {:ok, [_one]} = IgniterCss.get_at_rules(css, "theme")
      assert fonts_loaded(css) == %{"Open Sans" => ["400", "700"]}
    end
  end

  describe "a page's colours" do
    test "adapt to the dark theme: the site's tokens, each with its dark twin, not slate" do
      html = html(items!("page", "elementor-pages")["elementor-landing"])
      classes = html |> attribute("[class]", "class") |> Enum.flat_map(&String.split/1)

      refute Enum.any?(classes, &(&1 =~ "slate"))
      assert "text-fg" in classes and "dark:text-fg-dark" in classes
      assert "text-dim" in classes and "dark:text-dim-dark" in classes

      for class <- classes, String.starts_with?(class, ["text-fg", "text-dim", "text-subtle"]) do
        assert ("dark:" <> class <> "-dark") in classes
      end
    end

    test "are tokens the starter's theme defines, light and dark" do
      theme = MishkaCmsCore.Install.StarterContent.theme_css()

      for token <- ~w(fg dim subtle faint brand edge page) do
        assert theme =~ "--color-#{token}-dark:"
      end
    end
  end

  describe "a page's Elementor styling, as the builder's own style settings" do
    # What the Inspector reads back from the element's classes: its per-width property overrides.
    defp styled(elements, selector) do
      elements
      |> laid_out!()
      |> html()
      |> attribute(selector, "class")
      |> hd()
      |> Styles.from_classes()
      |> then(fn {authored, styles} -> {authored, without_weight(styles)} end)
    end

    defp without_weight(styles),
      do:
        styles
        |> Map.new(fn {bucket, props} -> {bucket, Map.delete(props, "font-weight")} end)
        |> Map.reject(fn {_bucket, props} -> props == %{} end)

    defp section(settings, widgets \\ [column(%{})]),
      do: [%{"elType" => "section", "settings" => settings, "elements" => widgets}]

    defp column(settings),
      do: %{
        "elType" => "column",
        "elements" => [
          widget("heading", Map.merge(%{"title" => "T", "header_size" => "h1"}, settings))
        ]
      }

    defp box(top, bottom, unit \\ "px"),
      do: %{"unit" => unit, "top" => top, "right" => "", "bottom" => bottom, "left" => ""}

    test "gives a heading its alignment and font size, at each width, as the Inspector reads them" do
      settings = %{
        "align" => "right",
        "typography_font_size" => %{"unit" => "px", "size" => 50},
        "typography_font_size_tablet" => %{"unit" => "rem", "size" => "2.5"},
        "align_mobile" => "center"
      }

      assert {authored, styles} = styled(section(%{}, [column(settings)]), "h1")

      assert styles == %{
               base: %{"font-size" => "50px", "text-align" => "text-right"},
               tablet: %{"font-size" => "2.5rem"},
               mobile: %{"text-align" => "text-center"}
             }

      assert "text-4xl" in authored
    end

    test "leaves a heading as the builder's when its size has no CSS unit or no number" do
      for size <- [%{"unit" => "custom", "size" => 5}, %{"unit" => "px", "size" => ""}, %{}] do
        assert {_authored, styles} =
                 styled(section(%{}, [column(%{"typography_font_size" => size})]), "h1")

        assert styles == %{}
      end
    end

    test "gives a heading the theme's token for a colour the theme has, and any other through the Inspector, keeping the theme's dark twin" do
      {authored, styles} =
        styled(section(%{}, [column(%{"title_color" => "#5B4FE0"})]), "h1")

      assert "text-brand" in authored and "dark:text-brand-dark" in authored
      refute "text-fg" in authored
      assert styles == %{}

      {authored, styles} =
        styled(section(%{}, [column(%{"title_color" => "#123456"})]), "h1")

      assert styles == %{base: %{"color" => "#123456"}}
      refute "text-fg" in authored
      assert "dark:text-fg-dark" in authored
    end

    test "gives a section its padding and margin by side, in the unit Elementor has, at each width" do
      settings = %{
        "padding" => box("100", "100"),
        "padding_mobile" => box("2", "3", "rem"),
        "margin" => box("10", "")
      }

      assert {authored, styles} = styled(section(settings), "section")

      assert styles == %{
               base: %{"py" => "100px", "mt" => "10px"},
               mobile: %{"pt" => "2rem", "pb" => "3rem"}
             }

      refute "py-16" in authored
    end

    test "is the builder's own section when Elementor sets none" do
      for settings <- [%{}, %{"padding" => box("", "")}, %{"padding" => %{"unit" => "custom"}}] do
        assert {authored, styles} = styled(section(settings), "section")
        assert styles == %{} and "py-16" in authored
      end
    end

    test "gives the container its boxed width and a container its gap" do
      {_authored, styles} =
        styled(section(%{"content_width" => %{"unit" => "px", "size" => 1140}}), "section > div")

      assert styles == %{base: %{"max-width" => "1140px"}}

      container = [
        %{
          "elType" => "container",
          "settings" => %{
            "flex_direction" => "row",
            "flex_gap" => %{"column" => "40", "row" => "40", "unit" => "px"}
          },
          "elements" => [column(%{}), column(%{})]
        }
      ]

      assert {_authored, %{base: %{"gap" => "40px"}}} = styled(container, "section > div > div")
    end

    test "aligns a text editor and a button with the builder's text alignment" do
      elements = [
        %{
          "elType" => "section",
          "settings" => %{},
          "elements" => [
            %{
              "elType" => "column",
              "elements" => [
                widget("text-editor", %{"editor" => "<p>x</p>", "align" => "center"}),
                widget("button", %{"text" => "Go", "align" => "right"})
              ]
            }
          ]
        }
      ]

      html = html(laid_out!(elements))

      assert [%{base: %{"text-align" => "text-center"}}, %{base: %{"text-align" => "text-right"}}] =
               html
               |> attribute("div[class*=text-]", "class")
               |> Enum.map(&elem(Styles.from_classes(&1), 1))
    end

    test "writes no inline style, and a page the builder parses" do
      elements =
        section(%{"padding" => box("8", "8"), "margin" => box("4", "4")}, [
          column(%{
            "align" => "center",
            "typography_font_size" => %{"unit" => "px", "size" => 30}
          })
        ])

      item = laid_out!(elements)
      assert item |> html() |> LazyHTML.query("[style]") |> Enum.empty?()
      assert {:ok, %Tree{}} = item |> Item.html() |> Tree.parse()
    end
  end

  describe "a page's Elementor colours and fonts" do
    setup do
      %{page: items!("page", "elementor-pages")["elementor-landing"]}
    end

    defp look(html, selector),
      do: html |> attribute(selector, "class") |> hd() |> Styles.from_classes()

    test "name the kit's colour and font through the Inspector and its token classes, a dark twin for the dark theme",
         %{page: page} do
      html = html(page)
      {authored, styles} = look(html, "h1")

      assert styles.base["color"] == "var(--color-el-primary)"
      assert styles.base["font-weight"] == "font-bold"
      assert "dark:text-el-primary-dark" in authored and "font-el-primary" in authored
      refute "text-fg" in authored or "dark:text-fg-dark" in authored

      {authored, styles} = look(html, "a.inline-block")
      assert styles.base["background"] == "var(--color-el-accent)"
      assert "dark:bg-el-accent-dark" in authored
      refute "bg-fg" in authored or "dark:bg-fg-dark" in authored

      {authored, styles} = look(html, "section:nth-of-type(2)")
      assert styles.base["background"] == "var(--color-el-a1b2c3d)"
      assert "dark:bg-el-a1b2c3d-dark" in authored
    end

    test "give a text editor's box the colour and font its paragraphs then take", %{page: page} do
      html = html(page)

      [box] =
        html
        |> LazyHTML.query("div:has(> p strong)")
        |> Enum.map(&(&1 |> LazyHTML.attribute("class") |> hd() |> Styles.from_classes()))

      assert {authored, %{base: %{"color" => "var(--color-el-text)"} = base}} = box
      assert base["font-weight"] == "font-normal"
      assert "font-el-text" in authored and "dark:text-el-text-dark" in authored

      for paragraph <- classes(html, "div:has(> p strong) > p") do
        refute Enum.any?(paragraph, &String.starts_with?(&1, ["text-dim", "dark:text-dim"]))
        assert MapSet.subset?(MapSet.new(~w(text-base leading-relaxed)), paragraph)
      end
    end

    test "give a colour and a font of the widget's own as the Inspector's, a family the kit loads as its token",
         %{page: page} do
      {authored, styles} = page |> html() |> look("h2")

      assert styles.base["color"] == "#0f766e"
      assert styles.base["font-weight"] == "font-medium"
      assert "font-el-secondary" in authored and "dark:text-fg-dark" in authored
      refute "text-fg" in authored
    end

    test "leave the theme's own where the kit has no such colour, a family it does not load, or a gradient" do
      elements = [
        %{
          "elType" => "section",
          "settings" => %{
            "background_background" => "gradient",
            "background_color" => "#000000"
          },
          "elements" => [
            %{
              "elType" => "column",
              "elements" => [
                widget("heading", %{
                  "title" => "T",
                  "header_size" => "h1",
                  "typography_font_family" => "Comic Neue",
                  "__globals__" => %{"title_color" => "globals/colors?id=gone"}
                })
              ]
            }
          ]
        }
      ]

      html = elements |> laid_out!() |> html()
      {authored, styles} = look(html, "h1")

      assert "text-fg" in authored and "dark:text-fg-dark" in authored
      refute Map.has_key?(styles.base, "color")
      refute Enum.any?(authored, &String.starts_with?(&1, "font-el-"))
      assert look(html, "section") == {["py-16"], %{}}
    end

    test "give a section's colour of its own the page's colour in the dark theme" do
      elements = [
        %{
          "elType" => "section",
          "settings" => %{"background_background" => "classic", "background_color" => "#F5F5F5"},
          "elements" => [%{"elType" => "column", "elements" => [widget("spacer", %{})]}]
        }
      ]

      assert {authored, %{base: %{"background" => "#f5f5f5"}}} =
               elements |> laid_out!() |> html() |> look("section")

      assert "dark:bg-page-dark" in authored
    end

    test "give a font's weight, size, line height, letter spacing and case at each width" do
      settings = %{
        "title" => "T",
        "header_size" => "h2",
        "typography_typography" => "custom",
        "typography_font_weight" => "300",
        "typography_font_size_mobile" => %{"unit" => "px", "size" => 20},
        "typography_line_height" => %{"unit" => "em", "size" => 1.2},
        "typography_letter_spacing_tablet" => %{"unit" => "px", "size" => 2},
        "typography_text_transform" => "uppercase"
      }

      assert {_authored, styles} =
               [widget("heading", settings)] |> laid_out!() |> html() |> look("h2")

      assert styles == %{
               base: %{
                 "font-weight" => "font-light",
                 "line-height" => "1.2em",
                 "text-transform" => "uppercase"
               },
               tablet: %{"letter-spacing" => "2px"},
               mobile: %{"font-size" => "20px"}
             }
    end

    test "give a text editor's own size and line height to its box, its paragraphs taking them" do
      html =
        [
          widget("text-editor", %{
            "editor" => "<p>One</p><p>Two</p>",
            "typography_font_size" => %{"unit" => "px", "size" => 18},
            "typography_line_height" => %{"unit" => "em", "size" => 1.8}
          })
        ]
        |> laid_out!()
        |> html()

      assert {[], %{base: %{"font-size" => "18px", "line-height" => "1.8em"}}} =
               look(html, "div:has(> p)")

      for paragraph <- classes(html, "div > p") do
        refute MapSet.member?(paragraph, "text-base") or
                 MapSet.member?(paragraph, "leading-relaxed")

        assert MapSet.member?(paragraph, "text-dim")
      end
    end

    test "are not in a post, which is the Blog's HTML" do
      heading =
        widget("heading", %{
          "title" => "T",
          "__globals__" => %{
            "title_color" => "globals/colors?id=primary",
            "typography_typography" => "globals/typography?id=primary"
          }
        })

      assert [heading] |> laid_out!("post") |> html() |> attribute("[class]", "class") == []
    end
  end

  describe "a page laid out with sections" do
    setup do
      %{page: items!("page", "elementor-pages")["elementor-landing"]}
    end

    test "is the page builder's sections, columns and stacks, an inner section inside its own", %{
      page: page
    } do
      html = html(page)

      assert html
             |> LazyHTML.query("body > section, section:not(section section)")
             |> Enum.count() == 3

      assert Enum.all?(classes(html, "section"), &drawn_as?(&1, "el-section"))
      assert Enum.all?(classes(html, "section > div"), &drawn_as?(&1, "el-container"))

      assert texts(html, ".md\\:grid-cols-2 > div > h2") == ["What comes across"]
      assert texts(html, "section .md\\:grid-cols-2 h3") == ["Before", "After"]
      assert html |> LazyHTML.query("section section") |> Enum.empty?()

      assert {:ok, %Tree{}} = page |> Item.html() |> Tree.parse()
      assert page.content |> Enum.reject(& &1.html) == []
      refute Map.has_key?(page.attrs, "unsupported_widgets")
    end

    test "draws its headings, text, button and HTML as the builder's elements for them", %{
      page: page
    } do
      html = html(page)

      assert [h1] = classes(html, "h1")
      assert drawn_as?(h1, "el-h1") and MapSet.member?(h1, "text-center")
      assert texts(html, "h1") == ["Move your WordPress site to Mishka CMS"]

      assert Enum.all?(
               classes(html, "section div > p:not(.note)"),
               &drawn_as?(&1, "el-paragraph")
             )

      assert texts(html, "p strong") == ["bold"]

      assert [button] =
               html |> LazyHTML.query("a") |> Enum.filter(&(LazyHTML.text(&1) =~ "Contact us"))

      assert button |> LazyHTML.attribute("href") == ["http://localhost:8089/contact/"]

      assert button
             |> LazyHTML.attribute("class")
             |> hd()
             |> String.split()
             |> MapSet.new()
             |> drawn_as?("el-submit")

      assert texts(html, "p.note") == ["The same page in Mishka CMS, open in its page builder."]
      assert attribute(html, "h3 > a", "href") == ["http://localhost:8089/docs/getting-started/"]
    end

    test "draws its image, list, video, divider and spacer as the builder's elements for them", %{
      page: page
    } do
      html = html(page)

      assert [figure] = Enum.to_list(LazyHTML.query(html, "figure:has(figcaption)"))
      assert attribute(figure, "a > img", "src") == [@uploads <> "hero.jpg"]
      assert attribute(figure, "a", "href") == [@uploads <> "hero.jpg"]
      assert attribute(figure, "img", "alt") == ["A blue gradient hero image with a white circle"]
      assert texts(figure, "figcaption") == ["The hero image, from the media library"]

      assert texts(html, "ul > li") ==
               ["Pages and their layout", "Posts, categories and tags", "Read the documentation"]

      assert attribute(html, "ul > li > a", "href") ==
               ["http://localhost:8089/blog/", "http://localhost:8089/docs/"]

      assert attribute(html, "iframe", "src") == [
               "https://www.youtube-nocookie.com/embed/jNQXAC9IVRw"
             ]

      assert [hr] = classes(html, "hr")
      assert drawn_as?(hr, "el-divider")
      assert [spacer] = classes(html, "div.h-16")
      assert drawn_as?(spacer, "el-spacer")
    end

    test "names its links to the site's pages and posts, and its files, for the target to rewrite",
         %{
           page: page
         } do
      assert Map.keys(page.attrs["pages"]) |> Enum.sort() ==
               Enum.sort([
                 "http://localhost:8089/about/",
                 "http://localhost:8089/blog/",
                 "http://localhost:8089/contact/",
                 "http://localhost:8089/docs/",
                 "http://localhost:8089/docs/getting-started/"
               ])

      assert page.attrs["links"] == %{
               "http://localhost:8089/2026/01/welcome-to-the-mishka-test-blog/" =>
                 "welcome-to-the-mishka-test-blog"
             }

      media = Map.new(recorded("media"), &{&1["slug"], &1["id"]})

      assert page.attrs["media"] == %{
               (@uploads <> "hero.jpg") => media["hero"],
               (@uploads <> "diagram.png") => media["diagram"]
             }
    end
  end

  describe "a page with widgets the CMS has no equivalent for" do
    setup do
      %{page: items!("page", "elementor-pages")["elementor-contact"]}
    end

    test "names them once each, in the order they come, and those Elementor drew nothing for", %{
      page: page
    } do
      assert page.attrs["unsupported_widgets"] == @unsupported
      assert page.attrs["no_fallback_widgets"] == ["form", "slides"]
    end

    test "has what Elementor drew for them in their place, without its classes, data, scripts or icons",
         %{page: page} do
      html = html(page)

      assert [map] = attribute(html, "iframe", "src")
      assert map =~ "maps.google.com/maps?q=Azadi"

      assert html |> attribute("img", "src") |> Enum.map(&Path.basename/1) ==
               ["gallery-1-150x150.jpg", "gallery-2-150x150.jpg", "gallery-3-150x150.jpg"]

      assert html
             |> LazyHTML.query("[data-id], [data-settings], script, svg, [srcset], [style]")
             |> Enum.empty?()

      refute html |> attribute("[class]", "class") |> Enum.any?(&(&1 =~ ~r/elementor|swiper/))
      assert texts(html, "h1") == ["Talk to us"]
    end
  end

  describe "a post laid out with containers" do
    setup do
      %{post: items!("post", "elementor-posts")["elementor-release-notes"]}
    end

    test "is the Blog's HTML: its columns as a grid, and none of the builder's classes", %{
      post: post
    } do
      html = html(post)

      assert attribute(html, "[class]", "class") == ["grid gap-6 md:grid-cols-3"]
      assert texts(html, ".md\\:grid-cols-3 > div > h3") == ["Faster", "Safer", "Easier"]
      assert texts(html, "h2") == ["What is new in 1.2"]
      assert html |> LazyHTML.query("section") |> Enum.empty?()
    end

    test "draws its gallery, videos, button, divider and shortcode, and no spacer", %{post: post} do
      html = html(post)

      assert html |> attribute("figure > figure > a > img", "src") |> Enum.map(&Path.basename/1) ==
               ["gallery-1.jpg", "gallery-2.jpg", "gallery-3.jpg"]

      assert attribute(html, "figure > figure > a", "href") ==
               Enum.map(~w(gallery-1.jpg gallery-2.jpg gallery-3.jpg), &(@uploads <> &1))

      assert attribute(html, "iframe", "src") == ["https://player.vimeo.com/video/76979871"]
      assert attribute(html, "video", "src") == [@uploads <> "sample.mp4"]
      assert attribute(html, "p > a[target=_blank]", "href") == [@uploads <> "guide.pdf"]
      assert texts(html, "p > a[target=_blank]") == ["Get the guide"]
      assert html |> LazyHTML.query("hr") |> Enum.count() == 1
      assert texts(html, "figure > figcaption") == ["The cover image"]
      assert html |> LazyHTML.query("div:empty") |> Enum.empty?()
      refute Map.has_key?(post.attrs, "unsupported_widgets")
    end
  end

  describe "a video widget" do
    test "whose address was cleared draws no video, and one never set draws Elementor's demo" do
      cleared =
        for {type, key} <- [
              {"youtube", "youtube_url"},
              {"vimeo", "vimeo_url"},
              {"dailymotion", "dailymotion_url"},
              {"videopress", "videopress_url"}
            ],
            value <- ["", nil, "  "],
            do: widget("video", %{"video_type" => type, key => value})

      assert cleared
             |> laid_out!()
             |> html()
             |> LazyHTML.query("iframe, video, a")
             |> Enum.empty?()

      assert [widget("video", %{})] |> laid_out!() |> html() |> attribute("iframe", "src") ==
               ["https://www.youtube-nocookie.com/embed/XHOmBV4js_E"]

      assert [widget("video", %{"video_type" => "vimeo"})]
             |> laid_out!()
             |> html()
             |> attribute("iframe", "src") == ["https://player.vimeo.com/video/235215203"]
    end
  end

  describe "a grid" do
    test "has 1 to 12 columns, so its class is always one Tailwind has" do
      image = %{"id" => "6", "url" => @uploads <> "gallery-1.jpg"}

      galleries =
        for columns <- ["20", "0", "-3", "abc", "3"],
            do: widget("image-gallery", %{"wp_gallery" => [image], "gallery_columns" => columns})

      row = %{
        "id" => "r000001",
        "elType" => "container",
        "settings" => %{"flex_direction" => "row"},
        "elements" => for(n <- 1..14, do: widget("heading", %{"title" => "H#{n}"}))
      }

      classes =
        (galleries ++ [row]) |> laid_out!() |> html() |> attribute("[class*=grid-cols]", "class")

      assert Enum.map(classes, &(&1 |> String.split() |> List.last())) == [
               "md:grid-cols-12",
               "md:grid-cols-1",
               "md:grid-cols-1",
               "md:grid-cols-4",
               "md:grid-cols-3",
               "md:grid-cols-12"
             ]
    end
  end

  describe "an unsafe address" do
    test "javascript:, vbscript: and data: but an image's are dropped from every link and source" do
      html =
        [
          widget("heading", %{"title" => "Heading", "link" => %{"url" => "javascript:alert(1)"}}),
          widget("button", %{"text" => "Button", "link" => %{"url" => " JaVaScRiPt:alert(1)"}}),
          widget("image", %{
            "image" => %{"url" => "data:image/png;base64,iVBORw0KGgo="},
            "link_to" => "custom",
            "link" => %{"url" => "vbscript:msgbox(1)"}
          }),
          widget("icon-list", %{
            "icon_list" => [%{"text" => "Item", "link" => %{"url" => "data:text/html,<b>x</b>"}}]
          }),
          widget("text-editor", %{
            "editor" => ~s|<p><a href="java\tscript:alert(1)">t</a><img src="javascript:x"></p>|
          }),
          widget("video", %{
            "video_type" => "hosted",
            "hosted_url" => %{"url" => "javascript:alert(1)"}
          }),
          widget("html", %{
            "html" => ~s(<iframe src="data:text/html,x"></iframe><a href="/ok">ok</a>)
          })
        ]
        |> laid_out!()
        |> html()

      addresses = attribute(html, "[href]", "href") ++ attribute(html, "[src]", "src")

      assert addresses == ["/ok", "data:image/png;base64,iVBORw0KGgo="]
      assert texts(html, "h2") == ["Heading"]
      assert html |> LazyHTML.query("a") |> Enum.map(&LazyHTML.text/1) |> Enum.member?("Button")
    end
  end

  describe "Elementor's own meta" do
    test "is left out of extra, so an entry Elementor could lay out reads as it did before Elementor" do
      [row | _] = recorded("pages")
      stub!()
      {:ok, conn} = WordPress.connect(@connection, "app password")
      context = Map.put(@context, :conn, conn)

      with_elementor =
        update_in(
          row,
          ["meta"],
          &Map.merge(&1, %{
            "_elementor_edit_mode" => "",
            "_elementor_template_type" => "",
            "_elementor_data" => "",
            "_elementor_page_settings" => nil
          })
        )

      assert {:ok, before} = row |> WordPress.normalize("page", context) |> built("page")
      assert {:ok, now} = with_elementor |> WordPress.normalize("page", context) |> built("page")
      assert Item.hash(now) == Item.hash(before)

      page = items!("page", "elementor-pages")["elementor-landing"]

      refute page.extra["meta"]
             |> Map.keys()
             |> Enum.any?(&String.starts_with?(&1, "_elementor_"))
    end

    test "that marks no layout, or one that is not JSON, leaves the entry to the HTML Elementor keeps" do
      [row] = Enum.filter(recorded("elementor-pages"), &(&1["slug"] == "elementor-landing"))
      stub!()
      {:ok, conn} = WordPress.connect(@connection, "app password")
      context = Map.put(@context, :conn, conn)

      for meta <- [%{"_elementor_edit_mode" => ""}, %{"_elementor_data" => "not json"}] do
        assert {:ok, item} =
                 row
                 |> update_in(["meta"], &Map.merge(&1, meta))
                 |> WordPress.normalize("page", context)
                 |> built("page")

        html = html(item)
        assert texts(html, "h1") == ["Move your WordPress site to Mishka CMS"]
        assert html |> LazyHTML.query("section, [class]") |> Enum.empty?()
        refute Map.has_key?(item.attrs, "unsupported_widgets")
      end
    end
  end

  describe "an export" do
    test "lays out the same entries, and names the widgets it cannot draw with no fallback in their place" do
      pages = exported!("page")
      from_site = items!("page", "elementor-pages")

      assert texts(html(pages["elementor-landing"]), "h1, h2, h3, li") ==
               texts(html(from_site["elementor-landing"]), "h1, h2, h3, li")

      contact = pages["elementor-contact"]
      assert contact.attrs["unsupported_widgets"] == @unsupported
      assert contact.attrs["no_fallback_widgets"] == @unsupported
      assert html(contact) |> LazyHTML.query("iframe, img") |> Enum.empty?()
      assert texts(html(contact), "h1") == ["Talk to us"]

      assert texts(html(exported!("post")["elementor-release-notes"]), ".md\\:grid-cols-3 h3") ==
               ["Faster", "Safer", "Easier"]

      assert classes(html(pages["elementor-landing"]), "[class]") ==
               classes(html(from_site["elementor-landing"]), "[class]")
    end
  end
end
