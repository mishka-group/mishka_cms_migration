# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Sources.WordPress.Navigation do
  @moduledoc """
  A block theme's menus as the rows of a menu (`MishkaCmsMigration.Sources.WordPress.menus/4`).

  A block menu is a `wp_navigation` post whose `content.raw` is block comments
  (`MishkaCmsMigration.Sources.WordPress.Content.blocks_in/1` reads them with the HTML parser, never
  by pattern): `core/navigation-link` is a link, `core/navigation-submenu` a link with the links
  under it, and `core/home-link` the site's home. Any other block (a page list, a search box, a
  social link) draws something WordPress works out as it serves the page, so it is not a link of
  the menu and is left out.

  `call/2` answers a row for each post: its `"id"` is `"navigation-"` and the post's id, so it never
  meets the id of a classic menu, its `"name"` the post's title, and `"items"` already nested in
  the shape a classic menu's items are given (`MishkaCmsMigration.Sources.WordPress`'s `"menu"`): a
  link's `"title"`, `"url"`, the `"kind"` and `"id"` of the page, post, category or tag it points at,
  `"new_tab"` and its own `"items"`. A block menu is never the main one, for WordPress sets no theme
  location on it.
  """

  alias MishkaCmsMigration.Sources.WordPress.Content

  @objects %{"page" => "page", "post" => "post", "category" => "category", "tag" => "tag"}

  @doc """
  The menu rows of `posts`, the `wp_navigation` posts as the REST API answers them (or rows of the
  same shape), with `home`, the site's own address, for the home link.
  """
  @spec call([map()], String.t() | nil) :: [map()]
  def call(posts, home), do: Enum.map(posts, &menu(&1, home))

  @doc """
  The links of a menu's `items`, as a sorted list of what each points at: `{:object, kind, id}`
  for a page, post, category or tag, `{:url, address}` for any other. Two menus with the same list
  have the same links, whatever their labels, order and nesting.
  """
  @spec targets([map()]) :: [tuple()]
  def targets(items), do: items |> flat() |> Enum.map(&target/1) |> Enum.sort()

  defp menu(%{"id" => id} = post, home) do
    %{
      "id" => "navigation-#{id}",
      "name" => name(post),
      "slug" => post["slug"],
      "locations" => [],
      "main" => false,
      "block" => true,
      "items" => post |> get_in(["content", "raw"]) |> items(home)
    }
  end

  defp name(%{"title" => %{"raw" => title}}) when is_binary(title) and title != "", do: title
  defp name(%{"slug" => slug}) when is_binary(slug) and slug != "", do: slug
  defp name(_post), do: "Navigation"

  defp items(raw, home) when is_binary(raw), do: raw |> Content.blocks_in() |> entries(home)
  defp items(_none, _home), do: []

  defp entries(blocks, home), do: Enum.flat_map(blocks, &entry(&1, home))

  defp entry({:block, "core/navigation-link", attrs, _inner, _raw}, _home),
    do: [link(attrs, [])]

  defp entry({:block, "core/navigation-submenu", attrs, inner, _raw}, home),
    do: [link(attrs, inner |> List.wrap() |> Content.blocks_in() |> entries(home))]

  defp entry({:block, "core/home-link", attrs, _inner, _raw}, home),
    do: [link(%{"label" => attrs["label"] || "Home", "url" => home}, [])]

  defp entry(_block, _home), do: []

  defp link(attrs, items) do
    {kind, id} = object(attrs)

    %{
      "title" => attrs |> Map.get("label") |> plain(),
      "url" => attrs["url"],
      "kind" => kind,
      "id" => id,
      "new_tab" => attrs["opensInNewTab"] == true,
      "items" => items
    }
  end

  defp object(%{"kind" => kind, "type" => type, "id" => id})
       when kind in ["post-type", "taxonomy"] and is_map_key(@objects, type) and not is_nil(id),
       do: {Map.fetch!(@objects, type), to_string(id)}

  defp object(_attrs), do: {nil, nil}

  defp plain(label) when is_binary(label),
    do: label |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()

  defp plain(_none), do: ""

  defp flat(items), do: Enum.flat_map(items, &[&1 | flat(&1["items"])])

  defp target(%{"kind" => kind, "id" => id}) when is_binary(kind), do: {:object, kind, id}
  defp target(%{"url" => url}) when is_binary(url), do: {:url, String.trim_trailing(url, "/")}
  defp target(_item), do: {:url, ""}
end
