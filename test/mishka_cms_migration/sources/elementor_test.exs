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
  addresses, and which of the builder's classes they carry, not its markup as a string.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0, recorded: 1]

  alias MishkaCmsCore.Runtime.Authoring.{Elements, Tree}
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Sources.{WordPress, WordPressFile}

  @connection %{"url" => "http://localhost:8089", "user" => "admin"}
  @context %{site_id: nil, run_id: nil, source_host: "localhost:8089", options: %{}}
  @export Path.expand("../../fixtures/wordpress/wxr/elementor.xml", __DIR__)
  @unsupported ["form", "google_maps", "image-carousel", "slides"]
  @uploads "http://localhost:8089/wp-content/uploads/2026/11/"

  defp items!(kind, recording) do
    stub!()
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

    attrs |> List.keyfind("class", 0) |> elem(1) |> String.split() |> MapSet.new()
  end

  defp drawn_as?(classes, id), do: MapSet.subset?(builder(id), classes)

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

    test "names them once each, in the order they come", %{page: page} do
      assert page.attrs["unsupported_widgets"] == @unsupported
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
      assert html(contact) |> LazyHTML.query("iframe, img") |> Enum.empty?()
      assert texts(html(contact), "h1") == ["Talk to us"]

      assert texts(html(exported!("post")["elementor-release-notes"]), ".md\\:grid-cols-3 h3") ==
               ["Faster", "Safer", "Easier"]
    end
  end
end
