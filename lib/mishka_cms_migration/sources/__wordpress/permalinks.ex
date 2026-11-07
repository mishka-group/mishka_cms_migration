# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Sources.WordPress.Permalinks do
  @moduledoc """
  The addresses a WordPress site gives its posts and terms, worked out from the addresses
  themselves: WordPress's REST API does not answer its permalink settings and an export does not
  carry them, but every published post's `link` is its permalink structure filled in.

  `call/1` compares each published post's address, without the site's home and a language's
  prefix, with what the post is: its slug, its id, its date (the site's own time, as WordPress
  fills `%year%` and the rest) and the path of each of its categories with their parents
  (`tutorials/wordpress/migration`). Each segment that is one of these becomes its tag, read left
  to right, each tag once, and any other segment stays as it is:
  `/2026/02/linking-between-posts-and-media/` is `/%year%/%monthnum%/%postname%/`,
  `/archives/35` is `/archives/%post_id%` and `/index.php/tutorials/elixir/hello/` is
  `/index.php/%category%/%postname%/`. A slug written in another script is compared decoded, so a
  Persian address fits as an English one does.

  The structure most posts share is the site's, and the posts whose address names no slug or id
  or has another structure are the ones that do not fit. A segment of a language the site runs
  (`/fa/` of Polylang) in front of a post's address is a language's prefix, not part of the
  structure.

  A term's address is its base followed by the term: a category's by its path with its parents,
  a tag's by its slug. The base most terms share is the site's (`category`, `tag`, or another
  the site set); a site whose terms carry no address, as in an export, has WordPress's own, in
  front of which WordPress puts the structure's literal start (`archives/category` under
  `/archives/%post_id%`).
  """

  @identifying ["%postname%", "%post_id%"]

  @captures %{
    "%postname%" => ":slug",
    "%post_id%" => ":post_id",
    "%year%" => ":year",
    "%monthnum%" => ":monthnum",
    "%day%" => ":day",
    "%hour%" => ":hour",
    "%minute%" => ":minute",
    "%second%" => ":second",
    "%category%" => ":category"
  }

  @typedoc """
  What `call/1` reads, every key a string-keyed map's own:

    * `:posts` — the published posts, each `"id"`, `"slug"` (as WordPress keeps it, percent-encoded
      or not), `"date"` (ISO 8601, the site's own time), `"link"` and `"categories"`, the keys of
      its categories in `:categories`;
    * `:categories` — each category by its key (its id, or its slug where the source names
      parents by slug) as `{slug, parent_key}`, the parent's key `nil` or `0` at the top;
    * `:terms` — the terms whose address the source knows: `"category"`, each `%{"key", "link"}`,
      and `"tag"`, each `%{"slug", "link"}`;
    * `:home` — the site's home address;
    * `:languages` — the codes of the languages the site runs, which may lead an address.
  """
  @type site :: %{
          posts: [map()],
          categories: %{term() => {String.t(), term()}},
          terms: %{String.t() => [map()]},
          home: String.t() | nil,
          languages: [String.t()]
        }

  @doc """
  The site's addresses, as a run keeps them in its `extra` under `"permalinks"`:

    * `"structure"` — WordPress's permalink structure, such as `"/%year%/%monthnum%/%postname%/"`
      (`nil` when no published post fits one);
    * `"pattern"` — the same as a path the CMS serves, each tag a capture: `"/:year/:monthnum/:slug"`
      (`%postname%` is `:slug`, `%category%` is `:category`, each other tag its own name).
      WordPress fills `%category%` with the category's path and its parents', several segments
      for a nested one (`tutorials/wordpress/migration`), where a `:category` capture takes one.
      `%author%` is not compared, so a structure that names it fits only the posts of one author;
    * `"language_prefixes"` — the language codes met in front of a post's address, such as `["fa"]`;
    * `"category_base"` and `"tag_base"` — what comes before a term in its address, `"category"`
      and `"tag"` by default;
    * `"posts"` — how many published posts were compared;
    * `"misfits"` — each post that does not fit the structure, its `"id"` and `"link"`.
  """
  @spec call(site()) :: map()
  def call(%{posts: posts, categories: categories, terms: terms, home: home} = site) do
    home_path = home |> path_of() |> segments()
    languages = Map.get(site, :languages, [])

    fitted =
      Enum.map(posts, fn post ->
        {post, structure(post, categories, home_path, languages)}
      end)

    {structure, _count} = shared(for {_post, {_prefix, fit}} <- fitted, do: fit)

    %{
      "structure" => written(structure),
      "pattern" => pattern(structure),
      "language_prefixes" =>
        for({_post, {prefix, ^structure}} <- fitted, prefix != nil, uniq: true, do: prefix)
        |> Enum.sort(),
      "category_base" =>
        base(
          terms["category"],
          &chain(&1["key"], categories),
          home_path,
          languages,
          structure,
          "category"
        ),
      "tag_base" =>
        base(terms["tag"], &[decoded(&1["slug"])], home_path, languages, structure, "tag"),
      "posts" => length(posts),
      "misfits" =>
        for(
          {post, {_prefix, fit}} <- fitted,
          fit == nil or fit != structure,
          do: %{"id" => to_string(post["id"]), "link" => post["link"]}
        )
    }
  end

  defp structure(post, categories, home_path, languages) do
    {trailing, path} = post["link"] |> path_of() |> trailing()

    {prefix, rest} =
      path |> segments() |> Enum.map(&decoded/1) |> without(home_path) |> language(languages)

    chains = Enum.map(post["categories"] || [], &chain(&1, categories))

    {prefix, rest |> tokens(values(post), chains) |> identifying() |> closed(trailing)}
  end

  defp values(post) do
    date = post["date"] || ""

    [
      {"%postname%", decoded(post["slug"] || "")},
      {"%post_id%", to_string(post["id"])},
      {"%year%", binary_part_or(date, 0, 4)},
      {"%monthnum%", binary_part_or(date, 5, 2)},
      {"%day%", binary_part_or(date, 8, 2)},
      {"%hour%", binary_part_or(date, 11, 2)},
      {"%minute%", binary_part_or(date, 14, 2)},
      {"%second%", binary_part_or(date, 17, 2)}
    ]
  end

  defp binary_part_or(text, start, length) when byte_size(text) >= start + length,
    do: binary_part(text, start, length)

  defp binary_part_or(_text, _start, _length), do: nil

  defp tokens([], _values, _chains), do: []

  defp tokens(segments, values, chains),
    do: chains |> Enum.find(&List.starts_with?(segments, &1)) |> chained(segments, values, chains)

  defp chained([_ | _] = chain, segments, values, _chains),
    do: ["%category%" | tokens(Enum.drop(segments, length(chain)), values, [])]

  defp chained(_no_chain, [segment | rest], values, chains),
    do: values |> List.keyfind(segment, 1) |> token(segment, rest, values, chains)

  defp token({tag, _value}, _segment, rest, values, chains),
    do: [tag | tokens(rest, List.keydelete(values, tag, 0), chains)]

  defp token(nil, segment, rest, values, chains), do: [segment | tokens(rest, values, chains)]

  defp identifying(tokens), do: tokens |> Enum.any?(&(&1 in @identifying)) |> kept(tokens)

  defp kept(true, tokens), do: tokens
  defp kept(false, _tokens), do: nil

  defp closed(nil, _trailing), do: nil
  defp closed(tokens, trailing), do: {tokens, trailing}

  defp shared([]), do: {nil, 0}

  defp shared(structures),
    do:
      structures
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.max_by(fn {structure, count} -> {count, structure} end, fn -> {nil, 0} end)

  defp written(nil), do: nil
  defp written({tokens, trailing}), do: "/" <> Enum.join(tokens, "/") <> trailing

  defp pattern(nil), do: nil

  defp pattern({tokens, _trailing}),
    do: "/" <> Enum.map_join(tokens, "/", &Map.get(@captures, &1, &1))

  defp base(links, tail, home_path, languages, structure, default) do
    for(
      term <- links || [],
      path = term["link"] |> path_of() |> segments() |> Enum.map(&decoded/1),
      {_prefix, rest} = path |> without(home_path) |> language(languages),
      ending = tail.(term),
      ending != [] and List.ends_with?(rest, ending),
      do: rest |> Enum.drop(-length(ending)) |> Enum.join("/")
    )
    |> shared()
    |> found_base(structure, default)
  end

  defp found_base({nil, 0}, structure, default), do: front(structure) <> default
  defp found_base({base, _count}, _structure, _default), do: base

  defp front({tokens, _trailing}),
    do:
      tokens
      |> Enum.take_while(&(not String.starts_with?(&1, "%")))
      |> Enum.map_join(&(&1 <> "/"))

  defp front(nil), do: ""

  defp chain(key, categories), do: chain(key, categories, [])

  defp chain(key, categories, seen),
    do: categories |> Map.get(key) |> linked(key in seen, key, categories, seen)

  defp linked({slug, parent}, false, key, categories, seen),
    do: chain(parent, categories, [key | seen]) ++ [decoded(slug)]

  defp linked(_top_or_loop, _seen?, _key, _categories, _seen), do: []

  defp language([code | rest] = segments, languages) when rest != [],
    do: code |> Kernel.in(languages) |> prefixed(code, segments)

  defp language(segments, _languages), do: {nil, segments}

  defp prefixed(true, code, [code | rest]), do: {code, rest}
  defp prefixed(false, _code, segments), do: {nil, segments}

  defp without(segments, home_path),
    do: segments |> List.starts_with?(home_path) |> under_home(segments, home_path)

  defp under_home(true, segments, home_path), do: Enum.drop(segments, length(home_path))
  defp under_home(false, segments, _home_path), do: segments

  defp trailing(path), do: {path |> String.ends_with?("/") |> slash(), path}

  defp slash(true), do: "/"
  defp slash(false), do: ""

  defp path_of(link) when is_binary(link), do: URI.parse(link).path || ""
  defp path_of(_none), do: ""

  defp segments(path), do: String.split(path, "/", trim: true)

  defp decoded(text), do: text |> URI.decode() |> valid_or(text)

  defp valid_or(decoded, text), do: decoded |> String.valid?() |> valid_or(decoded, text)

  defp valid_or(true, decoded, _text), do: decoded
  defp valid_or(false, _decoded, text), do: text
end
