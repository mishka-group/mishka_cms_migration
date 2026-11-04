# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Sources.WordPress.Elementor do
  @moduledoc """
  A WordPress page or post laid out with Elementor as its item's content pieces
  (`MishkaCmsMigration.Source.Item`), and the widgets in it the CMS has no equivalent for.

  Elementor keeps an entry's layout as JSON in its `_elementor_data` meta, and marks an entry it
  lays out with the `_elementor_edit_mode` meta `"builder"`. The REST API answers both from
  Elementor 3.27 on, and an export carries them. `call/3` reads an entry so marked whose data is a
  list of elements. Any other entry is `:none`, and so is one whose data is not JSON: it is read
  from its `content` (`MishkaCmsMigration.Sources.WordPress.Content`), where Elementor keeps a rough
  HTML fallback of the layout. A site on an older Elementor answers no data over the REST API, so
  its Elementor entries are read from that fallback; its export carries the data.

  The data is a tree of elements: sections holding columns, and containers (Elementor 3.6 on)
  holding containers, each holding widgets. A section or a container at the top is drawn across the
  page; one nested in another (`"isInner"`) is drawn inside it.

  ## A page

  A page is laid out with the plain HTML the CMS's page builder places
  (`MishkaCmsCore.Runtime.Authoring.Elements`), each element with the builder's own classes, so it
  opens in the builder as though it had been built there:

    * a section or a container at the top — a Section, holding a Container (centred and width
      capped) unless it is full width;
    * the columns of a section, and the children of a container laid out in a row — a grid with a
      column for each, side by side from the `md` width, as the builder's 2, 3 and 4 columns are;
      one column alone, and the children of a container laid out in a column — a Stack, one under
      the next;
    * a heading — the H1 to H6 its size names (H2 by default; a paragraph for a `div`, `span` or
      `p`), linked when it links, centred, right-aligned or justified as it is;
    * a text editor — its HTML in a box, converted as classic content is (paragraphs, shortcodes,
      a YouTube or Vimeo address alone on its line);
    * an image — an Image, or a Figure with its caption (its own, or its file's), linked to its
      file or to its own address;
    * a button — a link drawn as the builder's button, centred or right-aligned as it is;
    * a video — the player of a YouTube or Vimeo video
      (`MishkaCmsMigration.Sources.WordPress.Content.embed/1`), a link to a Dailymotion or
      VideoPress one, and a `<video>` of a file the site hosts or of another address;
    * an icon list — a Bulleted list, each item linked when it links, without its icons;
    * an image gallery, and Elementor Pro's gallery — a grid of as many columns as it has, of
      Figures each linked to its file or to its attachment page;
    * a spacer — a Spacer, and a divider a Divider;
    * HTML — the author's markup as it is;
    * a shortcode — its shortcodes, converted as classic content's are.

  The paragraphs, lists, quotes, links, images, figures and rules of these take the classes of the
  builder's element of the same tag (Paragraph, Bulleted list, Link, ...).

  ## A post

  A post is the Blog's HTML, as a post written in the block editor is: the same elements without
  the builder's classes, Sections or Stacks, the columns of a grid as
  `<div class="grid gap-6 md:grid-cols-N">`, a gallery as a `<figure>` of figures, a button as a
  link in a paragraph, and no spacer.

  ## Widgets the CMS has no equivalent for

  Any other widget, such as Elementor Pro's form or slides, an image carousel or a map, and an
  element of another kind (Elementor 4's atomic elements), stands in its place as what Elementor
  drew for it: its part of the entry's `content.rendered`, found by its `data-id`, without classes,
  styles, `data-` attributes, the `srcset` of other sizes, scripts and decorative (`aria-hidden`)
  parts. Its name (`widgetType`, or the element's `elType`) is among the names `call/3` answers,
  each once, in the order they come, for the target to ask an admin before it writes the fallback
  (`MishkaCmsMigration.Targets.Helpers.Widgets`). An export carries no rendering, so such a widget
  read from an export has no fallback, and nothing stands in its place.

  The images of the image and gallery widgets are read from WordPress with `fetch`
  (`/wp/v2/media`), all in one request, for their alt text, caption and attachment page.
  """

  alias MishkaCmsCore.Runtime.Authoring.Elements
  alias MishkaCmsMigration.Sources.WordPress.Content

  @widgets ~w(heading text-editor image button video icon-list image-gallery gallery spacer divider
              html shortcode)
  @styled_widgets ~w(text-editor image video icon-list image-gallery gallery divider shortcode)
  @layouts ["section", "column", "container"]
  @galleries ["image-gallery", "gallery"]
  @headings ~w(h1 h2 h3 h4 h5 h6)
  @rows ["row", "row-reverse"]
  @aligned %{"center" => "text-center", "right" => "text-right", "justify" => "text-justify"}
  @element_id ~r/\A[\w-]+\z/
  @dropped_attrs ~w(class style srcset sizes loading decoding fetchpriority)
  @not_kept ["script", "style", "noscript"]

  @videos %{
    "youtube" => {"youtube_url", "https://www.youtube.com/watch?v=XHOmBV4js_E"},
    "vimeo" => {"vimeo_url", "https://vimeo.com/235215203"},
    "dailymotion" => {"dailymotion_url", "https://www.dailymotion.com/video/x6tqhqb"},
    "videopress" => {"videopress_url", "https://videopress.com/v/ZCAOzTNk"}
  }

  @elements ~w(el-section el-container el-stack el-spacer el-submit el-h1 el-h2 el-h3 el-h4 el-h5
               el-h6 el-paragraph el-link el-list el-list-ordered el-quote el-image el-figure
               el-divider)
            |> Map.new(fn id ->
              {id,
               id
               |> Elements.get()
               |> Map.fetch!(:template)
               |> LazyHTML.from_fragment()
               |> LazyHTML.to_tree()
               |> hd()}
            end)

  @styles ~w(el-h1 el-h2 el-h3 el-h4 el-h5 el-h6 el-paragraph el-link el-list el-list-ordered
             el-quote el-image el-figure el-divider)
          |> Enum.map(&Map.fetch!(@elements, &1))
          |> LazyHTML.Tree.postwalk(%{}, fn
            {tag, attrs, _children} = node, styles ->
              {node,
               Enum.reduce(attrs, styles, fn
                 {"class", class}, styles -> Map.put_new(styles, tag, class)
                 _attr, styles -> styles
               end)}

            node, styles ->
              {node, styles}
          end)
          |> elem(1)

  @button "inline-block " <>
            (@elements
             |> Map.fetch!("el-submit")
             |> elem(1)
             |> List.keyfind("class", 0)
             |> elem(1))

  @doc """
  The content pieces of `row`, an entry Elementor laid out, made as a `kind` (`"page"` or
  `"post"`) is, and the names of the widgets in it the CMS has no equivalent for, reading its images
  with `fetch`; `:none` for an entry Elementor did not lay out.
  """
  @spec call(map(), String.t(), Content.fetch()) :: {:ok, [map()], [String.t()]} | :none
  def call(
        %{"meta" => %{"_elementor_edit_mode" => "builder", "_elementor_data" => data}} = row,
        kind,
        fetch
      )
      when is_binary(data),
      do: data |> JSON.decode() |> laid_out(row, kind, fetch)

  def call(_row, _kind, _fetch), do: :none

  defp laid_out({:ok, [_ | _] = elements}, row, kind, fetch) do
    found = Enum.reduce(elements, %{media: [], unsupported: []}, &found/2)
    unsupported = Enum.reverse(found.unsupported)

    ctx = %{
      kind: kind,
      fetch: fetch,
      media: media(found.media, fetch),
      fallbacks: fallbacks(row, unsupported)
    }

    {:ok, elements |> Enum.flat_map(&element(&1, ctx)) |> Content.pieces(),
     unsupported |> Enum.map(&elem(&1, 1)) |> Enum.uniq()}
  end

  defp laid_out(_no_layout, _row, _kind, _fetch), do: :none

  defp found(%{"elType" => type, "elements" => children}, found)
       when type in @layouts and is_list(children),
       do: Enum.reduce(children, found, &found/2)

  defp found(%{"elType" => "widget", "widgetType" => type} = widget, found)
       when type in @widgets,
       do: %{found | media: images(type, settings(widget)) ++ found.media}

  defp found(%{"elType" => _type} = element, found),
    do: %{found | unsupported: [{element["id"], name(element)} | found.unsupported]}

  defp found(_unreadable, found), do: found

  defp name(%{"elType" => "widget", "widgetType" => type}) when is_binary(type), do: type
  defp name(%{"elType" => type}) when is_binary(type), do: type
  defp name(_element), do: "widget"

  defp images("image", %{"image" => image}), do: image |> media_id() |> List.wrap()

  defp images(type, settings) when type in @galleries,
    do: settings |> gallery() |> Enum.flat_map(&List.wrap(media_id(&1)))

  defp images(_type, _settings), do: []

  defp media([], _fetch), do: %{}
  defp media(ids, fetch), do: fetch.("/wp/v2/media", Enum.uniq(ids))

  defp fallbacks(%{"content" => %{"rendered" => html}}, [_ | _] = unsupported)
       when is_binary(html) do
    rendered = LazyHTML.from_fragment(html)

    for {id, _name} <- unsupported,
        is_binary(id) and Regex.match?(@element_id, id),
        into: %{},
        do: {id, rendered |> LazyHTML.query(~s([data-id="#{id}"])) |> fallback()}
  end

  defp fallbacks(_row, _unsupported), do: %{}

  defp fallback(drawn),
    do: drawn |> LazyHTML.child_nodes() |> LazyHTML.to_tree() |> LazyHTML.Tree.postwalk(&kept/1)

  defp kept({tag, _attrs, _children}) when tag in @not_kept, do: []

  defp kept({tag, attrs, children}),
    do: kept({"aria-hidden", "true"} in attrs, {tag, Enum.reject(attrs, &dropped?/1), children})

  defp kept({:comment, _text}), do: []
  defp kept(text), do: text

  defp kept(true, _decorative), do: []
  defp kept(false, node), do: node

  defp dropped?({"data-" <> _name, _value}), do: true
  defp dropped?({name, _value}), do: name in @dropped_attrs

  defp element(%{"elType" => "section", "elements" => columns} = section, ctx)
       when is_list(columns),
       do: columns |> cells(ctx) |> side_by_side(ctx) |> placed(section, ctx)

  defp element(%{"elType" => "column", "elements" => widgets}, ctx) when is_list(widgets),
    do: Enum.flat_map(widgets, &element(&1, ctx))

  defp element(%{"elType" => "container", "elements" => children} = container, ctx)
       when is_list(children),
       do:
         container
         |> settings()
         |> Map.get("flex_direction")
         |> flexed(cells(children, ctx), ctx)
         |> placed(container, ctx)

  defp element(%{"elType" => "widget", "widgetType" => type} = widget, ctx)
       when type in @widgets,
       do: type |> widget(settings(widget), ctx) |> styled(type, ctx)

  defp element(%{"elType" => _type} = element, ctx),
    do: Map.get(ctx.fallbacks, element["id"], [])

  defp element(_unreadable, _ctx), do: []

  defp settings(%{"settings" => %{} = settings}), do: settings
  defp settings(_element), do: %{}

  defp cells(elements, ctx),
    do: elements |> Enum.map(&element(&1, ctx)) |> Enum.reject(&(&1 == []))

  defp flexed(direction, cells, ctx) when direction in @rows, do: side_by_side(cells, ctx)
  defp flexed(_column, cells, ctx), do: cells |> Enum.concat() |> stack(ctx)

  defp side_by_side([], _ctx), do: []
  defp side_by_side([cell], ctx), do: stack(cell, ctx)

  defp side_by_side(cells, ctx),
    do: [
      {"div", [{"class", "grid gap-6 md:grid-cols-#{length(cells)}"}],
       Enum.map(cells, &cell(&1, ctx))}
    ]

  defp cell([{_tag, _attrs, _children} = one], _ctx), do: one
  defp cell(nodes, %{kind: "page"}), do: built("el-stack", [], nodes)
  defp cell(nodes, _post), do: {"div", [], nodes}

  defp stack([], _ctx), do: []
  defp stack(nodes, %{kind: "page"}), do: [built("el-stack", [], nodes)]
  defp stack(nodes, _post), do: nodes

  defp placed(nodes, %{"isInner" => true}, _ctx), do: nodes
  defp placed([], _element, _ctx), do: []

  defp placed(nodes, element, %{kind: "page"}),
    do: [built("el-section", [], element |> settings() |> boxed(nodes))]

  defp placed(nodes, _element, _post), do: nodes

  defp boxed(%{"layout" => "full_width"}, nodes), do: nodes
  defp boxed(%{"content_width" => "full"}, nodes), do: nodes
  defp boxed(_boxed, nodes), do: [built("el-container", [], nodes)]

  defp built(id, attributes, children) do
    {tag, own, _placeholder} = Map.fetch!(@elements, id)
    {tag, attributes ++ [List.keyfind(own, "class", 0)], children}
  end

  defp styled(nodes, type, %{kind: "page"}) when type in @styled_widgets,
    do: LazyHTML.Tree.postwalk(nodes, &style/1)

  defp styled(nodes, _type, _ctx), do: nodes

  defp style({tag, attrs, children}) when is_map_key(@styles, tag),
    do: {tag, classed(attrs, List.keymember?(attrs, "class", 0), tag), children}

  defp style(node), do: node

  defp classed(attrs, true, _tag), do: attrs
  defp classed(attrs, false, tag), do: attrs ++ [{"class", Map.fetch!(@styles, tag)}]

  defp widget("heading", %{"title" => title} = settings, ctx)
       when is_binary(title) and title != "" do
    tag = heading(settings["header_size"])

    [
      heading_tag(
        tag,
        title |> fragment() |> linked(settings["link"]),
        aligned(settings["align"]),
        ctx
      )
    ]
  end

  defp widget("text-editor", %{"editor" => html}, ctx) when is_binary(html),
    do: html |> Content.nodes(ctx.fetch) |> boxed_text(ctx)

  defp widget("image", %{"image" => %{"url" => url} = image} = settings, ctx)
       when is_binary(url) and url != "" do
    file = Map.get(ctx.media, media_id(image))

    [{"img", [{"src", url}, {"alt", alt(image, file)}], []}]
    |> linked(image_link(settings, url))
    |> captioned(caption(settings, file))
  end

  defp widget("button", settings, ctx),
    do:
      settings["link"]
      |> link_attributes()
      |> button(
        settings["text"] |> text("Click here") |> fragment(),
        aligned(settings["align"]),
        ctx
      )

  defp widget("video", settings, _ctx), do: settings |> video() |> played()

  defp widget("icon-list", %{"icon_list" => [_ | _] = items}, _ctx),
    do: [
      {"ul", [],
       for(
         %{"text" => text} = item <- items,
         is_binary(text),
         do: {"li", [], text |> fragment() |> linked(item["link"])}
       )}
    ]

  defp widget(type, settings, ctx) when type in @galleries,
    do:
      settings
      |> gallery()
      |> Enum.flat_map(&figure(&1, gallery_link(settings), ctx))
      |> laid(settings, ctx)

  defp widget("spacer", _settings, %{kind: "page"}), do: [built("el-spacer", [], [])]
  defp widget("divider", _settings, _ctx), do: [{"hr", [], []}]

  defp widget("html", %{"html" => html}, _ctx) when is_binary(html),
    do: html |> fragment() |> LazyHTML.Tree.postwalk(&uncommented/1)

  defp widget("shortcode", %{"shortcode" => text}, ctx) when is_binary(text),
    do: Content.nodes(text, ctx.fetch)

  defp widget(_type, _settings, _ctx), do: []

  defp heading(size) when size in @headings, do: size
  defp heading(size) when size in ["div", "span", "p"], do: "p"
  defp heading(_default), do: "h2"

  defp heading_tag(tag, children, classes, %{kind: "page"}),
    do: {tag, [{"class", Enum.join([Map.fetch!(@styles, tag) | classes], " ")}], children}

  defp heading_tag(tag, children, _classes, _post), do: {tag, [], children}

  defp aligned(align) when is_map_key(@aligned, align), do: [Map.fetch!(@aligned, align)]
  defp aligned(_start), do: []

  defp boxed_text(nodes, %{kind: "page"}), do: [{"div", [], nodes}]
  defp boxed_text(nodes, _post), do: nodes

  defp button(href, label, aligned, %{kind: "page"}),
    do: aligned_button({"a", href ++ [{"class", @button}], label}, aligned)

  defp button(href, label, _aligned, _post), do: [{"p", [], [{"a", href, label}]}]

  defp aligned_button(a, []), do: [a]
  defp aligned_button(a, classes), do: [{"div", [{"class", Enum.join(classes, " ")}], [a]}]

  defp linked(nodes, link), do: link |> link_attributes() |> linked_to(nodes)

  defp linked_to([], nodes), do: nodes
  defp linked_to(href, nodes), do: [{"a", href, nodes}]

  defp link_attributes(%{"url" => url} = link) when is_binary(url) and url != "",
    do:
      [{"href", url}] ++
        opened(link["is_external"]) ++ followed(link["nofollow"])

  defp link_attributes(_no_link), do: []

  defp opened("on"), do: [{"target", "_blank"}]
  defp opened(_same_tab), do: []

  defp followed("on"), do: [{"rel", "nofollow"}]
  defp followed(_followed), do: []

  defp image_link(%{"link_to" => "file"}, url), do: %{"url" => url}
  defp image_link(%{"link_to" => "custom", "link" => link}, _url), do: link
  defp image_link(_settings, _url), do: nil

  defp caption(%{"caption_source" => "custom", "caption" => caption}, _file)
       when is_binary(caption),
       do: caption

  defp caption(%{"caption_source" => "attachment"}, %{"caption" => %{"raw" => caption}})
       when is_binary(caption),
       do: caption

  defp caption(_settings, _file), do: nil

  defp captioned(nodes, caption) when is_binary(caption) and caption != "",
    do: [{"figure", [], nodes ++ [{"figcaption", [], fragment(caption)}]}]

  defp captioned(nodes, _no_caption), do: nodes

  defp alt(%{"alt" => alt}, _file) when is_binary(alt) and alt != "", do: alt
  defp alt(_image, %{"alt_text" => alt}) when is_binary(alt), do: alt
  defp alt(_image, _file), do: ""

  defp media_id(%{"id" => id}) when is_integer(id) and id > 0, do: id

  defp media_id(%{"id" => id}) when is_binary(id), do: id |> Integer.parse() |> whole()

  defp media_id(_none), do: nil

  defp gallery(%{"wp_gallery" => images}) when is_list(images), do: images
  defp gallery(%{"gallery" => images}) when is_list(images), do: images
  defp gallery(_settings), do: []

  defp gallery_link(%{"gallery_link" => link}), do: link
  defp gallery_link(%{"link_to" => link}), do: link
  defp gallery_link(_settings), do: "file"

  defp figure(%{"url" => url} = image, link, ctx) when is_binary(url) and url != "" do
    file = Map.get(ctx.media, media_id(image))

    [
      {"figure", [],
       linked(
         [{"img", [{"src", url}, {"alt", alt(image, file)}], []}],
         file_link(link, url, file)
       )}
    ]
  end

  defp figure(_image, _link, _ctx), do: []

  defp file_link("file", url, _file), do: %{"url" => url}
  defp file_link("attachment", _url, %{"link" => page}), do: %{"url" => page}
  defp file_link(_none, _url, _file), do: nil

  defp laid([], _settings, _ctx), do: []

  defp laid(figures, settings, %{kind: "page"}),
    do: [{"div", [{"class", "grid gap-6 md:grid-cols-#{columns(settings)}"}], figures}]

  defp laid(figures, _settings, _post), do: [{"figure", [], figures}]

  defp columns(settings),
    do:
      settings
      |> Map.get("gallery_columns", settings["columns"])
      |> to_string()
      |> Integer.parse()
      |> whole() || 4

  defp whole({number, ""}) when number > 0, do: number
  defp whole(_not_whole), do: nil

  defp video(%{"video_type" => "hosted"} = settings), do: {:file, hosted(settings)}
  defp video(settings), do: settings |> Map.get("video_type", "youtube") |> addressed(settings)

  defp addressed(type, settings) when is_map_key(@videos, type) do
    {key, default} = Map.fetch!(@videos, type)
    {:player, text(settings[key], default)}
  end

  defp addressed(_type, _settings), do: nil

  defp hosted(%{"insert_url" => "yes", "external_url" => %{"url" => url}}), do: url
  defp hosted(%{"hosted_url" => %{"url" => url}}), do: url
  defp hosted(_settings), do: nil

  defp played({:player, url}), do: [url |> String.trim() |> Content.embed()]

  defp played({:file, url}) when is_binary(url) and url != "",
    do: [{"video", [{"controls", ""}, {"src", url}], []}]

  defp played(_none), do: []

  defp text(text, _default) when is_binary(text) and text != "", do: text
  defp text(_none, default), do: default

  defp fragment(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.to_tree()

  defp uncommented({:comment, _text}), do: []
  defp uncommented(node), do: node
end
