# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Sources.WordPress.Content do
  @moduledoc """
  A WordPress post's or page's `content.raw` as its item's content pieces
  (`MishkaCmsMigration.Source.Item`): `%{html: ...}` for what is converted here, and
  `%{name: ..., attrs: ..., raw: ...}` for a block or shortcode left to `migration:content:convert`
  (`MishkaCmsMigration.Events`), in the order they come. `call/2` reads the content with LazyHTML,
  an HTML5 parser, so its markup is never edited as text; only a shortcode, which is text, is read
  with a pattern.

  ## Blocks

  A block is what its `<!-- wp:name {attrs} -->` and `<!-- /wp:name -->` comments enclose, or a
  `<!-- wp:name {attrs} /-->` alone. A core block (`core/…`, the name without a namespace) becomes
  its own saved markup, which is already semantic HTML: headings, lists, quotes, tables,
  `<pre><code>`, `<figure>` with its `<img>` and `<figcaption>`, a gallery's figures inside one
  `<figure>`, `<hr>`. The markup loses WordPress's `class` and `style`, which no theme here reads,
  and the block comments; the blocks inside it are converted the same way. Some take a shape of
  their own:

    * `core/columns` and `core/media-text` — a `<div class="grid gap-6 md:grid-cols-N">`, one
      column per inner block, and `core/group` a `<div class="grid gap-6">`;
    * `core/embed` — a `<figure>` with a link to its address;
    * `core/html` — the author's markup as it is, classes kept, without its comments;
    * `core/shortcode` — its shortcodes, below;
    * `core/block`, a reusable block — the content of the reusable block it names, read from
      WordPress with the `fetch` `call/2` is handed (`/wp/v2/blocks`) and converted the same way; a
      reusable block inside it, or one WordPress does not answer, is a piece named `core/block`
      with its `"ref"`.

  A block of another namespace (`acme/callout`) and a block with no saved markup, which WordPress
  draws as the page is served (`core/latest-posts`), are pieces named by the block, with its attrs
  and its markup, comments included, as `raw`.

  ## Classic content and shortcodes

  What sits outside any block, all of a post written in the classic editor, has its paragraphs
  made as WordPress makes them when it shows the post: a blank line ends one, a line break inside
  one is a `<br>`, and a block element (a heading, a list, a figure) stands on its own. Its
  shortcodes, and those of a `core/shortcode` block, become HTML:

    * `[caption]` — a `<figure>` with the image and its caption;
    * `[gallery ids="…"]` — a `<figure>` of a figure per image, each image read from WordPress
      (`/wp/v2/media`) and linked to its file (`link="file"`), to nothing (`link="none"`) or to its
      attachment page;
    * `[embed]` — a `<figure>` with a link to the address it encloses;
    * `[video src="…"]` — a `<video>` with its controls.

  Any other shortcode, and a gallery none of whose images WordPress answers, is a piece named by the
  shortcode (no namespace, so never mistaken for a block), with its attributes and its text as
  `raw`. A shortcode inside a block other than `core/shortcode` is left as text.

  Images and links keep the addresses WordPress gave them. The links to the site's own posts are
  named in the item's `links` (`MishkaCmsMigration.Sources.WordPress`), for the target to point
  them at where the posts move; the media are moved after this.
  """

  @piece "mishka:piece"

  @grids %{"core/columns" => :columns, "core/media-text" => :columns, "core/group" => :rows}

  @dropped_attrs ["class", "style"]

  @block_tags ~w(address article aside blockquote details div dl figure footer h1 h2 h3 h4 h5 h6
                 header hr iframe nav ol p pre section table ul video)

  @shortcode ~r/\[(\/?)([A-Za-z][\w-]*)((?:\s[^\[\]]*)?)\]/u
  @shortcode_attr ~r/([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"']+))/u
  @blank_line ~r/\n[^\S\n]*\n/

  @typedoc """
  How `call/2` reads more of WordPress: the rows of a REST route (`"/wp/v2/blocks"`,
  `"/wp/v2/media"`) with these ids, by id, or `%{}` when it cannot.
  """
  @type fetch :: (String.t(), [pos_integer()] -> %{optional(pos_integer()) => map()})

  @doc """
  The pieces `raw` is made of, reading the reusable blocks and the gallery images it names with
  `fetch`.
  """
  @spec call(String.t(), fetch()) :: [map()]
  def call(raw, fetch) when is_binary(raw) do
    {tree, pieces} =
      raw
      |> tree()
      |> top(%{fetch: fetch, reusable?: true})
      |> LazyHTML.Tree.postwalk([], &marked/2)

    tree
    |> LazyHTML.Tree.to_html()
    |> String.split("<!--#{@piece}-->")
    |> joined(Enum.reverse(pieces))
  end

  defp tree(raw), do: raw |> LazyHTML.from_fragment() |> LazyHTML.to_tree()

  defp marked({:piece, piece}, pieces), do: {{:comment, @piece}, [piece | pieces]}
  defp marked(node, pieces), do: {node, pieces}

  defp joined([html], []), do: html_piece(html)

  defp joined([html | htmls], [piece | pieces]),
    do: html_piece(html) ++ [piece | joined(htmls, pieces)]

  defp html_piece(""), do: []
  defp html_piece(html), do: [%{html: html}]

  defp top(nodes, ctx),
    do: nodes |> blocks() |> Enum.chunk_by(&block?/1) |> Enum.flat_map(&run(&1, ctx))

  defp run([{:block, _name, _attrs, _inner, _raw} | _] = blocks, ctx),
    do: Enum.flat_map(blocks, &block(&1, ctx))

  defp run(nodes, ctx), do: nodes |> shortcodes(ctx) |> paragraphs()

  defp inner(nodes, ctx), do: nodes |> blocks() |> Enum.flat_map(&inner_node(&1, ctx))

  defp inner_node({:block, _name, _attrs, _inner, _raw} = block, ctx), do: block(block, ctx)
  defp inner_node(node, ctx), do: clean(node, ctx)

  defp clean({:comment, _text}, _ctx), do: []

  defp clean({tag, attrs, children}, ctx),
    do: [{tag, Enum.reject(attrs, &(elem(&1, 0) in @dropped_attrs)), inner(children, ctx)}]

  defp clean(text, _ctx), do: [text]

  defp block?(node), do: match?({:block, _name, _attrs, _inner, _raw}, node)

  defp blocks([]), do: []

  defp blocks([{:comment, text} = comment | rest]),
    do: text |> delimiter() |> opened(comment, rest)

  defp blocks([node | rest]), do: [node | blocks(rest)]

  defp opened({:open, name, attrs}, comment, rest) do
    {inner, close, rest} = closing(rest, name, 0, [])
    [{:block, name, attrs, inner, [comment | inner] ++ close} | blocks(rest)]
  end

  defp opened({:void, name, attrs}, comment, rest),
    do: [{:block, name, attrs, nil, [comment]} | blocks(rest)]

  defp opened(_not_an_opening, comment, rest), do: [comment | blocks(rest)]

  defp closing([], _name, _depth, inner), do: {Enum.reverse(inner), [], []}

  defp closing([{:comment, text} = node | rest], name, depth, inner),
    do: text |> delimiter() |> closed(node, rest, name, depth, inner)

  defp closing([node | rest], name, depth, inner), do: closing(rest, name, depth, [node | inner])

  defp closed({:close, name}, node, rest, name, 0, inner), do: {Enum.reverse(inner), [node], rest}

  defp closed({:close, name}, node, rest, name, depth, inner),
    do: closing(rest, name, depth - 1, [node | inner])

  defp closed({:open, name, _attrs}, node, rest, name, depth, inner),
    do: closing(rest, name, depth + 1, [node | inner])

  defp closed(_other, node, rest, name, depth, inner),
    do: closing(rest, name, depth, [node | inner])

  defp delimiter(text), do: text |> String.trim() |> delimited()

  defp delimited("/wp:" <> name), do: {:close, block_name(String.trim(name))}
  defp delimited("wp:" <> rest), do: rest |> String.split(" ", parts: 2) |> opening()
  defp delimited(_comment), do: :comment

  defp opening([name]), do: {:open, block_name(name), %{}}

  defp opening([name, rest]),
    do: opening(block_name(name), String.trim(rest), String.ends_with?(rest, "/"))

  defp opening(name, rest, true), do: {:void, name, rest |> String.trim_trailing("/") |> json()}
  defp opening(name, rest, false), do: {:open, name, json(rest)}

  defp block_name(name), do: block_name(name, String.contains?(name, "/"))
  defp block_name(name, true), do: name
  defp block_name(name, false), do: "core/" <> name

  defp json(text), do: text |> JSON.decode() |> decoded()

  defp decoded({:ok, attrs}) when is_map(attrs), do: attrs
  defp decoded(_not_attrs), do: %{}

  defp block({:block, "core/block", %{"ref" => ref} = attrs, nil, raw}, %{reusable?: true} = ctx)
       when is_integer(ref),
       do: "/wp/v2/blocks" |> ctx.fetch.([ref]) |> Map.get(ref) |> reusable(attrs, raw, ctx)

  defp block({:block, name, attrs, nil, raw}, _ctx), do: [piece(name, attrs, raw)]

  defp block({:block, "core/html", _attrs, inner, _raw}, _ctx),
    do: LazyHTML.Tree.postwalk(inner, &uncommented/1)

  defp block({:block, "core/shortcode", _attrs, inner, _raw}, ctx), do: shortcodes(inner, ctx)
  defp block({:block, "core/embed", %{"url" => url}, _inner, _raw}, _ctx), do: [embed(url)]

  defp block({:block, name, _attrs, inner, _raw}, ctx) when is_map_key(@grids, name),
    do: [grid(Map.fetch!(@grids, name), inner |> wrapped() |> inner(ctx))]

  defp block({:block, "core/" <> _name, _attrs, inner, _raw}, ctx), do: inner(inner, ctx)
  defp block({:block, name, attrs, _inner, raw}, _ctx), do: [piece(name, attrs, raw)]

  defp reusable(%{"content" => %{"raw" => content}}, _attrs, _raw, ctx)
       when is_binary(content),
       do: content |> tree() |> top(%{ctx | reusable?: false})

  defp reusable(_unanswered, attrs, raw, _ctx), do: [piece("core/block", attrs, raw)]

  defp uncommented({:comment, _text}), do: []
  defp uncommented(node), do: node

  defp wrapped(inner), do: Enum.find_value(inner, inner, &children/1)

  defp children({_tag, _attrs, children}), do: children
  defp children(_node), do: nil

  defp grid(:rows, children), do: {"div", [{"class", "grid gap-6"}], children}

  defp grid(:columns, children),
    do:
      {"div", [{"class", "grid gap-6 md:grid-cols-#{Enum.count(children, &element?/1)}"}],
       children}

  defp element?(node), do: match?({_tag, _attrs, _children}, node)

  defp piece(name, attrs, raw),
    do: {:piece, %{name: name, attrs: attrs, raw: Enum.map_join(raw, &source/1)}}

  defp source(text) when is_binary(text), do: text
  defp source(node), do: LazyHTML.Tree.to_html([node])

  defp embed(url), do: {"figure", [], [{"a", [{"href", url}], [url]}]}

  defp shortcodes(nodes, ctx),
    do: nodes |> Enum.flat_map(&tokens/1) |> shortcoded(ctx) |> Enum.flat_map(&clean(&1, ctx))

  defp tokens(text) when is_binary(text),
    do: @shortcode |> Regex.split(text, include_captures: true, trim: true) |> Enum.map(&token/1)

  defp tokens(node), do: [node]

  defp token(part), do: @shortcode |> Regex.run(part, capture: :all_but_first) |> tag(part)

  defp tag(["/", name, _attrs], text), do: {:close, String.downcase(name), text}

  defp tag(["", name, attrs], text),
    do: {:open, String.downcase(name), shortcode_attrs(attrs), text}

  defp tag(nil, text), do: text

  defp shortcode_attrs(text),
    do:
      for(
        [_match, name | values] <- Regex.scan(@shortcode_attr, text),
        into: %{},
        do: {String.downcase(name), Enum.join(values)}
      )

  defp shortcoded([], _ctx), do: []

  defp shortcoded([{:open, name, attrs, text} | rest], ctx),
    do: rest |> enclosed(name, []) |> shortcode(name, attrs, text, rest, ctx)

  defp shortcoded([{:close, _name, text} | rest], ctx), do: [text | shortcoded(rest, ctx)]
  defp shortcoded([node | rest], ctx), do: [node | shortcoded(rest, ctx)]

  defp enclosed([], _name, _content), do: :alone

  defp enclosed([{:close, name, text} | rest], name, content),
    do: {:enclosing, content |> Enum.reverse() |> Enum.map(&untokened/1), text, rest}

  defp enclosed([token | rest], name, content), do: enclosed(rest, name, [token | content])

  defp untokened({:open, _name, _attrs, text}), do: text
  defp untokened({:close, _name, text}), do: text
  defp untokened(node), do: node

  defp shortcode({:enclosing, content, close, rest}, name, attrs, open, _rest, ctx),
    do: [
      converted(name, attrs, content, [open | content] ++ [close], ctx) | shortcoded(rest, ctx)
    ]

  defp shortcode(:alone, name, attrs, open, rest, ctx),
    do: [converted(name, attrs, [], [open], ctx) | shortcoded(rest, ctx)]

  defp converted("caption", attrs, [_ | _] = content, _raw, _ctx) do
    {media, words} = Enum.split_with(content, &element?/1)
    {"figure", [], media ++ figcaption(Map.get(attrs, "caption", Enum.join(words)))}
  end

  defp converted("gallery", attrs, _content, raw, ctx),
    do: attrs |> Map.get("ids", "") |> ids() |> gallery(attrs, raw, ctx)

  defp converted("embed", _attrs, [url], _raw, _ctx) when is_binary(url),
    do: url |> String.trim() |> embed()

  defp converted("video", %{"src" => src} = attrs, _content, _raw, _ctx),
    do:
      {"video",
       [{"controls", ""}, {"src", src}] ++
         for(key <- ~w(width height poster), is_map_key(attrs, key), do: {key, attrs[key]}), []}

  defp converted(name, attrs, _content, raw, _ctx), do: piece(name, attrs, raw)

  defp figcaption(caption), do: caption |> String.trim() |> captioned()

  defp captioned(""), do: []
  defp captioned(caption), do: [{"figcaption", [], [caption]}]

  defp ids(ids),
    do:
      for(
        id <- String.split(ids, ","),
        {number, ""} <- [Integer.parse(String.trim(id))],
        do: number
      )

  defp gallery([], attrs, raw, _ctx), do: piece("gallery", attrs, raw)

  defp gallery(ids, attrs, raw, ctx) do
    media = ctx.fetch.("/wp/v2/media", ids)

    ids
    |> Enum.flat_map(&image(Map.get(media, &1), attrs["link"]))
    |> figures(attrs, raw)
  end

  defp figures([], attrs, raw), do: piece("gallery", attrs, raw)
  defp figures(images, _attrs, _raw), do: {"figure", [], images}

  defp image(%{"source_url" => url} = media, link) when is_binary(url),
    do: [
      {"figure", [],
       [linked({"img", [{"src", url}, {"alt", media["alt_text"] || ""}], []}, link, media)]}
    ]

  defp image(_unanswered, _link), do: []

  defp linked(img, "file", %{"source_url" => url}), do: {"a", [{"href", url}], [img]}
  defp linked(img, "none", _media), do: img

  defp linked(img, _attachment_page, %{"link" => page}) when is_binary(page),
    do: {"a", [{"href", page}], [img]}

  defp linked(img, _link, _media), do: img

  defp paragraphs(nodes) do
    {done, open} = Enum.reduce(nodes, {[], []}, &paragraph/2)
    open |> flush(done) |> Enum.reverse()
  end

  defp paragraph(text, {done, open}) when is_binary(text) do
    [first | rest] = String.split(text, @blank_line)
    Enum.reduce(rest, {done, [first | open]}, &broken_off/2)
  end

  defp paragraph(node, {done, open}), do: paragraph(block_level?(node), node, {done, open})

  defp paragraph(true, node, {done, open}), do: {[node | flush(open, done)], []}
  defp paragraph(false, node, {done, open}), do: {done, [node | open]}

  defp broken_off(part, {done, open}), do: {flush(open, done), [part]}

  defp block_level?({:piece, _piece}), do: true
  defp block_level?({tag, _attrs, _children}), do: tag in @block_tags
  defp block_level?(_node), do: false

  defp flush(open, done), do: open |> Enum.reverse() |> trimmed() |> flushed(done)

  defp flushed([], done), do: done
  defp flushed(inline, done), do: [{"p", [], Enum.flat_map(inline, &lines/1)} | done]

  defp trimmed(inline) do
    inline
    |> trim_edge(&String.trim_leading/1)
    |> Enum.reverse()
    |> trim_edge(&String.trim_trailing/1)
    |> Enum.reverse()
  end

  defp trim_edge([text | rest], trim) when is_binary(text),
    do: text |> trim.() |> trimmed_edge(rest, trim)

  defp trim_edge(nodes, _trim), do: nodes

  defp trimmed_edge("", rest, trim), do: trim_edge(rest, trim)
  defp trimmed_edge(text, rest, _trim), do: [text | rest]

  defp lines(text) when is_binary(text),
    do: text |> String.split("\n") |> Enum.intersperse({"br", [], []}) |> Enum.reject(&(&1 == ""))

  defp lines(node), do: [node]
end
