# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Sources.AddressesTest do
  @moduledoc """
  The addresses a WordPress visitor or search engine knows, made from rows the seeded WordPress
  answered (`test/fixtures/wordpress/rest`): each one names what it points at, the query it is
  only with, and the address WordPress gave it, a Persian one included.
  """
  use ExUnit.Case, async: true

  import MishkaCmsMigration.Test.WordPress, only: [recorded: 1]

  alias MishkaCmsMigration.Sources.WordPress.Addresses

  defp post(id), do: Enum.find(recorded("posts"), &(&1["id"] == id))
  defp by_id(rows), do: Map.new(rows, &{&1["id"], &1})

  test "a published post is its link, the addresses of its earlier slugs and its ?p=, and a draft has no address" do
    persian = post(36)

    rows =
      persian
      |> Map.put("old_slugs", ["%d8%b3%d9%84%d8%a7%d9%85", persian["slug"]])
      |> Addresses.post()
      |> by_id()

    assert rows["36"]["from"] == URI.parse(persian["link"]).path
    assert rows["36?p"] |> Map.take(["from", "query"]) == %{"from" => "/", "query" => "p=36"}

    assert rows["36~%d8%b3%d9%84%d8%a7%d9%85"]["from"] ==
             "/2026/02/%d8%b3%d9%84%d8%a7%d9%85/"

    assert rows["36/feed"]["from"] == String.trim_trailing(rows["36"]["from"], "/") <> "/feed"
    assert map_size(rows) == 4
    assert Enum.all?(Map.values(rows), &(&1["to"] == %{"kind" => "post", "id" => "36"}))

    paged =
      persian
      |> Map.put("content", %{"raw" => "one<!--nextpage-->two<!--nextpage-->three"})
      |> Addresses.post()
      |> by_id()

    assert paged["36/3"]["from"] == String.trim_trailing(rows["36"]["from"], "/") <> "/3"
    assert paged["36/2"]["to"] == %{"kind" => "post", "id" => "36"}
    refute is_map_key(paged, "36/4")

    draft = Enum.find(recorded("posts"), &(&1["status"] == "draft"))
    assert [%{"from" => nil}] = Addresses.post(draft)
  end

  test "a post's comment pages are its top comments over a page's count, each sent to the post" do
    post = post(50)
    path = post["link"] |> URI.parse() |> Map.fetch!(:path) |> String.trim_trailing("/")

    pages = fn comments, per_page ->
      post
      |> Map.put("comments", comments)
      |> Addresses.post(per_page)
      |> by_id()
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "50/comment-page-"))
      |> Enum.sort()
    end

    rows = post |> Map.put("comments", 25) |> Addresses.post(10) |> by_id()

    assert pages.(25, 10) == ~w(50/comment-page-1 50/comment-page-2 50/comment-page-3)
    assert rows["50/comment-page-3"]["from"] == path <> "/comment-page-3"
    assert rows["50/comment-page-2"]["to"] == %{"kind" => "post", "id" => "50"}

    assert pages.(30, 10) == ~w(50/comment-page-1 50/comment-page-2 50/comment-page-3)
    assert pages.(1, 50) == ["50/comment-page-1"]
    assert pages.(0, 50) == []
    assert pages.(25, nil) == []
    assert post |> Map.put("comments", 25) |> Addresses.post() |> by_id() |> map_size() == 3

    draft = Enum.find(recorded("posts"), &(&1["status"] == "draft"))
    assert [%{"from" => nil}] = draft |> Map.put("comments", 25) |> Addresses.post(10)

    assert Addresses.comments_per_page(%{comment_pages: true, comments_per_page: 20}) == 20
    assert Addresses.comments_per_page(%{comment_pages: false, comments_per_page: 20}) == nil
    assert Addresses.comments_per_page(nil) == nil
  end

  test "a term and an author are their archive and their query, and a file its attachment page" do
    category =
      Enum.find(recorded("categories"), &(&1["slug"] == "%d8%a2%d9%85%d9%88%d8%b2%d8%b4"))

    rows = category |> Addresses.term("category", category["link"]) |> by_id()
    key = "category:#{category["id"]}"

    assert rows[key]["from"] == "/category/%d8%a2%d9%85%d9%88%d8%b2%d8%b4/"
    assert rows[key <> "?cat"]["query"] == "cat=#{category["id"]}"

    tag = hd(recorded("tags"))

    assert [_archive, %{"query" => query}, %{"from" => feed}] =
             Addresses.term(tag, "tag", tag["link"])

    assert query == "tag=#{tag["slug"]}"
    assert feed == "/tag/#{tag["slug"]}/feed"

    pages = tag |> Map.put("count", 21) |> Addresses.term("tag", tag["link"]) |> by_id()
    assert pages["tag:#{tag["id"]}/page/3"]["from"] == "/tag/#{tag["slug"]}/page/3"

    assert pages["tag:#{tag["id"]}/page/3"]["to"] == %{
             "kind" => "tag",
             "id" => "#{tag["id"]}",
             "page" => 3
           }

    refute is_map_key(pages, "tag:#{tag["id"]}/page/4")

    file = hd(recorded("media"))
    rows = file |> Addresses.media() |> by_id()

    assert rows["media:#{file["id"]}"]["from"] == URI.parse(file["link"]).path
    assert rows["media:#{file["id"]}?attachment_id"]["query"] == "attachment_id=#{file["id"]}"
  end

  test "the feeds, the date archives and the list's pages point at the list, under the structure's front" do
    posts =
      [
        %{"date" => "2026-02-02T10:00:00", "status" => "publish"},
        %{"date" => "2026-03-01T10:00:00", "status" => "publish"},
        %{"date" => "2099-05-01T10:00:00", "status" => "future"}
      ] ++ List.duplicate(%{"date" => "2026-03-01T10:00:00", "status" => "publish"}, 9)

    paths = fn structure ->
      posts |> Addresses.archives(structure, nil) |> Enum.map(& &1["from"])
    end

    all = paths.("/%year%/%monthnum%/%postname%/")

    for path <-
          ~w(/feed /feed/atom /rss2 /comments/feed /2026 /2026/02 /2026/02/02 /2026/02/feed /page/2),
        do: assert(path in all, path)

    refute "/page/3" in all
    refute "/2099" in all
    assert "/archives/date/2026/02" in paths.("/archives/%post_id%")
    assert "/2026/02" in paths.("/%postname%/")

    rows =
      posts
      |> Addresses.archives(nil, "https://example.com/news", "https://example.com/news/blog/")
      |> by_id()

    assert rows["archive:/news/page/2"]["to"] == %{"kind" => "list", "id" => nil, "page" => 2}

    assert rows["archive:/news/blog/page/2"]["to"] == %{
             "kind" => "list",
             "id" => nil,
             "page" => 2
           }

    assert rows["archive:/news/blog/feed"]["to"] == %{"kind" => "list", "id" => nil}
    assert rows["archive:/news/wp-sitemap.xml"]["to"] == %{"kind" => "sitemap", "id" => nil}
    assert Enum.all?(Map.values(rows), &String.starts_with?(&1["from"], "/news/"))
  end
end
