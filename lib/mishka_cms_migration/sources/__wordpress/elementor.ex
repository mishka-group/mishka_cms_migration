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
      column for each, 12 at most (the widest grid Tailwind has), side by side from the `md`
      width, as the builder's 2, 3 and 4 columns are;
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
      VideoPress one, and a `<video>` of a file the site hosts or of another address; a video
      whose address was never set is Elementor's demo video, as Elementor draws it, and one whose
      address was cleared is none;
    * an icon list — a Bulleted list, each item linked when it links, without its icons;
    * an image gallery, and Elementor Pro's gallery — a grid of as many columns as it says (1 to
      12, and 4 when it says none), of Figures each linked to its file or to its attachment page;
    * a spacer — a Spacer, and a divider a Divider;
    * HTML — the author's markup as it is;
    * a shortcode — its shortcodes, converted as classic content's are.

  The paragraphs, lists, quotes, links, images, figures and rules of these take the classes of the
  builder's element of the same tag (Paragraph, Bulleted list, Link, ...), with the builder's slate
  colours swapped for the site's colour tokens (`text-fg dark:text-fg-dark`, ...): slate does not
  change in the dark theme, and the tokens do.

  ## What of Elementor's styling is carried over

  Through the builder's own style settings (`MishkaCmsCore.Runtime.Authoring.Tree.Styles`, what its
  Inspector writes and reads back), never an inline `style`: a property and a value for each width
  (Elementor's own, tablet and mobile settings are the builder's base, tablet and mobile), compiled
  to the Tailwind classes the Inspector would have written, after the element's own.

    * alignment (`align`) — a heading's, a text editor's and a button's `text-align`;
    * the `padding` and `margin` of a section and a container (on the Section at the top, on the
      grid or the stack an inner one becomes), of a column (on the Stack its cell becomes, wrapped
      in one even when it holds one widget), of a widget (its Advanced tab's `_padding` and
      `_margin`, on the element it draws, or on a box around it when it draws more than one, or a
      link) and a button's own (`text_padding`) — by side (`py`/`px` when both sides match, else
      `pt`, `pb`, `pl`, `pr`), exact, not rounded to a spacing step;
    * a section's `content_width` and a container's `boxed_width` — the Container's `max-width`;
    * a container's `flex_gap` — the `gap` of the grid or stack it becomes; a section's named
      column `gap` — the grid's `gap` in the pixels Elementor documents for it (no 0, narrow 5,
      default 10, extended 15, wide 20, wider 30), or its `gap_columns_custom`;
    * an image's `width`, and its own size (`width: auto`) when Elementor gives none, in place of
      the builder's full width, and its `align` — its margins (`mx: auto` centred, `ml: auto` to
      the right, `mx: 0` to the left), centred when Elementor says nothing, as Elementor draws it;
    * a heading's, a text editor's and a button's typography — its font's `font-size`, in the unit
      Elementor has (px, em, rem, %, vw, vh), `font-weight` (300 to 800), `line-height`,
      `letter-spacing` and `text-transform`, each at the widths Elementor has them;
    * colours — a heading's (`title_color`), a text editor's (`text_color`) and a button's
      (`button_text_color`) `color`, and the `background` of a button, a section, a column and a
      container whose background is a colour (`background_background` `classic`).

  ## Elementor's global colours and fonts

  A colour or a font a widget names in its `__globals__` is one of the kit's, which the site has as
  theme tokens (`MishkaCmsMigration.Sources.WordPress.ElementorKit`), and the page names the token:

    * a colour is the style setting `var(--color-el-<id>,<value>)`, and its dark twin the class
      `dark:text-[var(--color-el-<id>-dark,var(--color-el-<id>,<value>))]` (or `dark:bg-…` for a
      background) in place of the theme's own pair (`text-fg dark:text-fg-dark`, ...): the dark
      theme shows the twin, which an admin sets once in the stylesheet for every page;
    * a font is the class of its family,
      `font-[family-name:var(--font-el-<id>,'<family>',sans-serif)]`, and its weight, size, line
      height, letter spacing and case are the style settings above. Elementor applies a global font
      whole, so the widget's own typography is not read beside it.

  Each token has the kit's own colour or family behind it, so a page reads while the stylesheet is
  missing, not yet active, or archived.

  A family a widget sets itself is the class of the kit's font in that family, the one the
  stylesheet loads; any other family is left out, as nothing on the site would load it. A global the
  kit does not have, such as a custom colour since deleted, draws nothing, as on WordPress.

  A colour of the widget's own is the style setting with its value (`text-[#0f766e]`), in place of
  the theme's light colour, and the element keeps the theme's dark twin, so it reads in the dark
  theme (`dark:bg-page-dark` for the background of a section, a column or a container, which has
  none); a colour that is exactly the light value of one of the theme's text tokens (fg, dim,
  subtle, faint, brand) is that token's classes with their dark twins. A text editor's colour, size
  and line height are its box's, so its paragraphs, lists and quotes leave theirs out and take the
  box's.

  Not carried over: a family no font of the kit has, gradients and pictures behind an element,
  borders, shadows and hover colours. Elementor's tablet (1024) and mobile (767) widths become the
  builder's (900 and 560).

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
  (`MishkaCmsMigration.Targets.Helpers.Widgets`). One Elementor drew nothing for has no fallback,
  and nothing stands in its place: one whose `data-id` the rendering does not have, one whose
  part holds nothing but empty boxes, such as a Pro widget on a site without Pro, and every such
  widget read from an export, which carries no rendering. `call/3` names those apart.

  The images of the image and gallery widgets are read from WordPress with `fetch`
  (`/wp/v2/media`), all in one request, for their alt text, caption and attachment page.
  """

  alias MishkaCmsCore.Runtime.Authoring.Elements
  alias MishkaCmsCore.Runtime.Authoring.Tree.Styles
  alias MishkaCmsMigration.Sources.WordPress.{Content, ElementorKit}

  @widgets ~w(heading text-editor image button video icon-list image-gallery gallery spacer divider
              html shortcode)
  @styled_widgets ~w(image video icon-list image-gallery gallery divider shortcode)
  @layouts ["section", "column", "container"]
  @galleries ["image-gallery", "gallery"]
  @headings ~w(h1 h2 h3 h4 h5 h6)
  @rows ["row", "row-reverse"]
  @alignments ~w(left center right justify)
  @lengths ~w(px em rem % vw vh)
  @breakpoints [base: "", tablet: "_tablet", mobile: "_mobile"]
  @element_id ~r/\A[\w-]+\z/
  @grid_columns 12
  @dropped_attrs ~w(class style srcset sizes loading decoding fetchpriority)
  @not_kept ["script", "style", "noscript"]

  # The builder's elements are written in Tailwind's slate, which stays dark on a dark page. The
  # site's own colour tokens (`MishkaCmsCore.Install.StarterContent.theme_css/0`) each have a
  # `-dark` twin, so a page is drawn with them, as the starter's own pages are.
  @themed %{
    "text-slate-900" => "text-fg dark:text-fg-dark",
    "text-slate-700" => "text-dim dark:text-dim-dark",
    "text-slate-600" => "text-dim dark:text-dim-dark",
    "text-slate-500" => "text-subtle dark:text-subtle-dark",
    "border-slate-300" => "border-edge dark:border-edge-dark",
    "border-slate-200" => "border-edge dark:border-edge-dark",
    "bg-slate-900" => "bg-fg dark:bg-fg-dark",
    "text-white" => "text-white dark:text-page-dark"
  }

  # The theme's text colours by the light value Elementor would carry for the same colour.
  @colors %{
    "#1a1a1f" => ["text-fg", "dark:text-fg-dark"],
    "#6b6a72" => ["text-dim", "dark:text-dim-dark"],
    "#8a8892" => ["text-subtle", "dark:text-subtle-dark"],
    "#a3a0a9" => ["text-faint", "dark:text-faint-dark"],
    "#5b4fe0" => ["text-brand", "dark:text-brand-dark"]
  }
  @color_classes @colors |> Map.values() |> List.flatten()

  # The theme's colour classes an element of the builder carries, light and dark, by the Tailwind
  # prefix they colour: what a colour of Elementor's takes the place of.
  @theme_paint (@themed |> Map.values() |> Enum.flat_map(&String.split/1)) ++ @color_classes
  @paints %{"color" => "text", "background" => "bg"}
  @light_paint Map.new(@paints, fn {_prop, prefix} ->
                 {prefix, Enum.filter(@theme_paint, &String.starts_with?(&1, prefix <> "-"))}
               end)
  @dark_paint Map.new(@paints, fn {_prop, prefix} ->
                {prefix, Enum.filter(@theme_paint, &String.starts_with?(&1, "dark:#{prefix}-"))}
              end)
  # The theme's own colour a raw colour gives way to in the dark theme, on an element with none.
  @dark_default %{"text" => "dark:text-fg-dark", "bg" => "dark:bg-page-dark"}

  # The classes of a text block a text editor's own colour, size and line height take the place of,
  # so its paragraphs, lists and quotes take them from the box as Elementor's do.
  @inheriting ~w(p ul ol blockquote)
  @inherited %{
    "color" => Enum.filter(@theme_paint, &String.starts_with?(&1, ["text-", "dark:text-"])),
    "font-size" => ["text-base"],
    "line-height" => ["leading-relaxed"]
  }

  @weights %{
    "300" => "font-light",
    "400" => "font-normal",
    "normal" => "font-normal",
    "500" => "font-medium",
    "600" => "font-semibold",
    "700" => "font-bold",
    "bold" => "font-bold",
    "800" => "font-extrabold"
  }

  # Elementor's named column gaps, in the pixels it documents for each.
  @gaps %{
    "no" => "0px",
    "narrow" => "5px",
    "default" => "10px",
    "extended" => "15px",
    "wide" => "20px",
    "wider" => "30px"
  }

  # An image's alignment as its margins, the way the builder centres a block.
  @image_aligns %{
    "left" => %{"mx" => "0px"},
    "center" => %{"mx" => "auto"},
    "right" => %{"ml" => "auto", "mr" => "0px"}
  }

  @no_look {[], %{}}

  @transforms %{
    "uppercase" => "uppercase",
    "lowercase" => "lowercase",
    "capitalize" => "capitalize",
    "none" => "normal-case"
  }

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
                 {"class", class}, styles ->
                   Map.put_new(
                     styles,
                     tag,
                     class |> String.split() |> Enum.map_join(" ", &Map.get(@themed, &1, &1))
                   )

                 _attr, styles ->
                   styles
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
             |> elem(1)
             |> String.split()
             |> Enum.map_join(" ", &Map.get(@themed, &1, &1)))

  @doc """
  The content pieces of `row`, an entry Elementor laid out, made as a `kind` (`"page"` or
  `"post"`) is, the names of the widgets in it the CMS has no equivalent for, and the names of
  those of them Elementor drew nothing for, reading its images with `fetch` and naming the site's
  `globals` (`MishkaCmsMigration.Sources.WordPress.ElementorKit`); `:none` for an entry Elementor
  did not lay out.
  """
  @spec call(map(), String.t(), Content.fetch(), ElementorKit.globals()) ::
          {:ok, [map()], [String.t()], [String.t()]} | :none
  def call(row, kind, fetch, globals \\ %{})

  def call(
        %{"meta" => %{"_elementor_edit_mode" => "builder", "_elementor_data" => data}} = row,
        kind,
        fetch,
        globals
      )
      when is_binary(data),
      do: data |> JSON.decode() |> laid_out(row, {kind, fetch, globals})

  def call(_row, _kind, _fetch, _globals), do: :none

  defp laid_out({:ok, [_ | _] = elements}, row, {kind, fetch, globals}) do
    found = Enum.reduce(elements, %{media: [], unsupported: []}, &found/2)
    unsupported = Enum.reverse(found.unsupported)

    ctx = %{
      kind: kind,
      fetch: fetch,
      globals: ElementorKit.read(globals),
      media: media(found.media, fetch),
      fallbacks: fallbacks(row, unsupported)
    }

    {:ok, elements |> Enum.flat_map(&element(&1, ctx)) |> Content.pieces(), named(unsupported),
     unsupported |> Enum.reject(&is_map_key(ctx.fallbacks, elem(&1, 0))) |> named()}
  end

  defp laid_out(_no_layout, _row, _call), do: :none

  defp named(unsupported), do: unsupported |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

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
        drawn = rendered |> LazyHTML.query(~s([data-id="#{id}"])) |> fallback(),
        not blank?(drawn),
        into: %{},
        do: {id, drawn}
  end

  defp fallbacks(_row, _unsupported), do: %{}

  defp fallback(drawn),
    do: drawn |> LazyHTML.child_nodes() |> LazyHTML.to_tree() |> LazyHTML.Tree.postwalk(&kept/1)

  defp blank?(nodes), do: Enum.all?(nodes, &blank_node?/1)

  defp blank_node?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank_node?({_tag, [], children}), do: blank?(children)
  defp blank_node?(_node), do: false

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
       do:
         columns
         |> cells(ctx)
         |> side_by_side(section |> settings() |> column_gap(ctx), ctx)
         |> placed(section, ctx)

  defp element(%{"elType" => "column", "elements" => widgets}, ctx) when is_list(widgets),
    do: Enum.flat_map(widgets, &element(&1, ctx))

  defp element(%{"elType" => "container", "elements" => children} = container, ctx)
       when is_list(children),
       do:
         container
         |> settings()
         |> Map.get("flex_direction")
         |> flexed(cells(children, ctx), ctx)
         |> restyled(gap(settings(container)), ctx)
         |> placed(container, ctx)

  defp element(%{"elType" => "widget", "widgetType" => type} = widget, ctx)
       when type in @widgets,
       do:
         type
         |> widget(settings(widget), ctx)
         |> styled(type, ctx)
         |> spaced(settings(widget), ctx)

  defp element(%{"elType" => _type} = element, ctx),
    do: Map.get(ctx.fallbacks, element["id"], [])

  defp element(_unreadable, _ctx), do: []

  defp settings(%{"settings" => %{} = settings}), do: settings
  defp settings(_element), do: %{}

  # Each element's nodes, as a cell of the grid or the stack it is drawn in, with the look a column
  # gives its own cell: its padding, margin and background.
  defp cells(elements, ctx),
    do:
      for(
        element <- elements,
        nodes = element(element, ctx),
        nodes != [],
        do: {nodes, cell_look(element, ctx)}
      )

  defp cell_look(%{"elType" => "column"} = column, %{kind: "page"} = ctx),
    do: box_look(settings(column), ctx)

  defp cell_look(_element, _ctx), do: @no_look

  # An element's own padding, margin and background, as the look of what it is drawn as.
  defp box_look(settings, ctx),
    do:
      @no_look
      |> painted("background", background(settings, ctx))
      |> with_styles(spacing(settings, "padding", "p"))
      |> with_styles(spacing(settings, "margin", "m"))

  defp flexed(direction, cells, ctx) when direction in @rows, do: side_by_side(cells, %{}, ctx)
  defp flexed(_column, cells, ctx), do: cells |> Enum.flat_map(&elem(&1, 0)) |> stack(ctx)

  defp side_by_side([], _gap, _ctx), do: []

  defp side_by_side([{nodes, look}], _gap, ctx),
    do: nodes |> stack(ctx) |> Enum.map(&worn(&1, look))

  defp side_by_side(cells, gap, ctx),
    do: [
      restyled_node(
        {"div", [{"class", "grid gap-6 md:grid-cols-#{cells |> length() |> grid()}"}],
         Enum.map(cells, &cell(&1, ctx))},
        gap
      )
    ]

  defp cell({[{_tag, _attrs, _children} = one], {[], styles}}, _ctx) when styles == %{}, do: one
  defp cell({nodes, look}, %{kind: "page"}), do: "el-stack" |> built([], nodes) |> worn(look)
  defp cell({nodes, _look}, _post), do: {"div", [], nodes}

  defp column_gap(%{"gap" => "custom"} = settings, %{kind: "page"}),
    do: responsive(settings, "gap_columns_custom", &%{"gap" => css_length(&1)})

  defp column_gap(%{"gap" => gap}, %{kind: "page"}) when is_map_key(@gaps, gap),
    do: %{base: %{"gap" => Map.fetch!(@gaps, gap)}}

  defp column_gap(_settings, _ctx), do: %{}

  defp stack([], _ctx), do: []
  defp stack(nodes, %{kind: "page"}), do: [built("el-stack", [], nodes)]
  defp stack(nodes, _post), do: nodes

  defp placed([], _element, _ctx), do: []

  defp placed(nodes, %{"isInner" => true} = element, %{kind: "page"} = ctx),
    do: Enum.map(nodes, &worn(&1, box_look(settings(element), ctx)))

  defp placed(nodes, %{"isInner" => true}, _post), do: nodes

  defp placed(nodes, element, %{kind: "page"} = ctx) do
    settings = settings(element)
    ["el-section" |> built([], boxed(settings, nodes)) |> worn(box_look(settings, ctx))]
  end

  defp placed(nodes, _element, _post), do: nodes

  defp boxed(%{"layout" => "full_width"}, nodes), do: nodes
  defp boxed(%{"content_width" => "full"}, nodes), do: nodes

  defp boxed(settings, nodes),
    do: [restyled_node(built("el-container", [], nodes), width(settings))]

  defp width(settings),
    do: responsive(settings, ["content_width", "boxed_width"], &%{"max-width" => css_length(&1)})

  # The builder's own style vocabulary (`MishkaCmsCore.Runtime.Authoring.Tree.Styles`) is what the
  # Inspector's panel writes: a property and a value per width (`:base`, `:tablet`, `:mobile`),
  # compiled to Tailwind classes after the element's own. The Elementor settings that have a
  # property there are handed to it, so the Inspector opens on them as on a value an admin set.
  defp restyled(nodes, styles, %{kind: "page"}) when styles != %{},
    do: Enum.map(nodes, &restyled_node(&1, styles))

  defp restyled(nodes, _styles, _ctx), do: nodes

  defp restyled_node(node, styles, more \\ %{})
  defp restyled_node(node, styles, more) when styles == %{} and more == %{}, do: node

  defp restyled_node({tag, attrs, children}, styles, more) do
    styles = merge_styles(styles, more)
    class = attrs |> List.keyfind("class", 0, {"class", nil}) |> elem(1)

    {tag, List.keystore(attrs, "class", 0, {"class", Styles.merge_class(class, styles)}),
     children}
  end

  defp merge_styles(styles, more),
    do: Map.merge(styles, more, fn _bucket, left, right -> Map.merge(left, right) end)

  # An element's look: its classes and the builder's style settings for it, `{classes, styles}`,
  # worked on together and written once, the classes the Inspector's settings replace dropped
  # (`Styles.merge_class/2`).
  defp looked({_tag, attrs, _children} = node, fun),
    do: dressed(node, fun.({attrs |> class_of() |> String.split(), %{}}))

  defp dressed({tag, attrs, children}, {classes, styles}),
    do:
      {tag,
       with_class(attrs, classes |> Enum.uniq() |> Enum.join(" ") |> Styles.merge_class(styles)),
       children}

  defp class_of(attrs), do: attrs |> List.keyfind("class", 0, {"class", ""}) |> elem(1)

  defp with_class(attrs, class) when class in [nil, ""], do: List.keydelete(attrs, "class", 0)
  defp with_class(attrs, class), do: List.keystore(attrs, "class", 0, {"class", class})

  defp with_styles({classes, styles}, more), do: {classes, merge_styles(styles, more)}

  # A look worked out apart from the element it is given to, such as a column's, added to its own.
  defp worn(node, {[], styles}) when styles == %{}, do: node

  defp worn(node, {classes, styles}),
    do:
      looked(node, fn {own, own_styles} -> {own ++ classes, merge_styles(own_styles, styles)} end)

  # A widget's own padding and margin (Elementor's Advanced tab), on the element it draws, or on a
  # box around it when it draws more than one, or a link, which is inline.
  defp spaced(nodes, settings, %{kind: "page"}),
    do:
      settings
      |> spacing("_padding", "p")
      |> merge_styles(spacing(settings, "_margin", "m"))
      |> widget_box(nodes)

  defp spaced(nodes, _settings, _post), do: nodes

  defp widget_box(styles, nodes) when styles == %{}, do: nodes
  defp widget_box(_styles, []), do: []

  defp widget_box(styles, [{tag, _attrs, _children} = one]) when tag != "a",
    do: [restyled_node(one, styles)]

  defp widget_box(styles, nodes), do: [restyled_node({"div", [], nodes}, styles)]

  # Elementor's colour of a part: one of the kit's, named in `__globals__`, which the page names by
  # its token, or a value of its own. A global the kit does not have draws nothing, as on WordPress.
  defp colour(settings, key, ctx),
    do: settings |> global(key) |> coloured(settings[key], ctx)

  defp coloured({"colors", id}, _value, ctx) when is_map_key(ctx.globals.colours, id),
    do: {:global, id, Map.fetch!(ctx.globals.colours, id)}

  defp coloured(nil, value, _ctx), do: value |> ElementorKit.css_colour() |> own_colour()
  defp coloured(_unknown, _value, _ctx), do: nil

  defp own_colour(nil), do: nil
  defp own_colour(value), do: {:raw, value}

  defp background(%{"background_background" => type}, _ctx) when type not in [nil, "classic"],
    do: nil

  defp background(settings, ctx), do: colour(settings, "background_color", ctx)

  defp global(%{"__globals__" => %{} = globals}, key), do: globals |> Map.get(key) |> reference()
  defp global(_settings, _key), do: nil

  defp reference("globals/" <> _ = reference), do: reference |> URI.parse() |> referenced()
  defp reference(_own_value), do: nil

  defp referenced(%URI{path: "globals/" <> kind, query: query}) when is_binary(query),
    do: query |> URI.decode_query() |> Map.get("id") |> referenced(kind)

  defp referenced(_unreadable), do: nil

  defp referenced(id, kind) when is_binary(id) and id != "", do: {kind, id}
  defp referenced(_id, _kind), do: nil

  # A colour in place of the theme's: a global as its token, the light one through the builder's
  # style setting and its dark twin by its class; a value of the theme's own as its token classes;
  # any other value through the style setting, the element keeping the theme's own dark twin, so
  # it reads in the dark theme.
  defp painted(look, _prop, nil), do: look

  defp painted({classes, styles}, prop, {:global, id, value}) do
    prefix = Map.fetch!(@paints, prop)

    {unpainted(classes, prefix) ++ [ElementorKit.dark_class(prefix, id, value)],
     merge_styles(styles, %{base: %{prop => ElementorKit.colour(id, value)}})}
  end

  defp painted({classes, styles}, "color", {:raw, value}) when is_map_key(@colors, value),
    do: {unpainted(classes, "text") ++ Map.fetch!(@colors, value), styles}

  defp painted({classes, styles}, prop, {:raw, value}) do
    prefix = Map.fetch!(@paints, prop)
    kept = Enum.reject(classes, &(&1 in Map.fetch!(@light_paint, prefix)))

    {kept ++ dark_default(Enum.any?(kept, &(&1 in Map.fetch!(@dark_paint, prefix))), prefix),
     merge_styles(styles, %{base: %{prop => value}})}
  end

  defp unpainted(classes, prefix),
    do:
      Enum.reject(
        classes,
        &(&1 in Map.fetch!(@light_paint, prefix) or &1 in Map.fetch!(@dark_paint, prefix))
      )

  defp dark_default(true, _prefix), do: []
  defp dark_default(false, prefix), do: [Map.fetch!(@dark_default, prefix)]

  # Elementor's typography of a part: one of the kit's fonts, named in `__globals__`, whole, or its
  # own settings. A family is its font's token class, a family of its own the class of the kit's
  # font in that family (the one font a stylesheet loads), and the rest the builder's style settings.
  defp typed(look, settings, ctx),
    do: settings |> global("typography_typography") |> typography(settings, ctx) |> typeset(look)

  defp typography({"typography", id}, _settings, ctx),
    do: ctx.globals.typography |> Map.get(id) |> global_font(id)

  defp typography(nil, settings, ctx) do
    family = ElementorKit.family(settings)
    {ctx.globals.families |> Map.get(family) |> font_class(family), type_styles(settings)}
  end

  defp typography(_unknown, _settings, _ctx), do: {nil, %{}}

  defp global_font(nil, _id), do: {nil, %{}}

  defp global_font(settings, id),
    do: {settings |> ElementorKit.family() |> family_class(id), type_styles(settings)}

  defp family_class(nil, _id), do: nil
  defp family_class(family, id), do: ElementorKit.font_class(id, family)

  defp font_class(nil, _family), do: nil
  defp font_class(id, family), do: ElementorKit.font_class(id, family)

  defp typeset({nil, more}, look), do: with_styles(look, more)

  defp typeset({class, more}, {classes, styles}),
    do: with_styles({classes ++ [class], styles}, more)

  defp type_styles(settings),
    do:
      [
        size(settings),
        responsive(settings, "typography_font_weight", &%{"font-weight" => weight(&1)}),
        responsive(settings, "typography_line_height", &%{"line-height" => css_length(&1)}),
        responsive(settings, "typography_letter_spacing", &%{"letter-spacing" => css_length(&1)}),
        responsive(settings, "typography_text_transform", &%{"text-transform" => transform(&1)})
      ]
      |> Enum.reduce(%{}, &merge_styles(&2, &1))

  defp weight(value) when is_binary(value), do: Map.get(@weights, value)
  defp weight(_value), do: nil

  defp transform(value) when is_binary(value), do: Map.get(@transforms, value)
  defp transform(_value), do: nil

  # A setting Elementor keeps once for every width (`padding`, `padding_tablet`, `padding_mobile`),
  # read for each and made into that width's properties by `props`.
  defp responsive(settings, keys, props) do
    for {bucket, suffix} <- @breakpoints,
        key <- List.wrap(keys),
        value = Map.get(settings, key <> suffix),
        found = value |> props.() |> present(),
        found != %{},
        reduce: %{} do
      styles -> merge_styles(styles, %{bucket => found})
    end
  end

  defp present(%{} = props), do: Map.reject(props, fn {_prop, value} -> is_nil(value) end)
  defp present(_none), do: %{}

  defp spacing(settings, key, prefix),
    do: responsive(settings, key, &sides(&1, prefix))

  defp sides(%{"unit" => unit} = box, prefix) do
    [top, right, bottom, left] = Enum.map(~w(top right bottom left), &css_length(box[&1], unit))

    Map.new(
      axis(prefix <> "y", prefix <> "t", prefix <> "b", top, bottom) ++
        axis(prefix <> "x", prefix <> "l", prefix <> "r", left, right)
    )
  end

  defp sides(_box, _prefix), do: %{}

  defp axis(both, _first, _last, value, value) when is_binary(value), do: [{both, value}]

  defp axis(_both, first, last, one, other),
    do: for({prop, value} <- [{first, one}, {last, other}], is_binary(value), do: {prop, value})

  defp gap(settings),
    do:
      responsive(
        settings,
        "flex_gap",
        &%{"gap" => css_length(&1["column"] || &1["row"], &1["unit"])}
      )

  defp css_length(%{"size" => size, "unit" => unit}), do: css_length(size, unit)
  defp css_length(_none), do: nil

  defp css_length(value, unit) when unit in @lengths do
    case number(value) do
      nil -> nil
      number -> "#{trunc_whole(number)}#{unit}"
    end
  end

  defp css_length(_value, _unit), do: nil

  defp trunc_whole(number) when number == trunc(number), do: trunc(number)
  defp trunc_whole(number), do: number

  defp number(value) when is_number(value), do: value

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _not_a_number -> nil
    end
  end

  defp number(_value), do: nil

  defp built(id, attributes, children) do
    {tag, own, _placeholder} = Map.fetch!(@elements, id)
    {tag, attributes ++ [List.keyfind(own, "class", 0)], children}
  end

  defp styled(nodes, type, %{kind: "page"}) when type in @styled_widgets,
    do: LazyHTML.Tree.postwalk(nodes, &style/1)

  defp styled(nodes, _type, _ctx), do: nodes

  defp style(node), do: style(node, [])

  defp style({tag, attrs, children}, inherited) when is_map_key(@styles, tag),
    do: {tag, classed(attrs, List.keymember?(attrs, "class", 0), tag, inherited), children}

  defp style(node, _inherited), do: node

  defp classed(attrs, true, _tag, _inherited), do: attrs

  defp classed(attrs, false, tag, inherited) when tag in @inheriting,
    do:
      @styles
      |> Map.fetch!(tag)
      |> String.split()
      |> Enum.reject(&(&1 in inherited))
      |> Enum.join(" ")
      |> then(&with_class(attrs, &1))

  defp classed(attrs, false, tag, _inherited), do: attrs ++ [{"class", Map.fetch!(@styles, tag)}]

  defp widget("heading", %{"title" => title} = settings, ctx)
       when is_binary(title) and title != "" do
    tag = heading(settings["header_size"])

    [heading_tag(tag, title |> fragment() |> linked(settings["link"]), settings, ctx)]
  end

  defp widget("text-editor", %{"editor" => html} = settings, ctx) when is_binary(html),
    do: html |> Content.nodes(ctx.fetch) |> boxed_text(settings, ctx)

  defp widget("image", %{"image" => %{"url" => url} = image} = settings, ctx)
       when is_binary(url) and url != "" do
    file = Map.get(ctx.media, media_id(image))

    [image(url, alt(image, file), settings, ctx)]
    |> linked(image_link(settings, url))
    |> captioned(caption(settings, file))
  end

  defp widget("button", settings, ctx),
    do:
      settings["link"]
      |> link_attributes()
      |> button(settings["text"] |> text("Click here") |> fragment(), settings, ctx)

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

  defp heading_tag(tag, children, settings, %{kind: "page"} = ctx),
    do:
      looked({tag, [{"class", Map.fetch!(@styles, tag)}], children}, fn look ->
        look
        |> with_styles(aligned(settings))
        |> painted("color", colour(settings, "title_color", ctx))
        |> typed(settings, ctx)
      end)

  defp heading_tag(tag, children, _settings, _post), do: {tag, [], children}

  defp size(settings),
    do: responsive(settings, "typography_font_size", &%{"font-size" => css_length(&1)})

  defp aligned(settings),
    do:
      responsive(settings, "align", fn
        align when align in @alignments -> %{"text-align" => "text-" <> align}
        _start -> nil
      end)

  defp boxed_text(nodes, settings, %{kind: "page"} = ctx) do
    look =
      {[], aligned(settings)}
      |> painted("color", colour(settings, "text_color", ctx))
      |> typed(settings, ctx)

    inherited = inherited(look)
    [dressed({"div", [], LazyHTML.Tree.postwalk(nodes, &style(&1, inherited))}, look)]
  end

  defp boxed_text(nodes, _settings, _post), do: nodes

  defp inherited({classes, styles}) do
    set = styles |> Map.values() |> Enum.flat_map(&Map.keys/1)
    coloured? = Enum.any?(classes, &String.starts_with?(&1, ["text-", "dark:text-"]))

    for {prop, dropped} <- @inherited,
        prop in set or (prop == "color" and coloured?),
        class <- dropped,
        do: class
  end

  defp button(href, label, settings, %{kind: "page"} = ctx),
    do:
      {"a", href ++ [{"class", @button}], label}
      |> looked(fn look ->
        look
        |> painted("color", colour(settings, "button_text_color", ctx))
        |> painted("background", background(settings, ctx))
        |> typed(settings, ctx)
        |> with_styles(spacing(settings, "text_padding", "p"))
      end)
      |> aligned_button(aligned(settings))

  defp button(href, label, _settings, _post), do: [{"p", [], [{"a", href, label}]}]

  defp aligned_button(a, styles) when styles == %{}, do: [a]

  defp aligned_button(a, %{base: %{"text-align" => "text-left"}} = styles)
       when map_size(styles) == 1,
       do: [a]

  defp aligned_button(a, styles), do: [restyled_node({"div", [], [a]}, styles)]

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

  # An image at its own size, or the width Elementor gives it, and aligned as it is: centred unless
  # it says otherwise, as Elementor draws it.
  defp image(url, alt, settings, %{kind: "page"}),
    do:
      restyled_node(
        {"img", [{"src", url}, {"alt", alt}, {"class", Map.fetch!(@styles, "img")}], []},
        settings
        |> image_aligned()
        |> responsive("align", &Map.get(@image_aligns, &1))
        |> merge_styles(%{base: %{"width" => "auto"}})
        |> merge_styles(responsive(settings, "width", &%{"width" => css_length(&1)}))
      )

  defp image(url, alt, _settings, _post), do: {"img", [{"src", url}, {"alt", alt}], []}

  defp image_aligned(%{"align" => align} = settings) when is_map_key(@image_aligns, align),
    do: settings

  defp image_aligned(settings), do: Map.put(settings, "align", "center")

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
      |> counted()

  defp counted({count, ""}), do: grid(count)
  defp counted(_not_a_count), do: 4

  defp grid(count), do: count |> max(1) |> min(@grid_columns)

  defp whole({number, ""}) when number > 0, do: number
  defp whole(_not_whole), do: nil

  defp video(%{"video_type" => "hosted"} = settings), do: {:file, hosted(settings)}
  defp video(settings), do: settings |> Map.get("video_type", "youtube") |> addressed(settings)

  defp addressed(type, settings) when is_map_key(@videos, type) do
    {key, default} = Map.fetch!(@videos, type)
    {:player, Map.get(settings, key, default)}
  end

  defp addressed(_type, _settings), do: nil

  defp hosted(%{"insert_url" => "yes", "external_url" => %{"url" => url}}), do: url
  defp hosted(%{"hosted_url" => %{"url" => url}}), do: url
  defp hosted(_settings), do: nil

  defp played({kind, url}) when is_binary(url), do: url |> String.trim() |> drawn(kind)
  defp played(_none), do: []

  defp drawn("", _kind), do: []
  defp drawn(url, :player), do: [Content.embed(url)]
  defp drawn(url, :file), do: [{"video", [{"controls", ""}, {"src", url}], []}]

  defp text(text, _default) when is_binary(text) and text != "", do: text
  defp text(_none, default), do: default

  defp fragment(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.to_tree()

  defp uncommented({:comment, _text}), do: []
  defp uncommented(node), do: node
end
