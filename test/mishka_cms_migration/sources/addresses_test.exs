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

    assert map_size(rows) == 3
    assert Enum.all?(Map.values(rows), &(&1["to"] == %{"kind" => "post", "id" => "36"}))

    draft = Enum.find(recorded("posts"), &(&1["status"] == "draft"))
    assert [%{"from" => nil}] = Addresses.post(draft)
  end

  test "a term and an author are their archive and their query, and a file its attachment page" do
    category =
      Enum.find(recorded("categories"), &(&1["slug"] == "%d8%a2%d9%85%d9%88%d8%b2%d8%b4"))

    rows = category |> Addresses.term("category", category["link"]) |> by_id()
    key = "category:#{category["id"]}"

    assert rows[key]["from"] == "/category/%d8%a2%d9%85%d9%88%d8%b2%d8%b4/"
    assert rows[key <> "?cat"]["query"] == "cat=#{category["id"]}"

    tag = hd(recorded("tags"))
    assert [_archive, %{"query" => query}] = Addresses.term(tag, "tag", tag["link"])
    assert query == "tag=#{tag["slug"]}"

    file = hd(recorded("media"))
    rows = file |> Addresses.media() |> by_id()

    assert rows["media:#{file["id"]}"]["from"] == URI.parse(file["link"]).path
    assert rows["media:#{file["id"]}?attachment_id"]["query"] == "attachment_id=#{file["id"]}"
  end

  test "the feeds and the month and year archives point at the list, under the structure's front" do
    posts = [
      %{"date" => "2026-02-02T10:00:00", "status" => "publish"},
      %{"date" => "2026-03-01T10:00:00", "status" => "publish"},
      %{"date" => "2099-05-01T10:00:00", "status" => "future"}
    ]

    paths = fn structure ->
      posts |> Addresses.archives(structure, nil) |> Enum.map(& &1["from"])
    end

    assert paths.("/%year%/%monthnum%/%postname%/") ==
             ["/feed", "/comments/feed", "/2026", "/2026/02", "/2026/03"]

    assert "/archives/date/2026/02" in paths.("/archives/%post_id%")
    assert "/2026/02" in paths.("/%postname%/")

    assert Enum.all?(
             Addresses.archives(posts, nil, "https://example.com/news"),
             &(String.starts_with?(&1["from"], "/news/") and
                 &1["to"] == %{"kind" => "list", "id" => nil})
           )
  end
end
