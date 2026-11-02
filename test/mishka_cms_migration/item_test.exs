# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.ItemTest do
  @moduledoc """
  The normalized item every source hands over: what it accepts and cleans, what it refuses, and
  what its hash says about whether the source changed an item.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsMigration.Source.Item

  defp build!(attrs) do
    {:ok, item} = Item.build(Map.merge(%{kind: "post", source_id: "1"}, attrs))
    item
  end

  test "keeps a source id as a string and cleans the title" do
    assert %Item{source_id: "12", title: "Hello"} = build!(%{source_id: 12, title: "  Hello  "})
  end

  test "keeps its parent's source id as a string, none as nil, and refuses one that is not an id" do
    assert %Item{parent: "7"} = build!(%{parent: 7})
    assert %Item{parent: "7"} = build!(%{parent: "7"})
    assert %Item{parent: nil} = build!(%{parent: nil})
    assert %Item{parent: nil} = build!(%{})

    assert {:error, [%{field: :parent}]} =
             Item.build(%{kind: "post", source_id: "1", parent: [7]})
  end

  test "takes string keys and keeps the keys of attrs as they are" do
    assert {:ok, %Item{attrs: %{"slug" => "hello", "parent" => %{"id" => 3}}}} =
             Item.build(%{
               "kind" => "post",
               "source_id" => "1",
               "attrs" => %{"slug" => "hello", "parent" => %{"id" => 3}}
             })
  end

  test "refuses an item without an id, a key it does not know, or a content piece it does not know" do
    assert {:error, [%{field: :source_id}]} = Item.build(%{kind: "post"})
    assert {:error, [%{field: :slug}]} = Item.build(%{kind: "post", source_id: "1", slug: "x"})

    assert {:error, [%{field: :content}]} =
             Item.build(%{kind: "post", source_id: "1", content: [%{html: "<p/>", style: "x"}]})
  end

  test "reads the modified time from a DateTime, a naive one or an ISO 8601 string" do
    expected = ~U[2024-05-06 07:08:09Z]

    for value <- [
          expected,
          ~N[2024-05-06 07:08:09],
          "2024-05-06T07:08:09Z",
          "2024-05-06T07:08:09"
        ] do
      assert DateTime.compare(build!(%{modified_at: value}).modified_at, expected) == :eq
    end

    assert {:error, [%{field: :modified_at}]} =
             Item.build(%{kind: "post", source_id: "1", modified_at: "last week"})
  end

  test "its hash changes with what the source says, not with when it said it" do
    item = build!(%{title: "Hello", content: [%{html: "<p>a</p>"}]})

    assert Item.hash(item) == Item.hash(%{item | modified_at: DateTime.utc_now()})
    refute Item.hash(item) == Item.hash(%{item | title: "Hello again"})
    refute Item.hash(item) == Item.hash(%{item | parent: "7"})
    refute Item.hash(item) == Item.hash(build!(%{title: "Hello", content: [%{html: "<p>b</p>"}]}))
  end

  test "joins the html of its content pieces in order" do
    item =
      build!(%{
        content: [%{html: "<p>a</p>"}, %{name: "gallery", raw: "[gallery]"}, %{html: "<p>b</p>"}]
      })

    assert Item.html(item) == "<p>a</p><p>b</p>"
    assert Item.html(build!(%{})) == ""
  end
end
