# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.LanguagesTest do
  @moduledoc """
  A site that runs Polylang or WPML moved into the CMS, against what the seeded WordPress answered
  for its entries and terms in English and Persian (`rest/polylang-*`, `wxr/polylang.xml`): each
  edition is written in its language and linked to its other editions as one group
  (`language_group_id`), whatever order they come in and whichever an earlier run wrote, and the
  dry run says which item is a translation of which.

  Polylang Pro's and WPML's REST shapes, and WPML's export, are DERIVED from those recordings
  (`MishkaCmsMigration.Test.Languages`): neither plugin can be installed on the test WordPress.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 1]

  alias MishkaBlog.{BlogPost, Collection, Tag}
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Settings
  alias MishkaCmsMigration.MigrationRun
  alias MishkaCmsMigration.Test.Languages, as: Derived

  @connection %{"url" => "http://localhost:8089", "user" => "admin"}
  @admin [
    "admin:dashboard:migration",
    "admin:dashboard:runtime:page",
    "admin:dashboard:blog:post",
    "admin:dashboard:setting"
  ]
  @none {"application/json", "[]"}
  @empty %{
    "/wp-json/wp/v2/media" => @none,
    "/wp-json/wp/v2/comments" => @none,
    "/wp-json/wp/v2/menus" => @none,
    "/wp-json/wp/v2/menu-items" => @none,
    "/wp-json/wp/v2/navigation" => @none
  }
  @routes %{
    "/wp-json/wp/v2/posts" => "polylang-posts",
    "/wp-json/wp/v2/pages" => "polylang-pages",
    "/wp-json/wp/v2/categories" => "polylang-categories",
    "/wp-json/wp/v2/tags" => "polylang-tags"
  }

  setup do
    site = create_site!()
    %{site: site, admin: migration_admin!(site, @admin)}
  end

  defp languages!(site, languages),
    do: Settings.put("site.languages", languages, site_id: site.id, category: "general")

  defp stub_rows!(rows_of) do
    answers =
      Map.new(@routes, fn {route, recording} ->
        {route, {"application/json", recording |> rows_of.() |> Jason.encode!()}}
      end)

    stub!(@empty |> Map.merge(answers) |> Map.put("/wp-json/", "polylang-index"))
  end

  defp wordpress_run!(site, admin) do
    %{source: "wordpress", connection: @connection, secret: "app password", options: %{}}
    |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)
  end

  defp imported!(site, admin),
    do: site |> wordpress_run!(admin) |> dry_run!(admin) |> import!(admin)

  defp outcomes(run, kind),
    do:
      for(
        %{kind: ^kind} = entry <- run.report.entries,
        into: %{},
        do: {entry.source_id, {entry.outcome, entry.reason}}
      )

  defp by(resource, site, field),
    do:
      resource
      |> Ash.read!(tenant: site.id, authorize?: false)
      |> Map.new(&{Map.fetch!(&1, field), &1})

  # Each record's language, and the titles of the records of its group, itself among them.
  defp groups(resource, site, field) do
    records = by(resource, site, field)
    grouped = records |> Map.values() |> Enum.group_by(& &1.language_group_id)

    Map.new(records, fn {name, record} ->
      {name,
       {record.language,
        grouped[record.language_group_id] |> Enum.map(&Map.fetch!(&1, field)) |> Enum.sort()}}
    end)
  end

  @weekend ["A Weekend in Isfahan", "آخر هفته‌ای در اصفهان"]
  @story ["Our Story", "داستان ما"]
  @crew ["Our Crew", "همسفران ما"]

  describe "an import" do
    setup %{site: site} do
      languages!(site, ["en", "fa"])
      stub_rows!(&Derived.pro_rows/1)
      :ok
    end

    test "writes each post, page, category and tag in its language, each translation linked to its other editions as one group",
         %{site: site, admin: admin} do
      imported!(site, admin)

      assert %{
               "A Weekend in Isfahan" => {"en", @weekend},
               "آخر هفته‌ای در اصفهان" => {"fa", @weekend},
               "Packing Light" => {"en", ["Packing Light"]},
               "یادداشت سفر" => {"fa", ["یادداشت سفر"]}
             } = groups(BlogPost, site, :title)

      assert %{
               "Our Story" => {"en", @story},
               "داستان ما" => {"fa", @story},
               "Our Crew" => {"en", @crew},
               "همسفران ما" => {"fa", @crew}
             } = groups(Page, site, :title)

      assert %{"Travel" => {"en", ["Travel", "سفر"]}, "سفر" => {"fa", ["Travel", "سفر"]}} =
               groups(Collection, site, :name)

      assert %{"Coffee" => {"en", ["Coffee", "قهوه"]}, "قهوه" => {"fa", ["Coffee", "قهوه"]}} =
               groups(Tag, site, :name)
    end

    test "keeps the group's key the id of one of its editions, so the core's own list shows one row for it",
         %{site: site, admin: admin} do
      imported!(site, admin)

      posts = by(BlogPost, site, :title)
      [en, fa] = Enum.map(@weekend, &posts[&1])

      assert en.language_group_id == fa.language_group_id
      assert en.language_group_id in [en.id, fa.id]

      masters = posts |> Map.values() |> Enum.filter(&(&1.language_group_id == &1.id))
      assert length(masters) == 3
    end

    test "puts a translation under the categories and the page of its own language",
         %{site: site, admin: admin} do
      imported!(site, admin)

      fa =
        BlogPost
        |> Ash.read!(tenant: site.id, authorize?: false, load: [:tenant_collections])
        |> Enum.find(&(&1.title == "آخر هفته‌ای در اصفهان"))

      assert Enum.map(fa.tenant_collections, & &1.name) == ["سفر"]

      pages = by(Page, site, :title)
      assert pages["Our Crew"].path == "/our-story/our-crew"
      assert String.starts_with?(pages["همسفران ما"].path, pages["داستان ما"].path <> "/")
      assert String.starts_with?(pages["داستان ما"].path, "/fa/")
    end

    test "links the editions whatever order the source lists them, and to an edition an earlier run wrote",
         %{site: site, admin: admin} do
      stub_rows!(fn recording ->
        recording |> Derived.pro_rows() |> Enum.reject(&(&1["lang"] == "fa"))
      end)

      imported!(site, admin)

      [en] =
        BlogPost
        |> Ash.read!(tenant: site.id, authorize?: false)
        |> Enum.filter(&(&1.title == "A Weekend in Isfahan"))

      stub_rows!(fn recording -> recording |> Derived.pro_rows() |> Enum.reverse() end)
      run = imported!(site, admin)

      assert %{"122" => {:created, _}} = outcomes(run, "post")
      assert groups(BlogPost, site, :title)["آخر هفته‌ای در اصفهان"] == {"fa", @weekend}
      assert by(BlogPost, site, :title)["آخر هفته‌ای در اصفهان"].language_group_id == en.id

      again = imported!(site, admin)
      assert outcomes(again, "post")["122"] == {:skipped, "unchanged"}
      assert groups(BlogPost, site, :title)["A Weekend in Isfahan"] == {"en", @weekend}
    end

    test "of an export of the site links the same groups", %{site: site, admin: admin} do
      run =
        MishkaCmsMigration.create_run!(
          %{
            source: "wordpress_file",
            file: [%{path: staged!(Derived.export()), client_name: "export.xml"}]
          },
          actor: admin,
          tenant: site.id
        )

      on_exit(fn -> File.rm(run.connection["file"]) end)

      run |> dry_run!(admin) |> import!(admin)

      assert groups(BlogPost, site, :title)["آخر هفته‌ای در اصفهان"] == {"fa", @weekend}
      assert groups(Page, site, :title)["همسفران ما"] == {"fa", @crew}
      assert groups(Collection, site, :name)["سفر"] == {"fa", ["Travel", "سفر"]}
    end
  end

  describe "WPML" do
    setup %{site: site} do
      languages!(site, ["en", "fa"])
      :ok
    end

    test "over its REST API plugin links each translation to its other editions (derived rows)",
         %{site: site, admin: admin} do
      stub_rows!(fn
        recording when recording in ["polylang-posts", "polylang-pages"] ->
          Derived.wpml_rows(recording)

        recording ->
          Derived.pro_rows(recording)
      end)

      imported!(site, admin)

      assert groups(BlogPost, site, :title)["آخر هفته‌ای در اصفهان"] == {"fa", @weekend}
      assert groups(Page, site, :title)["داستان ما"] == {"fa", @story}
    end

    test "from its export links each translation to its other editions (derived export)",
         %{site: site, admin: admin} do
      run =
        MishkaCmsMigration.create_run!(
          %{
            source: "wordpress_file",
            file: [%{path: staged!(Derived.wpml_export!()), client_name: "export.xml"}]
          },
          actor: admin,
          tenant: site.id
        )

      on_exit(fn -> File.rm(run.connection["file"]) end)
      run = run |> dry_run!(admin) |> import!(admin)

      assert run.extra["languages"] == "wpml"
      assert groups(BlogPost, site, :title)["آخر هفته‌ای در اصفهان"] == {"fa", @weekend}
      assert groups(Tag, site, :name)["قهوه"] == {"fa", ["Coffee", "قهوه"]}
    end
  end

  describe "a dry run" do
    setup %{site: site} do
      languages!(site, ["en", "fa"])
      stub_rows!(&Derived.pro_rows/1)
      :ok
    end

    test "says which item is a translation of which, and writes nothing", %{
      site: site,
      admin: admin
    } do
      site |> wordpress_run!(admin) |> dry_run!(admin)
      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      assert %{
               "121" => {:created, "translations: fa"},
               "122" => {:created, "translation_of: A Weekend in Isfahan (en)"},
               "123" => {:created, nil},
               "124" => {:created, nil}
             } = outcomes(run, "post")

      assert MigrationRun.reason_label("translation_of: A Weekend in Isfahan (en)") ==
               "Translation of A Weekend in Isfahan (en)"

      assert MigrationRun.reason_label("translations: fa") =~ "Persian"
      assert BlogPost |> Ash.read!(tenant: site.id, authorize?: false) == []
    end
  end

  defp staged!(path) do
    staged =
      Path.join(System.tmp_dir!(), "gervaz_#{System.unique_integer([:positive])}_export.xml")

    File.cp!(path, staged)
    on_exit(fn -> File.rm(staged) end)
    staged
  end
end
