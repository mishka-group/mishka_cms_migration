# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Sources.LanguagesTest do
  @moduledoc """
  The language and the other editions each page, post, category and tag of a site that runs
  Polylang or WPML is read with, against what the seeded WordPress answered with Polylang's free
  plugin (`rest/polylang-*`, `wxr/polylang.xml`): the export carries both, the free plugin's REST
  API neither. Polylang Pro's and WPML's shapes are DERIVED from those recordings
  (`MishkaCmsMigration.Test.Languages`), as neither can be installed on the test WordPress.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 1, recorded: 1]

  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Sources.{WordPress, WordPressFile}
  alias MishkaCmsMigration.Test.Languages

  @connection %{"url" => "http://localhost:8089", "user" => "admin"}
  @context %{site_id: nil, run_id: nil, source_host: "localhost:8089", options: %{}}
  @recordings %{
    "post" => "polylang-posts",
    "page" => "polylang-pages",
    "category" => "polylang-categories",
    "tag" => "polylang-tags"
  }

  # The editions the seed made: each source id's language and the other editions by language.
  @editions %{
    "post" => %{
      "121" => {"en", %{"fa" => "122"}},
      "122" => {"fa", %{"en" => "121"}},
      "123" => {"en", %{}},
      "124" => {"fa", %{}}
    },
    "page" => %{
      "125" => {"en", %{"fa" => "126"}},
      "126" => {"fa", %{"en" => "125"}},
      "127" => {"en", %{"fa" => "128"}},
      "128" => {"fa", %{"en" => "127"}}
    },
    "category" => %{"30" => {"en", %{"fa" => "32"}}, "32" => {"fa", %{"en" => "30"}}},
    "tag" => %{"34" => {"en", %{"fa" => "36"}}, "36" => {"fa", %{"en" => "34"}}}
  }

  defp connected! do
    stub!(%{"/wp-json/" => "polylang-index"})
    {:ok, conn} = WordPress.connect(@connection, "app password")
    conn
  end

  defp items!(source, conn, rows, kind) do
    Map.new(rows, fn row ->
      assert {:ok, attrs} = source.normalize(row, kind, Map.put(@context, :conn, conn))
      assert {:ok, item} = attrs |> Map.put(:kind, kind) |> Item.build()
      {item.source_id, item}
    end)
  end

  defp editions(items),
    do:
      Map.new(items, fn {id, item} ->
        {id, {item.attrs["language"], item.attrs["translations"]}}
      end)

  defp file_items!(path, kind) do
    assert {:ok, conn} = WordPressFile.connect(%{"file" => path}, nil)
    assert {:ok, rows, nil} = WordPressFile.list(conn, kind, nil)
    items!(WordPressFile, conn, rows, kind)
  end

  describe "the REST API" do
    test "of Polylang's free plugin says no entry's or term's language, while its index names Polylang" do
      conn = connected!()

      assert WordPress.extra(conn)["languages"] == "polylang"

      for {kind, recording} <- @recordings do
        items = items!(WordPress, conn, recorded(recording), kind)

        assert map_size(items) == map_size(@editions[kind])
        assert Enum.all?(items, fn {_id, item} -> not Map.has_key?(item.attrs, "language") end)
      end
    end

    test "of Polylang Pro gives each one its language and its other editions (derived rows)" do
      conn = connected!()

      for {kind, recording} <- @recordings do
        items = items!(WordPress, conn, Languages.pro_rows(recording), kind)

        assert editions(items) == @editions[kind]
        assert Enum.all?(items, fn {_id, item} -> not Map.has_key?(item.extra, "lang") end)
      end
    end

    test "with the WPML REST API plugin gives each entry its language, from its locale, and its other editions (derived rows)" do
      conn = connected!()

      for kind <- ["post", "page"] do
        items = items!(WordPress, conn, Languages.wpml_rows(@recordings[kind]), kind)

        assert editions(items) == @editions[kind]

        assert Enum.all?(items, fn {_id, item} ->
                 not Map.has_key?(item.extra, "wpml_translations")
               end)
      end
    end
  end

  describe "an export" do
    test "of Polylang gives each entry and term its language and its other editions, and names Polylang" do
      assert {:ok, conn} = WordPressFile.connect(%{"file" => Languages.export()}, nil)
      assert WordPressFile.extra(conn)["languages"] == "polylang"

      for {kind, editions} <- @editions do
        items = file_items!(Languages.export(), kind)
        assert Map.take(editions(items), Map.keys(editions)) == editions
      end
    end

    test "of Polylang leaves a term in no group without a language, as Polylang exports none for it" do
      items = file_items!(Languages.export(), "category")

      assert %Item{title: "News"} = news = items["2"]
      refute Map.has_key?(news.attrs, "language")
      assert items["1"].attrs["language"] == "en"
    end

    test "reads the same languages over the REST API of Polylang Pro and from the export" do
      conn = connected!()

      for {kind, recording} <- @recordings do
        rest = items!(WordPress, conn, Languages.pro_rows(recording), kind)
        file = kind |> then(&file_items!(Languages.export(), &1)) |> Map.take(Map.keys(rest))

        assert editions(file) == editions(rest)
      end
    end

    test "of WPML gives each entry and term its language and its other editions, and names WPML (derived export)" do
      path = Languages.wpml_export!()

      assert {:ok, conn} = WordPressFile.connect(%{"file" => path}, nil)
      assert WordPressFile.extra(conn)["languages"] == "wpml"

      for {kind, editions} <- @editions do
        items = file_items!(path, kind)
        assert Map.take(editions(items), Map.keys(editions)) == editions

        assert Enum.all?(items, fn {_id, item} ->
                 not Map.has_key?(item.extra["meta"] || %{}, "_wpml_import_language_code")
               end)
      end
    end
  end
end
