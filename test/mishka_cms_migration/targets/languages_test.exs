# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.LanguagesTest do
  @moduledoc """
  A site that runs Polylang or WPML moved into the CMS, against what the seeded WordPress answered
  for its entries and terms in English and Persian (`rest/polylang-*`, `wxr/polylang.xml`): each
  edition is written in its language and linked to its other editions as one group
  (`language_group_id`), whatever order they come in and whichever an earlier run wrote; a language
  the site does not publish in, and one the source does not say, wait for an admin's decision.

  Polylang Pro's and WPML's REST shapes, and WPML's export, are DERIVED from those recordings
  (`MishkaCmsMigration.Test.Languages`): neither plugin can be installed on the test WordPress.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 1]

  alias MishkaBlog.{BlogPost, Collection, Tag}
  alias MishkaCmsCore.Runtime.{Languages, Page}
  alias MishkaCmsCore.Settings
  alias MishkaCmsMigration.{MigrationItem, MigrationRun}
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

  defp wordpress_run!(site, admin, options \\ %{}) do
    %{source: "wordpress", connection: @connection, secret: "app password", options: options}
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

  defp item(site, kind, source_id),
    do:
      MigrationItem
      |> Ash.read!(tenant: site.id, authorize?: false)
      |> Enum.find(&(&1.source_kind == kind and &1.source_id == source_id))

  defp decide!(site, admin, kind, source_id, choice),
    do:
      site
      |> item(kind, source_id)
      |> MishkaCmsMigration.decide_item!(choice, actor: admin, tenant: site.id)

  defp options(site, kind, source_id),
    do:
      MigrationItem.decision_options(%{
        form: %Phoenix.HTML.Form{data: item(site, kind, source_id)}
      })

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

  describe "a language the site does not publish in" do
    setup %{site: site} do
      languages!(site, ["en"])
      stub_rows!(&Derived.pro_rows/1)
      :ok
    end

    test "leaves each item in it for a decision, in the dry run and the import, and adds nothing",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      waits = {:undecided, "language_missing: fa"}

      assert %{"121" => {:created, _}, "122" => ^waits, "124" => ^waits} = outcomes(run, "post")
      assert %{"125" => {:created, _}, "126" => ^waits, "128" => ^waits} = outcomes(run, "page")
      assert %{"32" => ^waits} = outcomes(run, "category")

      assert options(site, "post", "122") == [
               {"Add Persian to the site", "import"},
               {"Leave this translation out", "leave_out"}
             ]

      assert MigrationRun.reason_label("language_missing: fa") =~ "Persian"

      run = import!(run, admin)

      assert %{"121" => {:created, _}, "122" => ^waits} = outcomes(run, "post")
      assert Languages.site(site.id) == ["en"]

      assert by(BlogPost, site, :title) |> Map.keys() |> Enum.sort() == [
               "A Weekend in Isfahan",
               "Packing Light"
             ]
    end

    test "Add Persian to the site adds it before the item is written, and links the translation",
         %{site: site, admin: admin} do
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, "post", "122", "import")

      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      assert outcomes(run, "post")["122"] ==
               {:created, "language_added: fa; translation_of: A Weekend in Isfahan (en)"}

      assert Languages.site(site.id) == ["en"]

      run = import!(run, admin)

      assert {:created, "language_added: fa" <> _} = outcomes(run, "post")["122"]
      assert Languages.site(site.id) == ["en", "fa"]
      assert groups(BlogPost, site, :title)["آخر هفته‌ای در اصفهان"] == {"fa", @weekend}

      again = imported!(site, admin)
      assert %{"124" => {:created, _}} = outcomes(again, "post")
      assert %{"126" => {:created, _}} = outcomes(again, "page")
    end

    test "Leave this translation out leaves the item out", %{site: site, admin: admin} do
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, "post", "124", "leave_out")

      run = imported!(site, admin)

      assert outcomes(run, "post")["124"] == {:skipped, "left_out_by_admin"}
      assert Languages.site(site.id) == ["en"]
    end
  end

  describe "one language for the run" do
    test "answers every item of a language the site does not publish in with it, asking nothing and deciding nothing per item",
         %{site: site, admin: admin} do
      languages!(site, ["en"])
      stub_rows!(&Derived.pro_rows/1)

      run = site |> wordpress_run!(admin, %{one_language: "en"}) |> dry_run!(admin)

      for kind <- ["post", "page", "category"],
          do:
            assert(
              Enum.all?(outcomes(run, kind), fn {_id, {outcome, _}} -> outcome == :created end)
            )

      assert Enum.all?(
               Ash.read!(MigrationItem, tenant: site.id, authorize?: false),
               &(&1.decisions == %{})
             )

      run = import!(run, admin)

      assert %{"122" => {:created, _}, "124" => {:created, _}} = outcomes(run, "post")
      assert Languages.site(site.id) == ["en"]
      assert by(BlogPost, site, :title) |> Map.values() |> Enum.all?(&(&1.language == "en"))
      assert %{"آخر هفته‌ای در اصفهان" => %{language: "en"}} = by(BlogPost, site, :title)
    end

    test "answers every item whose language the source does not say with it, in the import too",
         %{site: site, admin: admin} do
      languages!(site, ["en", "fa"])
      stub_rows!(&MishkaCmsMigration.Test.WordPress.recorded/1)

      run = site |> wordpress_run!(admin, %{one_language: "fa"}) |> dry_run!(admin)
      assert Enum.all?(outcomes(run, "post"), fn {_id, {outcome, _}} -> outcome == :created end)

      run = import!(run, admin)

      assert %{"122" => {:created, _}, "123" => {:created, _}} = outcomes(run, "post")
      assert by(BlogPost, site, :title) |> Map.values() |> Enum.all?(&(&1.language == "fa"))
    end

    test "keeps the language of an item the source gives in one of the site's languages",
         %{site: site, admin: admin} do
      languages!(site, ["en", "fa"])
      stub_rows!(&Derived.pro_rows/1)

      imported =
        wordpress_run!(site, admin, %{one_language: "en"}) |> dry_run!(admin) |> import!(admin)

      assert %{"122" => {:created, _}} = outcomes(imported, "post")
      assert %{"آخر هفته‌ای در اصفهان" => {"fa", @weekend}} = groups(BlogPost, site, :title)
    end

    test "is ignored when the language is not one of the site's, so the decisions are asked as before",
         %{site: site, admin: admin} do
      languages!(site, ["en", "fa"])
      stub_rows!(&MishkaCmsMigration.Test.WordPress.recorded/1)

      run = site |> wordpress_run!(admin, %{one_language: "de"}) |> dry_run!(admin)

      assert Enum.all?(outcomes(run, "post"), fn {_id, outcome} ->
               outcome == {:undecided, "language_unknown"}
             end)
    end
  end

  describe "a source that runs Polylang but says no language" do
    setup %{site: site} do
      languages!(site, ["en", "fa"])
      stub_rows!(&MishkaCmsMigration.Test.WordPress.recorded/1)
      :ok
    end

    test "leaves each post, page, category and tag for a decision rather than guess its language",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      waits = {:undecided, "language_unknown"}

      for kind <- ["post", "page", "category", "tag"],
          do: assert(Enum.all?(outcomes(run, kind), fn {_id, outcome} -> outcome == waits end))

      assert options(site, "post", "121") == [
               {"Import it in the site's main language", "import"},
               {"Wait, to import the site's export file instead", "keep"}
             ]

      assert MigrationRun.reason_label("language_unknown") =~ "export file"
    end

    test "Import it in the site's main language writes it so, and Wait leaves it for the export",
         %{site: site, admin: admin} do
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, "post", "122", "import")
      decide!(site, admin, "post", "123", "keep")

      run = imported!(site, admin)

      assert %{"122" => {:created, _}, "123" => {:skipped, "waits_for_language"}} =
               outcomes(run, "post")

      assert %{"آخر هفته‌ای در اصفهان" => %{language: "en"}} = by(BlogPost, site, :title)
    end

    test "a page decided on, two levels under one that waits, names the page it waits on and its decision, in the import and in Import this item, and is written once they are",
         %{site: site, admin: admin} do
      stub_rows!(fn
        "polylang-pages" -> MishkaCmsMigration.Test.WordPress.recorded("pages")
        recording -> MishkaCmsMigration.Test.WordPress.recorded(recording)
      end)

      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, "page", "26", "import")
      run = import!(run, admin)

      assert %{
               "24" => {:undecided, "language_unknown"},
               "25" => {:skipped, "parent_undecided: About (#24)"},
               "26" => {:skipped, "parent_undecided: Team (#25)"}
             } = outcomes(run, "page")

      run = import_items!(run, admin, ["26"])
      assert %{reason: "parent_undecided: Team (#25)"} = item(site, "page", "26")

      words = MigrationRun.reason_label("parent_undecided: Team (#25)", "page")
      assert words =~ "Team (#25) needs your decision"

      decide!(site, admin, "page", "25", "import")
      run = import_items!(run, admin, ["25"])
      assert %{reason: "parent_undecided: About (#24)"} = item(site, "page", "25")

      decide!(site, admin, "page", "24", "import")
      run = Enum.reduce(["24", "25", "26"], run, &import_items!(&2, admin, [&1]))

      assert %{outcome: :created, target_id: leadership_id} = item(site, "page", "26")
      assert %{id: ^leadership_id} = by(Page, site, :title)["Leadership"]
      assert run.status == :done
    end

    test "Import anyway writes a page that waits for its parent without it, says so, and Wait for its parent takes it back",
         %{site: site, admin: admin} do
      stub_rows!(fn
        "polylang-pages" -> MishkaCmsMigration.Test.WordPress.recorded("pages")
        recording -> MishkaCmsMigration.Test.WordPress.recorded(recording)
      end)

      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, "page", "26", "import")
      run = import!(run, admin)

      leadership = item(site, "page", "26")
      assert MigrationItem.waits_for_parent(leadership) == "parent_undecided: Team (#25)"
      assert MigrationItem.conflicts(leadership) == ["language_unknown", "parent_missing"]

      assert {:error, %Ash.Error.Invalid{errors: [%{field: :decision}]}} =
               MishkaCmsMigration.decide_item(leadership, "import", %{conflict: "slug_taken"},
                 actor: admin,
                 tenant: site.id
               )

      MishkaCmsMigration.decide_item!(leadership, "import", %{conflict: "parent_missing"},
        actor: admin,
        tenant: site.id
      )

      run = import_items!(run, admin, ["26"])

      assert %{outcome: :created, reason: "without_parent: Team (#25)", target_id: id} =
               item(site, "page", "26")

      assert %{id: ^id} = by(Page, site, :title)["Leadership"]
      assert %{outcome: :undecided, target_id: nil} = item(site, "page", "24")
      assert %{outcome: :skipped, target_id: nil} = item(site, "page", "25")

      assert MigrationRun.reason_label("without_parent: Team (#25)", "page") =~
               "without its parent Team (#25)"

      assert run.status == :done

      decide!(site, admin, "page", "25", "import")

      for choice <- ["import", "keep"],
          do:
            MishkaCmsMigration.decide_item!(
              item(site, "page", "25"),
              choice,
              %{conflict: "parent_missing"},
              actor: admin,
              tenant: site.id
            )

      assert %{"language_unknown" => "import", "parent_missing" => "keep"} =
               item(site, "page", "25").decisions

      import_items!(run, admin, ["25"])

      assert %{outcome: :skipped, reason: "parent_undecided: About (#24)"} =
               item(site, "page", "25")
    end

    test "one decision answers every page that waits for it, read in one query, and one import then writes each under its parent",
         %{site: site, admin: admin} do
      stub_rows!(fn
        "polylang-pages" -> MishkaCmsMigration.Test.WordPress.recorded("pages")
        recording -> MishkaCmsMigration.Test.WordPress.recorded(recording)
      end)

      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      pages = Enum.count(outcomes(run, "page"), &match?({_id, {:undecided, _conflict}}, &1))

      {groups, queries} =
        with_queries(fn -> MigrationItem.waiting_groups(run, admin) end)

      assert length(queries) == 1
      assert {:ok, groups} = groups
      assert %{count: ^pages} = Enum.find(groups, &(&1.kind == "page"))
      assert Enum.all?(groups, &(&1.conflict == "language_unknown"))

      assert {:ok, [%{kind: "page", count: 1}]} =
               MigrationItem.waiting_groups(run, admin, "leadership")

      assert {:ok, ^pages} =
               MigrationItem.decide_waiting(run, admin, "language_unknown", "import",
                 kinds: ["page"]
               )

      assert {:ok, groups} = MigrationItem.waiting_groups(run, admin)
      refute Enum.any?(groups, &(&1.kind == "page"))
      assert Enum.any?(groups, &(&1.kind == "post"))

      assert {:ok, 0} =
               MigrationItem.decide_waiting(run, admin, "language_unknown", "import",
                 kinds: ["page"]
               )

      run = import!(run, admin)

      assert %{"24" => {:created, _}, "25" => {:created, _}, "26" => {:created, _}} =
               outcomes(run, "page")

      assert {:undecided, "language_unknown"} = hd(Map.values(outcomes(run, "post")))
    end

    test "an item's parents are read with it in one query, the top one first, and a parent the source does not list ends them",
         %{site: site, admin: admin} do
      stub_rows!(fn
        "polylang-pages" ->
          "pages"
          |> MishkaCmsMigration.Test.WordPress.recorded()
          |> Enum.reject(&(&1["id"] == 24))

        recording ->
          MishkaCmsMigration.Test.WordPress.recorded(recording)
      end)

      site |> wordpress_run!(admin) |> dry_run!(admin)
      leadership = item(site, "page", "26")

      {{:ok, loaded}, queries} =
        with_queries(fn -> MigrationItem.fetch(leadership.id, admin, [:ancestors]) end)

      assert length(queries) == 2
      assert Enum.count(queries, &(&1 =~ "WITH RECURSIVE")) == 1

      assert [{nil, "24", :not_listed}, {_id, "25", :undecided}] =
               Enum.map(loaded.ancestors, &{&1.id, &1.source_id, MigrationItem.standing(&1)})

      assert Ash.load!(item(site, "page", "29"), :ancestors, actor: admin, tenant: site.id).ancestors ==
               nil
    end
  end

  defp with_queries(fun) do
    me = self()
    queries = queries_while(fn -> send(me, {:result, fun.()}) end)
    assert_received {:result, result}
    {result, queries}
  end

  defp import_items!(run, admin, page_ids) do
    ids = for id <- page_ids, do: item(%{id: run.site_id}, "page", id).id
    MishkaCmsMigration.import_items!(run, ids, actor: admin, tenant: run.site_id)
    %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
    MishkaCmsMigration.get_run!(run.id, tenant: run.site_id, authorize?: false)
  end

  defp staged!(path) do
    staged =
      Path.join(System.tmp_dir!(), "gervaz_#{System.unique_integer([:positive])}_export.xml")

    File.cp!(path, staged)
    on_exit(fn -> File.rm(staged) end)
    staged
  end
end
