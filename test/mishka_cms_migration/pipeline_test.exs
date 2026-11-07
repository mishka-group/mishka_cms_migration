# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.PipelineTest do
  @moduledoc """
  A run end to end over the fake source, with its redirect rows written as the CMS's own redirect
  rules: what a dry run reports and leaves alone, what an import writes and records, and what a
  second run does with what the first one wrote.
  """
  use MishkaCmsMigration.DataCase, async: false

  alias MishkaCmsCore.Runtime.Redirect
  alias MishkaCmsMigration.{Events, MigrationItem}
  alias MishkaCmsMigration.Targets.CmsPage
  alias MishkaCmsMigration.Test.Plugins.{FakeSource, ItemGate, PageTarget}
  alias MishkaCmsMigration.Workers.{DryRunWorker, ImportWorker}

  setup do
    for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)

    site = create_site!()
    %{site: site, admin: migration_admin!(site)}
  end

  defp redirects(site) do
    Redirect
    |> Ash.Query.sort(:from_path)
    |> Ash.read!(tenant: site.id, authorize?: false)
  end

  defp items(site) do
    MigrationItem
    |> Ash.Query.sort(:source_id)
    |> Ash.read!(tenant: site.id, authorize?: false)
  end

  defp refuse_run_update!(condition, message) do
    Repo.query!("""
    CREATE FUNCTION refuse_run_update() RETURNS trigger AS $$
    BEGIN
      IF #{condition} THEN
        RAISE EXCEPTION '#{message}';
      END IF;
      RETURN NEW;
    END $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER refuse_run_update BEFORE UPDATE ON mishka_cms_migration_runs
    FOR EACH ROW EXECUTE FUNCTION refuse_run_update()
    """)
  end

  defp outcomes(run), do: Map.new(run.report.entries, &{&1.source_id, {&1.outcome, &1.reason}})

  @rows [
    %{"id" => 1, "from" => "/old-one", "to" => "/one"},
    %{"id" => 2, "from" => "/old-two", "to" => "/two"},
    %{"id" => 3, "from" => "/old-three", "to" => "/three"}
  ]

  describe "a dry run" do
    test "reports every item as a create, records it as the item's plan, and writes nothing in the CMS",
         %{site: site, admin: admin} do
      run = site |> create_run!(admin, %{"redirect" => @rows}) |> dry_run!(admin)

      assert run.status == :dry_run
      assert run.report.counts == %{created: 3, updated: 0, skipped: 0, failed: 0, undecided: 0}
      assert [%{kind: "redirect", created: 3}] = run.report.kinds
      assert Enum.map(run.report.entries, & &1.source_id) == ["1", "2", "3"]
      assert redirects(site) == []
      assert imported_items(site) == []

      assert Enum.map(items(site), &{&1.source_id, &1.title, &1.plan, &1.plan_reason}) == [
               {"1", nil, :created, nil},
               {"2", nil, :created, nil},
               {"3", nil, :created, nil}
             ]

      assert {run.created_count, run.skipped_count} == {0, 0}
    end

    test "records why it would skip or fail an item as its plan, and leaves a row with no id out",
         %{site: site, admin: admin} do
      items = %{
        "redirect" => [%{"id" => 1, "unreadable" => true}, %{"from" => "/no-id", "to" => "/x"}],
        "note" => [%{"id" => 9, "title" => "A note"}]
      }

      site |> create_run!(admin, items) |> dry_run!(admin)

      assert [%{source_kind: "note", source_id: "9", plan: :skipped, plan_reason: "no_target"}] =
               items(site)
    end

    test "leaves what an import recorded, and the import keeps the plan", %{
      site: site,
      admin: admin
    } do
      first = migrate!(site, admin, %{"redirect" => @rows})
      imported = Map.new(items(site), &{&1.source_id, &1})

      changed =
        List.replace_at(@rows, 1, %{"id" => 2, "from" => "/old-two", "to" => "/two-moved"})

      later = site |> create_run!(admin, %{"redirect" => changed}) |> dry_run!(admin)

      for item <- items(site) do
        before = imported[item.source_id]

        assert Map.take(item, [:run_id, :outcome, :reason, :target_id, :content_hash]) ==
                 Map.take(before, [:run_id, :outcome, :reason, :target_id, :content_hash])

        assert item.run_id == first.id
      end

      assert Map.new(items(site), &{&1.source_id, {&1.plan, &1.plan_reason}}) == %{
               "1" => {:skipped, "unchanged"},
               "2" => {:updated, nil},
               "3" => {:skipped, "unchanged"}
             }

      import!(later, admin)

      assert Map.new(items(site), &{&1.source_id, {&1.outcome, &1.plan}}) == %{
               "1" => {:skipped, :skipped},
               "2" => {:updated, :updated},
               "3" => {:skipped, :skipped}
             }
    end

    test "saves its progress page by page, which the run's notifier broadcasts", %{
      site: site,
      admin: admin
    } do
      run = create_run!(site, admin, %{"redirect" => @rows})
      :ok = MishkaCmsMigration.TestEndpoint.subscribe("migration_run:#{site.id}:updated")
      run_id = run.id

      dry_run!(run, admin)

      for created <- [2, 3] do
        assert_receive %Phoenix.Socket.Broadcast{
          payload: %{
            data: %{id: ^run_id, progress: %{kind: "redirect", counts: %{created: ^created}}}
          }
        }
      end
    end

    test "walks the kinds in the order the source lists them", %{site: site, admin: admin} do
      items = %{
        "category" => [%{"id" => 3, "title" => "News", "slug" => "news"}],
        "page" => [%{"id" => 5, "title" => "About", "path" => "/about"}],
        "note" => [%{"id" => 9}],
        "redirect" => [%{"id" => 1, "from" => "/a", "to" => "/b"}]
      }

      run = site |> create_run!(admin, items) |> dry_run!(admin)

      assert Enum.map(run.report.kinds, & &1.kind) == FakeSource.kinds()
      assert Enum.map(run.report.entries, & &1.kind) == FakeSource.kinds()
    end

    test "skips a kind no target writes and fails a row the source cannot read", %{
      site: site,
      admin: admin
    } do
      items = %{
        "redirect" => [%{"id" => 1, "unreadable" => true}],
        "note" => [%{"id" => 9, "title" => "A note"}]
      }

      run = site |> create_run!(admin, items) |> dry_run!(admin)

      assert run.report.counts == %{created: 0, updated: 0, skipped: 1, failed: 1, undecided: 0}
      assert %{nil => {:failed, "unreadable"}, "9" => {:skipped, "no_target"}} = outcomes(run)
    end
  end

  describe "an item an admin left out" do
    defp item!(site, source_id), do: Enum.find(items(site), &(&1.source_id == source_id))

    defp leave_out!(site, admin, source_id),
      do:
        site
        |> item!(source_id)
        |> MishkaCmsMigration.leave_out_item!(actor: admin, tenant: site.id)

    test "is skipped by the dry run and the import and never written, until it is brought back",
         %{
           site: site,
           admin: admin
         } do
      run = site |> create_run!(admin, %{"redirect" => @rows}) |> dry_run!(admin)
      leave_out!(site, admin, "2")

      run = dry_run!(run, admin)
      assert %{"2" => {:skipped, "left_out_by_admin"}, "1" => {:created, nil}} = outcomes(run)
      assert %{plan: :skipped, plan_reason: "left_out_by_admin"} = item!(site, "2")

      run = import!(run, admin)
      assert run.report.counts == %{created: 2, updated: 0, skipped: 1, failed: 0, undecided: 0}
      assert Enum.map(redirects(site), & &1.from_path) == ["/old-one", "/old-three"]
      assert %{outcome: :skipped, reason: "left_out_by_admin", target_id: nil} = item!(site, "2")

      site |> item!("2") |> MishkaCmsMigration.bring_back_item!(actor: admin, tenant: site.id)
      again = migrate!(site, admin, %{"redirect" => @rows})

      assert %{"2" => {:created, nil}, "1" => {:skipped, "unchanged"}} = outcomes(again)
      assert length(redirects(site)) == 3
    end

    test "keeps the CMS record an import wrote, whatever the source and the admin changed since",
         %{
           site: site,
           admin: admin
         } do
      migrate!(site, admin, %{"redirect" => @rows})
      written = Enum.find(redirects(site), &(&1.from_path == "/old-one"))
      leave_out!(site, admin, "1")

      changed =
        List.replace_at(@rows, 0, %{"id" => 1, "from" => "/old-one", "to" => "/from-source"})

      run = migrate!(site, admin, %{"redirect" => changed})

      assert %{"1" => {:skipped, "left_out_by_admin"}} = outcomes(run)
      assert Enum.find(redirects(site), &(&1.id == written.id)).to == "/one"

      assert %{left_out: true, target_id: target_id, outcome: :skipped} = item!(site, "1")
      assert target_id == written.id
    end

    test "is reported by kind, so the run's card says how many were left out", %{
      site: site,
      admin: admin
    } do
      run = site |> create_run!(admin, %{"redirect" => @rows}) |> dry_run!(admin)
      for id <- ["1", "3"], do: leave_out!(site, admin, id)

      run = dry_run!(run, admin)

      assert [%{kind: "redirect", created: 1, skipped: 2}] = run.report.kinds
      assert Enum.count(run.report.entries, &(&1.reason == "left_out_by_admin")) == 2
    end
  end

  describe "an import" do
    test "writes every item through the target as the admin and records it", %{
      site: site,
      admin: admin
    } do
      run = migrate!(site, admin, %{"redirect" => @rows})

      assert run.status == :done
      assert run.report.counts == %{created: 3, updated: 0, skipped: 0, failed: 0, undecided: 0}
      assert run.created_count == 3
      assert MishkaCmsMigration.MigrationRun.open_secret(run) == {:ok, "letmein"}
      assert %DateTime{} = run.finished_at

      assert [{"/old-one", "/one"}, {"/old-three", "/three"}, {"/old-two", "/two"}] =
               Enum.map(redirects(site), &{&1.from_path, &1.to})

      by_id = Map.new(redirects(site), &{&1.id, &1})

      for item <- items(site) do
        assert item.outcome == :created
        assert item.run_id == run.id
        assert item.target_resource == inspect(Redirect)
        assert DateTime.compare(by_id[item.target_id].updated_at, item.target_updated_at) == :eq
      end
    end

    test "runs again as an update of what changed and a skip of what did not", %{
      site: site,
      admin: admin
    } do
      first = migrate!(site, admin, %{"redirect" => @rows})
      written = Map.new(redirects(site), &{&1.from_path, &1.id})

      changed =
        List.replace_at(@rows, 1, %{"id" => 2, "from" => "/old-two", "to" => "/two-moved"})

      second = migrate!(site, admin, %{"redirect" => changed})

      assert second.report.counts == %{
               created: 0,
               updated: 1,
               skipped: 2,
               failed: 0,
               undecided: 0
             }

      assert %{"2" => {:updated, nil}, "1" => {:skipped, "unchanged"}} = outcomes(second)
      assert Map.new(redirects(site), &{&1.from_path, &1.id}) == written
      assert Enum.find(redirects(site), &(&1.from_path == "/old-two")).to == "/two-moved"
      assert length(items(site)) == 3
      assert {second.updated_count, second.skipped_count} == {1, 2}
      assert first.id != second.id
    end

    test "a dry run of a second run reports the update and the skips", %{site: site, admin: admin} do
      migrate!(site, admin, %{"redirect" => @rows})

      changed =
        List.replace_at(@rows, 0, %{"id" => 1, "from" => "/old-one", "to" => "/elsewhere"})

      run = site |> create_run!(admin, %{"redirect" => changed}) |> dry_run!(admin)

      assert run.report.counts == %{created: 0, updated: 1, skipped: 2, failed: 0, undecided: 0}
      assert Enum.find(redirects(site), &(&1.from_path == "/old-one")).to == "/one"
    end

    test "never overwrites a row an admin changed in the CMS after the import", %{
      site: site,
      admin: admin
    } do
      migrate!(site, admin, %{"redirect" => @rows})
      edited = Enum.find(redirects(site), &(&1.from_path == "/old-one"))

      edited
      |> Ash.Changeset.for_update(:update, %{to: "/kept-by-admin"}, actor: admin, tenant: site.id)
      |> Ash.update!()

      changed =
        List.replace_at(@rows, 0, %{"id" => 1, "from" => "/old-one", "to" => "/from-source"})

      run = migrate!(site, admin, %{"redirect" => changed})

      assert %{"1" => {:skipped, "edited_in_cms"}} = outcomes(run)
      assert Enum.find(redirects(site), &(&1.id == edited.id)).to == "/kept-by-admin"
    end

    test "does not bring back a row archived or deleted in the CMS after the import: each waits for the admin's decision",
         %{site: site, admin: admin} do
      migrate!(site, admin, %{"redirect" => @rows})
      deleted = Enum.find(redirects(site), &(&1.from_path == "/old-one"))
      Ash.destroy!(deleted, actor: admin, tenant: site.id)

      changed = List.replace_at(@rows, 0, %{"id" => 1, "from" => "/old-one", "to" => "/again"})
      run = migrate!(site, admin, %{"redirect" => changed})

      assert %{"1" => {:undecided, "archived_in_cms"}} = outcomes(run)
      refute Enum.any?(redirects(site), &(&1.from_path == "/old-one"))

      Ash.destroy!(deleted, action: :permanent_destroy, actor: admin, tenant: site.id)
      run = migrate!(site, admin, %{"redirect" => changed})

      assert %{"1" => {:undecided, "deleted_in_cms"}} = outcomes(run)
      refute Enum.any?(redirects(site), &(&1.from_path == "/old-one"))
    end

    test "records a row the CMS action refuses as failed, with its reason, and goes on", %{
      site: site,
      admin: admin
    } do
      rows = [%{"id" => 1, "from" => "/loop", "to" => "/loop"} | tl(@rows)]
      run = migrate!(site, admin, %{"redirect" => rows})

      assert run.status == :done
      assert run.report.counts == %{created: 2, updated: 0, skipped: 0, failed: 1, undecided: 0}
      assert %{"1" => {:failed, reason}} = outcomes(run)
      assert reason =~ ": "
      refute reason =~ "Error returned from"

      assert %{outcome: :failed, target_id: nil, reason: ^reason} =
               Enum.find(items(site), &(&1.source_id == "1"))

      assert length(redirects(site)) == 2
    end

    test "keeps each item's title, whether it was written, refused or left out", %{
      site: site,
      admin: admin
    } do
      items = %{
        "redirect" => [
          %{"id" => 1, "title" => "Moved", "from" => "/old", "to" => "/new"},
          %{"id" => 2, "title" => "Loop", "from" => "/loop", "to" => "/loop"}
        ],
        "note" => [%{"id" => 9, "title" => "A note"}]
      }

      migrate!(site, admin, items)

      assert Map.new(items(site), &{&1.source_id, {&1.outcome, &1.title}}) == %{
               "1" => {:created, "Moved"},
               "2" => {:failed, "Loop"},
               "9" => {:skipped, "A note"}
             }
    end

    test "writes a source id listed twice once, on the same page or a later one", %{
      site: site,
      admin: admin
    } do
      rows = [
        %{"id" => 1, "from" => "/dup-a", "to" => "/a"},
        %{"id" => 1, "from" => "/dup-b", "to" => "/b"},
        %{"id" => 2, "from" => "/two", "to" => "/2"},
        %{"id" => 1, "from" => "/dup-c", "to" => "/c"}
      ]

      run = migrate!(site, admin, %{"redirect" => rows})

      assert run.report.counts == %{created: 2, updated: 0, skipped: 2, failed: 0, undecided: 0}
      assert Enum.map(redirects(site), & &1.from_path) == ["/dup-a", "/two"]

      assert [{"1", %{outcome: :created, target_id: target_id}}, {"2", _two}] =
               Enum.map(items(site), &{&1.source_id, &1})

      assert Enum.find(redirects(site), &(&1.from_path == "/dup-a")).id == target_id

      assert Enum.count(run.report.entries, &(&1.reason == "duplicate_in_source")) == 2
    end

    test "records a kind no target writes as skipped, and reports a row with no id without recording it",
         %{site: site, admin: admin} do
      items = %{
        "redirect" => [%{"from" => "/no-id", "to" => "/x"}],
        "note" => [%{"id" => 9, "title" => "A note"}]
      }

      run = migrate!(site, admin, items)

      assert run.report.counts == %{created: 0, updated: 0, skipped: 1, failed: 1, undecided: 0}
      assert %{nil => {:failed, reason}, "9" => {:skipped, "no_target"}} = outcomes(run)
      assert reason =~ "source_id"

      assert [
               %{
                 source_kind: "note",
                 source_id: "9",
                 outcome: :skipped,
                 reason: "no_target",
                 target_id: nil
               }
             ] =
               items(site)

      assert redirects(site) == []
    end

    test "writes a row and its record together, so a record that fails takes the row back", %{
      site: site,
      admin: admin
    } do
      Repo.query!("""
      CREATE FUNCTION refuse_created_two() RETURNS trigger AS $$
      BEGIN
        IF NEW.source_id = '2' AND NEW.outcome = 'created' THEN
          RAISE EXCEPTION 'the record of item 2 failed';
        END IF;
        RETURN NEW;
      END $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER refuse_created_two BEFORE INSERT ON mishka_cms_migration_items
      FOR EACH ROW EXECUTE FUNCTION refuse_created_two()
      """)

      run = migrate!(site, admin, %{"redirect" => @rows})

      assert run.report.counts == %{created: 2, updated: 0, skipped: 0, failed: 1, undecided: 0}
      refute Enum.any?(redirects(site), &(&1.from_path == "/old-two"))
      assert %{outcome: :failed, target_id: nil} = Enum.find(items(site), &(&1.source_id == "2"))

      Repo.query!("DROP TRIGGER refuse_created_two ON mishka_cms_migration_items")
      again = migrate!(site, admin, %{"redirect" => @rows})

      assert again.report.counts == %{created: 1, updated: 0, skipped: 2, failed: 0, undecided: 0}
      assert Enum.map(redirects(site), & &1.from_path) == ["/old-one", "/old-three", "/old-two"]
    end

    test "keeps the source's fields the CMS has no home for and its facts, and a re-run updates them",
         %{site: site, admin: admin} do
      facts = %{"version" => "6.5", "plugins" => ["acf", "yoast"]}
      row = Map.merge(hd(@rows), %{"_yoast_title" => "Old one", "acf" => %{"color" => "red"}})
      connection = %{"items" => %{"redirect" => [row]}, "facts" => facts}

      run =
        site
        |> create_run!(admin, %{}, %{connection: connection})
        |> dry_run!(admin)
        |> import!(admin)

      assert run.extra == facts

      assert [%{extra: %{"_yoast_title" => "Old one", "acf" => %{"color" => "red"}}}] =
               items(site)

      changed = %{"items" => %{"redirect" => [Map.put(row, "acf", %{"color" => "blue"})]}}

      again =
        site
        |> create_run!(admin, %{}, %{connection: changed})
        |> dry_run!(admin)
        |> import!(admin)

      assert %{"1" => {:updated, nil}} = outcomes(again)
      assert [%{extra: %{"acf" => %{"color" => "blue"}}}] = items(site)
    end

    test "a target whose CMS resource has an extra of its own copies the source's fields there",
         %{
           site: site
         } do
      {:ok, _stopped} = MishkaInstaller.Event.Event.stop(:name, CmsPage, false)
      on_exit(fn -> {:ok, _enabled} = MishkaInstaller.Event.Event.enable(CmsPage, false) end)
      register_plugin!(PageTarget, MishkaCmsMigration.Target.event())

      admin =
        migration_admin!(site, ["admin:dashboard:migration", "admin:dashboard:runtime:page"])

      row = %{
        "id" => 5,
        "title" => "About us",
        "path" => "/about",
        "content" => [%{"html" => "<p>About</p>"}],
        "_wp_page_template" => "full-width"
      }

      run = migrate!(site, admin, %{"page" => [row]})

      assert run.report.counts == %{created: 1, updated: 0, skipped: 0, failed: 0, undecided: 0}

      assert %{extra: %{"migration" => %{"_wp_page_template" => "full-width"}}} =
               MishkaCmsCore.Runtime.Page
               |> Ash.read!(tenant: site.id, authorize?: false)
               |> Enum.find(&(&1.path == "/about"))
    end

    test "writes as the admin, so a row their permissions do not cover fails", %{site: site} do
      admin = migration_admin!(site, ["admin:dashboard:migration"])
      run = migrate!(site, admin, %{"redirect" => @rows})

      assert run.report.counts == %{created: 0, updated: 0, skipped: 0, failed: 3, undecided: 0}
      assert redirects(site) == []

      assert Enum.all?(
               items(site),
               &({&1.outcome, &1.reason} == {:failed, "forbidden: redirect"})
             )
    end

    test "a failed item is created on the next run once the CMS accepts it", %{
      site: site,
      admin: admin
    } do
      migrate!(site, admin, %{"redirect" => [%{"id" => 1, "from" => "/loop", "to" => "/loop"}]})

      run =
        migrate!(site, admin, %{"redirect" => [%{"id" => 1, "from" => "/loop", "to" => "/fixed"}]})

      assert %{"1" => {:created, nil}} = outcomes(run)
      assert [%{from_path: "/loop", to: "/fixed"}] = redirects(site)
    end
  end

  describe "a row an admin deleted for good in the CMS" do
    setup %{site: site, admin: admin} do
      migrate!(site, admin, %{"redirect" => @rows})
      deleted = Enum.find(redirects(site), &(&1.from_path == "/old-one"))
      Ash.destroy!(deleted, action: :permanent_destroy, actor: admin, tenant: site.id)
      %{deleted: deleted}
    end

    defp deleted_item(site), do: Enum.find(items(site), &(&1.source_id == "1"))

    defp decide_deleted!(site, admin, choice),
      do:
        site
        |> deleted_item()
        |> MishkaCmsMigration.decide_item!(choice, actor: admin, tenant: site.id)

    defp said(cell), do: Phoenix.LiveViewTest.rendered_to_string(cell)

    defp old_ones(site), do: Enum.filter(redirects(site), &(&1.from_path == "/old-one"))

    test "waits for the admin's decision in a dry run and an import, and says it was deleted before the choices",
         %{site: site, admin: admin} do
      run = site |> create_run!(admin, %{"redirect" => @rows}) |> dry_run!(admin)

      assert %{"1" => {:undecided, "deleted_in_cms"}, "2" => {:skipped, "unchanged"}} =
               outcomes(run)

      item = deleted_item(site)
      assert MigrationItem.conflict(item) == "deleted_in_cms"
      assert said(MigrationItem.plan_cell(item)) =~ "Needs your decision"

      assert said(MigrationItem.plan_cell(item)) =~
               "This redirect was deleted in Mishka CMS after it was imported"

      run = import!(run, admin)
      assert %{"1" => {:undecided, "deleted_in_cms"}} = outcomes(run)
      assert old_ones(site) == []

      item = deleted_item(site)
      assert %{outcome: :undecided, reason: "deleted_in_cms"} = item

      assert said(MigrationItem.last_import_cell(item)) =~
               "This redirect was deleted in Mishka CMS after it was imported"

      assert MigrationItem.decision_options(%{form: %Phoenix.HTML.Form{data: item}}) == [
               {"Import it again", "import"},
               {"Leave it out", "keep"}
             ]
    end

    test "Import it again writes it anew as a first import would, remembers the new record, and a run after that leaves it unchanged",
         %{site: site, admin: admin, deleted: deleted} do
      migrate!(site, admin, %{"redirect" => @rows})
      decide_deleted!(site, admin, "import")

      run = site |> create_run!(admin, %{"redirect" => @rows}) |> dry_run!(admin)
      assert %{"1" => {:created, nil}} = outcomes(run)
      assert old_ones(site) == []

      assert %{"1" => {:created, nil}} = outcomes(import!(run, admin))
      assert [%{id: id, to: "/one"}] = old_ones(site)
      refute id == deleted.id
      assert deleted_item(site).target_id == id

      assert %{"1" => {:skipped, "unchanged"}} =
               outcomes(migrate!(site, admin, %{"redirect" => @rows}))

      assert [%{id: ^id}] = old_ones(site)
    end

    test "Import it again holds once: the new record deleted for good waits for the admin's decision again",
         %{site: site, admin: admin} do
      migrate!(site, admin, %{"redirect" => @rows})
      decide_deleted!(site, admin, "import")
      migrate!(site, admin, %{"redirect" => @rows})
      assert deleted_item(site).decisions == %{}

      [again] = old_ones(site)
      Ash.destroy!(again, action: :permanent_destroy, actor: admin, tenant: site.id)

      assert %{"1" => {:undecided, "deleted_in_cms"}} =
               outcomes(migrate!(site, admin, %{"redirect" => @rows}))

      assert old_ones(site) == []
    end

    test "Leave it out keeps it deleted on every later run, whatever the source changed, and asks no more",
         %{site: site, admin: admin} do
      migrate!(site, admin, %{"redirect" => @rows})
      decide_deleted!(site, admin, "keep")
      changed = List.replace_at(@rows, 0, %{"id" => 1, "from" => "/old-one", "to" => "/again"})

      for _run <- 1..2 do
        assert %{"1" => {:skipped, "target_missing"}} =
                 outcomes(migrate!(site, admin, %{"redirect" => changed}))
      end

      assert old_ones(site) == []

      item = deleted_item(site)
      refute item.left_out
      assert item.decisions == %{"deleted_in_cms" => "keep"}
      assert MigrationItem.conflict(item) == nil

      assert {:error, %Ash.Error.Forbidden{}} =
               MishkaCmsMigration.forget_item_deleted_decision(item,
                 actor: admin,
                 tenant: site.id
               )

      assert said(MigrationItem.plan_cell(item)) =~
               MishkaCmsMigration.MigrationRun.reason_label("target_missing")
    end
  end

  describe "an item under a parent" do
    setup %{site: site} do
      %{admin: migration_admin!(site, ["admin:dashboard:migration", "admin:dashboard:blog:post"])}
    end

    defp category(id, title, parent \\ nil),
      do: %{"id" => id, "title" => title, "slug" => String.downcase(title), "parent" => parent}

    defp collections(site) do
      MishkaBlog.Collection
      |> Ash.read!(tenant: site.id, authorize?: false)
      |> Map.new(&{&1.name, &1})
    end

    defp collection!(site, admin, name),
      do:
        MishkaBlog.Collection
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: name,
            slug: String.downcase(name),
            status: :active,
            language: MishkaCmsCore.Runtime.Languages.primary(site.id)
          },
          actor: admin,
          tenant: site.id
        )
        |> Ash.create!()

    defp map!(site, admin, source_id, mapped_id),
      do:
        site
        |> item!(source_id)
        |> MishkaCmsMigration.map_item!(mapped_id, actor: admin, tenant: site.id)

    defp parent_name(collections, name) do
      parent_id = collections[name].parent_collection_id
      Enum.find_value(collections, fn {parent, %{id: id}} -> id == parent_id && parent end)
    end

    test "is written under its parent when the source lists it first, on an earlier page", %{
      site: site,
      admin: admin
    } do
      rows = [
        category(3, "Guides", 2),
        category(4, "Elixir", 3),
        category(5, "Releases"),
        category(2, "News")
      ]

      run = migrate!(site, admin, %{"category" => rows})

      assert run.report.counts == %{created: 4, updated: 0, skipped: 0, failed: 0, undecided: 0}
      assert Enum.map(run.report.entries, & &1.source_id) == ["5", "2", "3", "4"]

      collections = collections(site)
      assert parent_name(collections, "Guides") == "News"
      assert parent_name(collections, "Elixir") == "Guides"
      assert is_nil(collections["News"].parent_collection_id)
      assert is_nil(collections["Releases"].parent_collection_id)
    end

    test "is skipped while its parent cannot be written, and written once a run writes it", %{
      site: site,
      admin: admin
    } do
      rows = [category(3, "Guides", 2), %{category(2, "News") | "title" => nil}]
      run = migrate!(site, admin, %{"category" => rows})

      assert %{"2" => {:failed, _reason}, "3" => {:skipped, "parent_missing: #2"}} = outcomes(run)
      assert collections(site) == %{}

      again =
        migrate!(site, admin, %{"category" => [category(3, "Guides", 2), category(2, "News")]})

      assert %{"2" => {:created, nil}, "3" => {:created, nil}} = outcomes(again)
      assert parent_name(collections(site), "Guides") == "News"
    end

    test "under a parent an admin left out is skipped with it, however deep, in the dry run and the import",
         %{site: site, admin: admin} do
      rows = [
        category(4, "Elixir", 3),
        category(3, "Guides", 2),
        category(6, "Phoenix", 3),
        category(2, "News"),
        category(5, "Releases")
      ]

      run = site |> create_run!(admin, %{"category" => rows}) |> dry_run!(admin)
      for id <- ["2", "6"], do: leave_out!(site, admin, id)

      run = dry_run!(run, admin)

      assert outcomes(run) == %{
               "2" => {:skipped, "left_out_by_admin"},
               "3" => {:skipped, "parent_left_out"},
               "4" => {:skipped, "parent_left_out"},
               "6" => {:skipped, "left_out_by_admin"},
               "5" => {:created, nil}
             }

      run = import!(run, admin)

      assert %{"3" => {:skipped, "parent_left_out"}, "4" => {:skipped, "parent_left_out"}} =
               outcomes(run)

      assert Map.keys(collections(site)) == ["Releases"]
    end

    test "listed before the parent an admin left out follows it too, and keeps its CMS record", %{
      site: site,
      admin: admin
    } do
      migrate!(site, admin, %{
        "category" => [category(2, "News"), category(3, "Guides", 2), category(4, "Elixir", 3)]
      })

      written = Map.new(collections(site), fn {name, c} -> {name, {c.id, c.description}} end)
      leave_out!(site, admin, "2")

      changed = [
        Map.put(category(4, "Elixir", 3), "description", "changed at the source"),
        category(3, "Guides", 2),
        category(2, "News")
      ]

      run = migrate!(site, admin, %{"category" => changed})

      assert outcomes(run) == %{
               "2" => {:skipped, "left_out_by_admin"},
               "3" => {:skipped, "parent_left_out"},
               "4" => {:skipped, "parent_left_out"}
             }

      assert Map.new(collections(site), fn {name, c} -> {name, {c.id, c.description}} end) ==
               written
    end

    test "mapped to a Blog category is connected to it, never written, and its children go under it",
         %{site: site, admin: admin} do
      topics = collection!(site, admin, "Topics")
      rows = [category(3, "Guides", 2), category(2, "News"), category(4, "Elixir", 3)]
      run = site |> create_run!(admin, %{"category" => rows}) |> dry_run!(admin)
      map!(site, admin, "2", topics.id)

      run = run |> dry_run!(admin) |> import!(admin)

      assert %{"2" => {:skipped, "connected"}, "3" => {:created, nil}} = outcomes(run)
      assert %{target_id: target_id, target_updated_at: nil} = item!(site, "2")
      assert target_id == topics.id

      collections = collections(site)
      refute Map.has_key?(collections, "News")
      assert parent_name(collections, "Guides") == "Topics"
      assert parent_name(collections, "Elixir") == "Guides"
      assert collections["Topics"].updated_at == topics.updated_at
    end

    test "mapped wins over what an import wrote and what the source changed, and unmapped meets its own record again by its slug",
         %{site: site, admin: admin} do
      migrate!(site, admin, %{"category" => [category(2, "News")]})
      news = collections(site)["News"]
      topics = collection!(site, admin, "Topics")

      map!(site, admin, "2", topics.id)
      changed = [Map.put(category(2, "News"), "description", "changed at the source")]
      run = migrate!(site, admin, %{"category" => changed})

      assert %{"2" => {:skipped, "connected"}} = outcomes(run)
      assert collections(site)["News"].description == news.description
      assert item!(site, "2").target_id == topics.id

      map!(site, admin, "2", nil)
      assert %{target_id: nil, mapped_id: nil} = item!(site, "2")

      again = migrate!(site, admin, %{"category" => changed})
      assert %{"2" => {:undecided, "slug_taken"}} = outcomes(again)

      site
      |> item!("2")
      |> MishkaCmsMigration.decide_item!("keep", actor: admin, tenant: site.id)

      again = migrate!(site, admin, %{"category" => changed})
      assert %{"2" => {:skipped, "connected"}} = outcomes(again)
      assert item!(site, "2").target_id == news.id
    end

    test "mapped under a left-out parent keeps its mapping, waits for the admin's decision once that record is archived, and is skipped as mapped_missing once it is gone",
         %{site: site, admin: admin} do
      topics = collection!(site, admin, "Topics")
      rows = [category(2, "News"), category(3, "Guides", 2)]
      run = site |> create_run!(admin, %{"category" => rows}) |> dry_run!(admin)
      leave_out!(site, admin, "2")
      map!(site, admin, "3", topics.id)

      assert %{"2" => {:skipped, "left_out_by_admin"}, "3" => {:skipped, "connected"}} =
               outcomes(dry_run!(run, admin))

      Ash.destroy!(topics, tenant: site.id, authorize?: false)
      assert %{"3" => {:undecided, "archived_in_cms"}} = outcomes(dry_run!(run, admin))

      Ash.destroy!(topics, action: :permanent_destroy, tenant: site.id, authorize?: false)
      assert %{"3" => {:skipped, "mapped_missing"}} = outcomes(dry_run!(run, admin))
    end

    test "whose parent the source never lists, or that is its own parent, is settled after the kind",
         %{site: site, admin: admin} do
      rows = [category(3, "Guides", 99), category(4, "Loop", 4), category(2, "News")]
      run = migrate!(site, admin, %{"category" => rows})

      assert %{"2" => {:created, nil}, "3" => {:skipped, "parent_not_listed: 99"}} = outcomes(run)
      assert %{"4" => {:skipped, "parent_missing: Loop (#4)"}} = outcomes(run)
      assert Map.keys(collections(site)) == ["News"]
    end
  end

  describe "a source that cannot be read" do
    @tag capture_log: true
    test "that refuses the password fails the run at once, in words, without raising", %{
      site: site,
      admin: admin
    } do
      run = create_run!(site, admin, %{"redirect" => @rows})

      Repo.query!(
        ~s(UPDATE mishka_cms_migration_runs SET connection = connection || '{"revoked": true}' WHERE id = $1),
        [Ecto.UUID.dump!(run.id)]
      )

      run = MishkaCmsMigration.start_dry_run!(run, actor: admin, tenant: site.id)

      [job] = assert_triggered(run, :run_dry_run)

      assert {:ok, %{status: :failed}} = perform_job(DryRunWorker, job.args, attempt: 1)

      run = MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id)
      assert {run.status, run.reason} == {:failed, "unauthorized"}

      assert MishkaCmsMigration.MigrationRun.reason_label(run.reason) ==
               "The source refused the user or the password"

      assert MishkaCmsMigration.MigrationRun.open_secret(run) == {:ok, "letmein"}
    end

    test "whose last attempt Oban stops at its timeout fails the run, which keeps its secret", %{
      site: site,
      admin: admin
    } do
      run =
        site
        |> create_run!(admin, %{"redirect" => @rows})
        |> dry_run!(admin)
        |> MishkaCmsMigration.start_import!(actor: admin, tenant: site.id)

      [job] = assert_triggered(run, :run_import)
      job = %{job | attempt: 3}

      :telemetry.execute([:oban, :job, :exception], %{duration: 0}, %{
        job: job,
        state: :discard,
        kind: :error,
        reason: Oban.TimeoutError.exception({ImportWorker, :timer.hours(1)})
      })

      run = MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id)

      assert {run.status, MishkaCmsMigration.MigrationRun.open_secret(run)} ==
               {:failed, {:ok, "letmein"}}

      assert run.reason =~ "timed out"
    end

    @tag capture_log: true
    test "a discarded job the handler cannot read leaves the handler attached", %{} do
      job = %Oban.Job{worker: "MishkaCmsMigration.Workers.DryRunWorker", args: %{"run_id" => 1}}

      :telemetry.execute([:oban, :job, :exception], %{duration: 0}, %{
        job: job,
        state: :discard,
        kind: :error,
        reason: :crashed
      })

      assert Enum.any?(
               :telemetry.list_handlers([:oban, :job, :exception]),
               &(&1.id == "mishka-cms-migration-discarded-jobs")
             )
    end

    @tag capture_log: true
    test "fails the run when listing breaks, and nothing is written", %{site: site, admin: admin} do
      run =
        site
        |> create_run!(admin, %{"redirect" => @rows}, %{connection: %{"broken" => "list"}})
        |> MishkaCmsMigration.start_dry_run!(actor: admin, tenant: site.id)

      [job] = assert_triggered(run, :run_dry_run)

      assert :ok = perform_job(DryRunWorker, job.args, attempt: 3)

      assert %{status: :failed, reason: "source_unreachable"} =
               MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id)

      assert redirects(site) == []
    end
  end

  describe "several sources into one site" do
    defp migrate_host!(site, admin, host, rows) do
      site
      |> create_run!(admin, %{"redirect" => rows}, %{source_host: host})
      |> dry_run!(admin)
      |> import!(admin)
    end

    defp to_of(site, from), do: Enum.find(redirects(site), &(&1.from_path == from)).to

    test "keep their own items and rows, the same id from two hosts being two", %{
      site: site,
      admin: admin
    } do
      a = migrate_host!(site, admin, "old-a.example.com", [redirect_row(1, "/a-one", "/a")])
      b = migrate_host!(site, admin, "old-b.example.com", [redirect_row(1, "/b-one", "/b")])

      assert {a.created_count, b.created_count} == {1, 1}

      assert [{"old-a.example.com", "1"}, {"old-b.example.com", "1"}] =
               site |> items() |> Enum.map(&{&1.source_host, &1.source_id}) |> Enum.sort()

      assert Enum.map(redirects(site), & &1.from_path) == ["/a-one", "/b-one"]

      assert ["old-a.example.com", "old-b.example.com"] =
               MishkaCmsMigration.MigrationRun
               |> Ash.read!(actor: admin, tenant: site.id)
               |> Enum.map(& &1.source_host)
               |> Enum.sort()
    end

    test "re-run one host and update only its own rows", %{site: site, admin: admin} do
      migrate_host!(site, admin, "old-a.example.com", [redirect_row(1, "/a-one", "/a")])
      b = migrate_host!(site, admin, "old-b.example.com", [redirect_row(1, "/b-one", "/b")])

      again = migrate_host!(site, admin, "old-a.example.com", [redirect_row(1, "/a-one", "/a2")])

      assert %{"1" => {:updated, nil}} = outcomes(again)
      assert {to_of(site, "/a-one"), to_of(site, "/b-one")} == {"/a2", "/b"}
      assert %{run_id: run_id} = Enum.find(items(site), &(&1.source_host == "old-b.example.com"))
      assert run_id == b.id
    end

    test "never overwrite each other: the second to claim an address is refused with why", %{
      site: site,
      admin: admin
    } do
      migrate_host!(site, admin, "old-a.example.com", [redirect_row(1, "/shared", "/from-a")])
      b = migrate_host!(site, admin, "old-b.example.com", [redirect_row(7, "/shared", "/from-b")])

      assert %{"7" => {:failed, reason}} = outcomes(b)
      assert reason =~ "already redirects that address"
      assert to_of(site, "/shared") == "/from-a"
      assert [_one] = redirects(site)
    end
  end

  describe "the source's secret" do
    test "none is handed to the source as none", %{site: site, admin: admin} do
      connection = %{"public" => true, "items" => %{"redirect" => @rows}}
      run = create_run!(site, admin, %{}, %{secret: nil, connection: connection})

      assert is_nil(run.connection_secret)

      assert %{status: :done, report: %{counts: %{created: 3}}} =
               run |> dry_run!(admin) |> import!(admin)
    end

    @tag capture_log: true
    test "one sealed under another key fails the run instead of connecting without it", %{
      site: site,
      admin: admin
    } do
      run = create_run!(site, admin, %{"redirect" => @rows})

      rotated =
        Phoenix.Token.encrypt(String.duplicate("a rotated key base ", 4), "salt", "letmein")

      Repo.query!("UPDATE mishka_cms_migration_runs SET connection_secret = $1 WHERE id = $2", [
        rotated,
        Ecto.UUID.dump!(run.id)
      ])

      run = MishkaCmsMigration.start_dry_run!(run, actor: admin, tenant: site.id)
      [job] = assert_triggered(run, :run_dry_run)

      assert {:ok, %{status: :failed}} = perform_job(DryRunWorker, job.args, attempt: 3)

      run = MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id)

      assert {run.status, run.reason, run.connection_secret} ==
               {:failed, "unreadable_secret", rotated}
    end
  end

  describe "a source or a target that raises" do
    test "costs only the row a source cannot normalize", %{site: site, admin: admin} do
      run = migrate!(site, admin, %{"redirect" => ["not a row" | @rows]})

      assert run.status == :done
      assert run.report.counts == %{created: 3, updated: 0, skipped: 0, failed: 1, undecided: 0}

      assert [%{source_id: nil, outcome: :failed, reason: reason}] =
               Enum.filter(run.report.entries, &(&1.outcome == :failed))

      assert byte_size(reason) > 0
      assert length(redirects(site)) == 3
    end

    test "costs only the row a target cannot map, which is recorded as failed", %{
      site: site,
      admin: admin
    } do
      rows = [Map.put(hd(@rows), "explode", "attrs") | tl(@rows)]
      run = migrate!(site, admin, %{"redirect" => rows})

      assert run.report.counts == %{created: 2, updated: 0, skipped: 0, failed: 1, undecided: 0}
      assert %{outcome: :failed, target_id: nil} = Enum.find(items(site), &(&1.source_id == "1"))
      refute Enum.any?(redirects(site), &(&1.from_path == "/old-one"))
    end

    @tag capture_log: true
    test "outside an item is tried again, and its last attempt fails the run, which keeps its secret",
         %{
           site: site,
           admin: admin
         } do
      run =
        site
        |> create_run!(admin, %{"redirect" => @rows}, %{connection: %{"broken" => "raise"}})
        |> MishkaCmsMigration.start_dry_run!(actor: admin, tenant: site.id)

      [job] = assert_triggered(run, :run_dry_run)

      assert_raise Ash.Error.Invalid, ~r/the source broke/, fn ->
        perform_job(DryRunWorker, job.args, attempt: 1)
      end

      assert MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id).status ==
               :dry_running

      assert :ok = perform_job(DryRunWorker, job.args, attempt: 3)

      run = MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id)
      assert run.status == :failed
      assert run.reason =~ "the source broke"
      assert MishkaCmsMigration.MigrationRun.open_secret(run) == {:ok, "letmein"}
    end
  end

  describe "a source whose pages never end" do
    for {broken, reason} <- [{"loop", :cursor_repeated}, {"endless", :too_many_pages}] do
      @tag capture_log: true
      test "fails the run with #{reason} when its cursors #{broken}", %{site: site, admin: admin} do
        run =
          site
          |> create_run!(admin, %{}, %{connection: %{"broken" => unquote(broken)}})
          |> MishkaCmsMigration.start_dry_run!(actor: admin, tenant: site.id)

        [job] = assert_triggered(run, :run_dry_run)

        assert :ok = perform_job(DryRunWorker, job.args, attempt: 3)

        assert %{status: :failed, reason: reason} =
                 MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id)

        assert reason =~ "#{unquote(reason)}"
      end
    end
  end

  describe "a job" do
    @tag capture_log: true
    test "whose finished report the database cannot save is tried again, and the retry finishes",
         %{
           site: site,
           admin: admin
         } do
      run =
        site
        |> create_run!(admin, %{"redirect" => @rows})
        |> dry_run!(admin)
        |> MishkaCmsMigration.start_import!(actor: admin, tenant: site.id)

      [job] = assert_triggered(run, :run_import)

      refuse_run_update!("NEW.status = 'done'", "the report could not be saved")

      assert_raise Ash.Error.Invalid, ~r/the report could not be saved/, fn ->
        perform_job(ImportWorker, job.args, attempt: 1)
      end

      assert MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id).status ==
               :importing

      Repo.query!("DROP TRIGGER refuse_run_update ON mishka_cms_migration_runs")

      assert {:ok, _run} = perform_job(ImportWorker, job.args, attempt: 2)

      assert %{status: :done, report: %{counts: %{skipped: 3}}} =
               MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id)
    end

    @tag capture_log: true
    test "whose progress the database cannot save is tried again, and its last attempt fails the run",
         %{site: site, admin: admin} do
      run =
        site
        |> create_run!(admin, %{"redirect" => @rows})
        |> dry_run!(admin)
        |> MishkaCmsMigration.start_import!(actor: admin, tenant: site.id)

      [job] = assert_triggered(run, :run_import)

      refuse_run_update!(
        "NEW.progress IS DISTINCT FROM OLD.progress",
        "the progress could not be saved"
      )

      assert_raise Ash.Error.Invalid, ~r/the progress could not be saved/, fn ->
        perform_job(ImportWorker, job.args, attempt: 1)
      end

      assert MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id).status ==
               :importing

      assert :ok = perform_job(ImportWorker, job.args, attempt: 3)

      assert %{status: :failed, reason: reason} =
               MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id)

      assert reason =~ "the progress could not be saved"
    end

    test "whose run is not waiting for it is cancelled and changes nothing", %{
      site: site,
      admin: admin
    } do
      run = create_run!(site, admin, %{"redirect" => @rows})
      args = %{primary_key: %{id: run.id}, tenant: site.id, actor: %{id: admin.id}}

      assert {:cancel, :trigger_no_longer_applies} = perform_job(ImportWorker, args)
      assert MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id).status == :pending
      assert redirects(site) == []
    end

    test "whose run is cancelled while it walks stops at the next page and is cancelled", %{
      site: site,
      admin: admin
    } do
      register_plugin!(ItemGate, Events.before_import_event())

      rows = [
        redirect_row(1, "/one", "/a", %{"gate" => "cancel"}),
        redirect_row(2, "/two", "/b"),
        redirect_row(3, "/three", "/c")
      ]

      run =
        site
        |> create_run!(admin, %{"redirect" => rows})
        |> dry_run!(admin)
        |> MishkaCmsMigration.start_import!(actor: admin, tenant: site.id)

      [job] = assert_triggered(run, :run_import)

      assert {:cancel, :not_running} = perform_job(ImportWorker, job.args)

      assert MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id).status ==
               :cancelled

      assert Enum.map(redirects(site), & &1.from_path) == ["/one", "/two"]
    end

    test "fails an item whose skip cannot be recorded, and goes on with the rest", %{
      site: site,
      admin: admin
    } do
      Repo.query!("""
      CREATE FUNCTION refuse_skipped() RETURNS trigger AS $$
      BEGIN
        IF NEW.outcome = 'skipped' THEN
          RAISE EXCEPTION 'the skip could not be recorded';
        END IF;
        RETURN NEW;
      END $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER refuse_skipped BEFORE INSERT ON mishka_cms_migration_items
      FOR EACH ROW EXECUTE FUNCTION refuse_skipped()
      """)

      items = %{
        "redirect" => [redirect_row(1, "/old", "/new")],
        "note" => [%{"id" => 9, "title" => "A note"}]
      }

      run = migrate!(site, admin, items)

      assert run.status == :done
      assert run.report.counts == %{created: 1, updated: 0, skipped: 0, failed: 1, undecided: 0}
      assert %{"1" => {:created, nil}, "9" => {:failed, reason}} = outcomes(run)
      assert reason =~ "the skip could not be recorded"

      assert [
               %{source_id: "1", outcome: :created},
               %{source_id: "9", outcome: nil, plan: :skipped}
             ] = items(site)
    end
  end
end
