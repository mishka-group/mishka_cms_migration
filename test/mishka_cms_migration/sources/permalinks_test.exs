# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Sources.PermalinksTest do
  @moduledoc """
  The permalink structure worked out from the recorded site's published posts and categories
  (`rest/posts`, `rest/categories`), their links written as the seeded WordPress served them under
  each structure WordPress offers. The address of post 35 under each one is the one the site
  answered when its structure was switched (`/2026/02/02/linking-between-posts-and-media/`,
  `/archives/35`, `/tutorials/wordpress/migration/linking-between-posts-and-media/`, ...).
  """
  use ExUnit.Case, async: true

  import MishkaCmsMigration.Test.WordPress, only: [recorded: 1]

  alias MishkaCmsMigration.Sources.WordPress.Permalinks

  @home "http://localhost:8089"

  # Each structure with what WordPress puts in a post's address for it, and post 35's address the
  # site answered under it.
  @structures [
    {"/%year%/%monthnum%/%day%/%postname%/", "/:year/:monthnum/:day/:slug",
     "/2026/02/02/linking-between-posts-and-media/"},
    {"/%year%/%monthnum%/%postname%/", "/:year/:monthnum/:slug",
     "/2026/02/linking-between-posts-and-media/"},
    {"/archives/%post_id%", "/archives/:post_id", "/archives/35"},
    {"/%postname%/", "/:slug", "/linking-between-posts-and-media/"},
    {"/%category%/%postname%/", "/:category/:slug",
     "/tutorials/wordpress/migration/linking-between-posts-and-media/"},
    {"/index.php/%year%/%monthnum%/%postname%/", "/index.php/:year/:monthnum/:slug",
     "/index.php/2026/02/linking-between-posts-and-media/"}
  ]

  defp categories, do: Map.new(recorded("categories"), &{&1["id"], {&1["slug"], &1["parent"]}})

  defp published, do: Enum.filter(recorded("posts"), &(&1["status"] == "publish"))

  defp category_path(id, categories) do
    {slug, parent} = Map.fetch!(categories, id)
    if parent == 0, do: slug, else: category_path(parent, categories) <> "/" <> slug
  end

  # A post's address under `structure`, written as WordPress writes it: its first category's
  # path, the lowest id, for `%category%`.
  defp linked(post, structure, categories) do
    <<year::binary-4, "-", month::binary-2, "-", day::binary-2, _time::binary>> = post["date"]

    path =
      Enum.reduce(
        [
          {"%year%", year},
          {"%monthnum%", month},
          {"%day%", day},
          {"%postname%", post["slug"]},
          {"%post_id%", to_string(post["id"])},
          {"%category%", post["categories"] |> Enum.min() |> category_path(categories)}
        ],
        structure,
        fn {tag, value}, path -> String.replace(path, tag, value) end
      )

    Map.put(post, "link", @home <> path)
  end

  defp site(posts, terms \\ %{}, languages \\ []),
    do: %{
      posts: posts,
      categories: categories(),
      terms: terms,
      home: @home,
      languages: languages
    }

  test "each structure WordPress offers is found from the posts' addresses, as a path the CMS serves" do
    categories = categories()

    for {structure, pattern, post_35} <- @structures do
      posts = Enum.map(published(), &linked(&1, structure, categories))
      assert Enum.find(posts, &(&1["id"] == 35))["link"] == @home <> post_35

      assert %{
               "structure" => ^structure,
               "pattern" => ^pattern,
               "misfits" => [],
               "language_prefixes" => []
             } = Permalinks.call(site(posts))
    end
  end

  test "the posts the site addressed as it does are read as the site's addresses, a Persian slug among them" do
    assert %{
             "structure" => "/%year%/%monthnum%/%postname%/",
             "pattern" => "/:year/:monthnum/:slug",
             "posts" => 17,
             "misfits" => []
           } = Permalinks.call(site(published()))
  end

  test "a post whose address has another structure, or names neither its slug nor its id, does not fit" do
    [moved, plain | rest] = published()
    moved = Map.put(moved, "link", @home <> "/news/" <> moved["slug"] <> "/")
    plain = Map.put(plain, "link", @home <> "/?p=#{plain["id"]}")

    assert %{"structure" => "/%year%/%monthnum%/%postname%/", "misfits" => misfits} =
             Permalinks.call(site([moved, plain | rest]))

    assert Enum.sort(misfits) ==
             Enum.sort([
               %{"id" => to_string(moved["id"]), "link" => moved["link"]},
               %{"id" => to_string(plain["id"]), "link" => plain["link"]}
             ])
  end

  test "a language's prefix in front of a post's address is not part of the structure" do
    posts = recorded("polylang-posts")

    assert %{
             "structure" => "/%year%/%monthnum%/%postname%/",
             "language_prefixes" => ["fa"],
             "misfits" => []
           } = Permalinks.call(site(posts, %{}, ["en", "fa"]))

    assert %{"misfits" => [_, _]} = Permalinks.call(site(posts, %{}, []))
  end

  test "a site at a folder of its host has its posts' addresses read under that folder" do
    posts =
      Enum.map(published(), fn post ->
        %{post | "link" => String.replace(post["link"], @home, @home <> "/news-site")}
      end)

    assert %{"structure" => "/%year%/%monthnum%/%postname%/", "misfits" => []} =
             Permalinks.call(%{site(posts) | home: @home <> "/news-site"})
  end

  test "the category and tag bases are read from the terms' addresses, a language's prefix left out" do
    terms = %{
      "category" =>
        Enum.map(
          recorded("categories") ++ recorded("polylang-categories"),
          &%{"key" => &1["id"], "link" => &1["link"]}
        ),
      "tag" => recorded("tags") ++ recorded("polylang-tags")
    }

    categories =
      Map.merge(
        categories(),
        Map.new(recorded("polylang-categories"), &{&1["id"], {&1["slug"], &1["parent"]}})
      )

    assert %{"category_base" => "category", "tag_base" => "tag"} =
             Permalinks.call(%{site(published(), terms, ["en", "fa"]) | categories: categories})

    renamed = %{
      "category" =>
        Enum.map(
          terms["category"],
          &%{&1 | "link" => String.replace(&1["link"], "/category/", "/topics/")}
        ),
      "tag" =>
        Enum.map(terms["tag"], &%{&1 | "link" => String.replace(&1["link"], "/tag/", "/labels/")})
    }

    assert %{"category_base" => "topics", "tag_base" => "labels"} =
             Permalinks.call(%{site(published(), renamed, ["en", "fa"]) | categories: categories})
  end

  test "without term addresses the bases are WordPress's own, behind the structure's literal start" do
    assert %{"category_base" => "category", "tag_base" => "tag"} =
             Permalinks.call(site(published()))

    posts = Enum.map(published(), &linked(&1, "/archives/%post_id%", categories()))

    assert %{"category_base" => "archives/category", "tag_base" => "archives/tag"} =
             Permalinks.call(site(posts))
  end

  test "a site with no published post has no structure, and nothing fits it" do
    assert %{"structure" => nil, "pattern" => nil, "posts" => 0, "misfits" => []} =
             Permalinks.call(site([]))
  end
end
