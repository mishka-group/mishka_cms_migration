# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Sources.WordPress.Addresses do
  @moduledoc """
  The addresses a WordPress visitor or search engine knows, as the rows of the `"post_redirect"`
  kind: one row for each address, which the redirect target answers with a 301 when the site does
  not serve it as it is (`MishkaCmsMigration.Targets.PostRedirect`).

  Each row is a map with string keys:

    * `"id"` — the address's own id, which the item keeps as its `source_id`: a post's own address
      is the post's id (`"35"`), and every other names what it points at and how
      (`"35?p"`, `"35~hello-world"`, `"category:8"`, `"tag:12?tag"`, `"archive:/2026/02"`);
    * `"title"` — what it points at, as the Items page names it;
    * `"from"` — the address, a path or a link whose path is taken (`nil` for one with no address
      of its own, such as a draft's `/?p=39`);
    * `"query"` — the query string the address is only with, on `/` (`"p=35"`), or `nil`;
    * `"to"` — what it points at, `%{"kind" => kind, "id" => id}`: a `"post"`, `"page"`,
      `"category"`, `"tag"`, `"user"` or `"media"` by its WordPress id, or `"list"`, the Blog's
      list of posts, with no id;
    * `"modified_gmt"` — when what it points at last changed, where the row says.

  What each kind of row gives:

    * a post — its `link` (`/2026/02/hello/`), the address it had under each earlier slug
      (WordPress's `_wp_old_slug`, as `"old_slugs"`: `/2026/02/hello-world/`) and, once published,
      `/?p=<id>`;
    * a published page — `/?page_id=<id>` (its own address is kept as the page's path);
    * a category, a tag and an author — its archive's address, the term's or user's `link` or, for
      an export, which carries none, the one its base and slug make (`/category/tutorials/news/`
      with its parents), and `/?cat=<id>`, `/?tag=<slug>` or `/?author=<id>`;
    * a file — its attachment page (its `link`) and `/?attachment_id=<id>`;
    * the published posts as a whole (`archives/3`) — the site's feeds, `/feed` and
      `/comments/feed`, and the archive of each year and month a post was published in, under the
      structure's front as WordPress puts them (`/2026/02`, `/archives/date/2026/02` for
      `/archives/%post_id%`): the Blog has neither, so they point at its list.
  """

  @doc "The addresses of a post row (see the module doc)."
  @spec post(map()) :: [map()]
  def post(%{"id" => id} = row) do
    from = own_path(row)

    [rule(row, to_string(id), from, nil, "post")] ++
      for(
        {old_slug, old} <- old_paths(from, row),
        do: rule(row, "#{id}~#{old_slug}", old, nil, "post")
      ) ++ queried(row, "#{id}?p", "p=#{id}", "post")
  end

  @doc "The addresses of a page row: `/?page_id=<id>` once it is published."
  @spec page(map()) :: [map()]
  def page(%{"id" => id} = row), do: queried(row, "page:#{id}", "page_id=#{id}", "page")

  @doc """
  The addresses of a category, tag or user row of `kind` (`"category"`, `"tag"` or `"user"`), its
  archive at `from` (its `link`, or the address its base and slug make) and its query address.
  """
  @spec term(map(), String.t(), String.t() | nil) :: [map()]
  def term(%{"id" => id} = row, kind, from) do
    key = "#{kind}:#{id}"
    row = Map.put_new(row, "status", "publish")

    [
      rule(row, key, own_link(from), nil, kind)
      | queried(row, key <> "?" <> param(kind), query(row, kind), kind)
    ]
  end

  @doc "The addresses of a file row: its attachment page and `/?attachment_id=<id>`."
  @spec media(map()) :: [map()]
  def media(%{"id" => id} = row) do
    row = Map.put(row, "status", "publish")
    key = "media:#{id}"

    [rule(row, key, own_link(row["link"]), nil, "media")] ++
      queried(row, key <> "?attachment_id", "attachment_id=#{id}", "media")
  end

  @doc """
  The feeds and the date archives of the published `posts` (one whose `"status"` is another is
  left out), each `"date"` (the site's own time) and `"link"`,
  under `structure` (`"/%year%/%monthnum%/%postname%/"`, or `nil`) on a site at `home`.
  """
  @spec archives([map()], String.t() | nil, String.t() | nil) :: [map()]
  def archives(posts, structure, home) do
    root = home |> own_link() |> Kernel.||("") |> String.trim_trailing("/")
    front = root <> date_front(structure)

    dated =
      for %{"date" => date} = post when is_binary(date) <- posts,
          Map.get(post, "status", "publish") == "publish",
          <<year::binary-size(4), "-", month::binary-size(2), _rest::binary>> <- [date],
          path <- [front <> year, front <> year <> "/" <> month],
          uniq: true,
          do: path

    for path <- [root <> "/feed", root <> "/comments/feed" | Enum.sort(dated)],
        do: %{
          "id" => "archive:" <> path,
          "title" => path,
          "from" => path,
          "query" => nil,
          "to" => %{"kind" => "list", "id" => nil},
          "modified_gmt" => nil
        }
  end

  # WordPress moves its date archives under `date/` when `%post_id%` is one of the structure's first
  # three tags, so the two cannot be read as each other.
  defp date_front(structure) when is_binary(structure) do
    literal = structure |> String.split("%") |> hd()
    tags = Regex.scan(~r/%[^%]+%/, structure) |> List.flatten() |> Enum.take(3)

    literal <> dated_under("%post_id%" in tags)
  end

  defp date_front(_none), do: "/"

  defp dated_under(true), do: "date/"
  defp dated_under(false), do: ""

  defp rule(row, id, from, query, kind),
    do: %{
      "id" => id,
      "title" => title(row),
      "from" => from,
      "query" => query,
      "to" => %{"kind" => kind, "id" => to_string(row["id"])},
      "modified_gmt" => row["modified_gmt"]
    }

  defp queried(%{"status" => "publish"} = row, id, query, kind),
    do: [rule(row, id, "/", query, kind)]

  defp queried(_unpublished, _id, _query, _kind), do: []

  defp param("category"), do: "cat"
  defp param("tag"), do: "tag"
  defp param("user"), do: "author"

  defp query(row, "tag"), do: "tag=#{row["slug"]}"
  defp query(row, kind), do: "#{param(kind)}=#{row["id"]}"

  defp title(%{"title" => %{"raw" => title}}), do: title
  defp title(%{"title" => title}) when is_binary(title), do: title
  defp title(%{"name" => name}) when is_binary(name), do: name
  defp title(row), do: row["slug"]

  defp own_path(%{"status" => "publish", "link" => link}), do: own_link(link)
  defp own_path(_not_public), do: nil

  defp own_link(link) when is_binary(link), do: link |> URI.parse() |> path_of()
  defp own_link(_none), do: nil

  defp path_of(%URI{path: "/" <> rest = path}) when rest != "", do: path
  defp path_of(_no_path), do: nil

  defp old_paths("/" <> _ = path, %{"slug" => slug, "old_slugs" => [_ | _] = old_slugs})
       when is_binary(slug) do
    segments = String.split(path, "/")
    current = decoded(slug)

    for old_slug <- old_slugs,
        decoded(old_slug) != current,
        renamed = Enum.map(segments, &renamed(&1, current, old_slug)),
        renamed != segments,
        uniq: true,
        do: {old_slug, Enum.join(renamed, "/")}
  end

  defp old_paths(_no_path, _row), do: []

  defp renamed(segment, current, old_slug),
    do: segment |> decoded() |> Kernel.==(current) |> old_segment(segment, old_slug)

  defp old_segment(true, _segment, old_slug), do: old_slug
  defp old_segment(false, segment, _old_slug), do: segment

  defp decoded(text), do: text |> URI.decode() |> valid_or(text)

  defp valid_or(decoded, text), do: decoded |> String.valid?() |> valid_or(decoded, text)

  defp valid_or(true, decoded, _text), do: decoded
  defp valid_or(false, _decoded, text), do: text
end
