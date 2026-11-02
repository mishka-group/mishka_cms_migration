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
    test "reports every item as a create and writes nothing", %{site: site, admin: admin} do
      run = site |> create_run!(admin, %{"redirect" => @rows}) |> dry_run!(admin)

      assert run.status == :dry_run
      assert run.report.counts == %{created: 3, updated: 0, skipped: 0, failed: 0}
      assert [%{kind: "redirect", created: 3}] = run.report.kinds
      assert Enum.map(run.report.entries, & &1.source_id) == ["1", "2", "3"]
      assert redirects(site) == []
      assert items(site) == []
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

      assert run.report.counts == %{created: 0, updated: 0, skipped: 1, failed: 1}
      assert %{nil => {:failed, "unreadable"}, "9" => {:skipped, "no_target"}} = outcomes(run)
    end
  end

  describe "an import" do
    test "writes every item through the target as the admin and records it", %{
      site: site,
      admin: admin
    } do
      run = migrate!(site, admin, %{"redirect" => @rows})

      assert run.status == :done
      assert run.report.counts == %{created: 3, updated: 0, skipped: 0, failed: 0}
      assert run.created_count == 3
      assert is_nil(run.connection_secret)
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

      assert second.report.counts == %{created: 0, updated: 1, skipped: 2, failed: 0}
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

      assert run.report.counts == %{created: 0, updated: 1, skipped: 2, failed: 0}
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

    test "does not bring back a row deleted in the CMS after the import", %{
      site: site,
      admin: admin
    } do
      migrate!(site, admin, %{"redirect" => @rows})
      deleted = Enum.find(redirects(site), &(&1.from_path == "/old-one"))
      Ash.destroy!(deleted, actor: admin, tenant: site.id)

      changed = List.replace_at(@rows, 0, %{"id" => 1, "from" => "/old-one", "to" => "/again"})
      run = migrate!(site, admin, %{"redirect" => changed})

      assert %{"1" => {:skipped, "target_missing"}} = outcomes(run)
      refute Enum.any?(redirects(site), &(&1.from_path == "/old-one"))
    end

    test "records a row the CMS action refuses as failed, with its reason, and goes on", %{
      site: site,
      admin: admin
    } do
      rows = [%{"id" => 1, "from" => "/loop", "to" => "/loop"} | tl(@rows)]
      run = migrate!(site, admin, %{"redirect" => rows})

      assert run.status == :done
      assert run.report.counts == %{created: 2, updated: 0, skipped: 0, failed: 1}
      assert %{"1" => {:failed, reason}} = outcomes(run)
      assert reason =~ ": "
      refute reason =~ "Error returned from"

      assert %{outcome: :failed, target_id: nil, reason: ^reason} =
               Enum.find(items(site), &(&1.source_id == "1"))

      assert length(redirects(site)) == 2
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

      assert run.report.counts == %{created: 2, updated: 0, skipped: 2, failed: 0}
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

      assert run.report.counts == %{created: 0, updated: 0, skipped: 1, failed: 1}
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

      assert run.report.counts == %{created: 2, updated: 0, skipped: 0, failed: 1}
      refute Enum.any?(redirects(site), &(&1.from_path == "/old-two"))
      assert %{outcome: :failed, target_id: nil} = Enum.find(items(site), &(&1.source_id == "2"))

      Repo.query!("DROP TRIGGER refuse_created_two ON mishka_cms_migration_items")
      again = migrate!(site, admin, %{"redirect" => @rows})

      assert again.report.counts == %{created: 1, updated: 0, skipped: 2, failed: 0}
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

      assert run.report.counts == %{created: 1, updated: 0, skipped: 0, failed: 0}

      assert %{extra: %{"migration" => %{"_wp_page_template" => "full-width"}}} =
               MishkaCmsCore.Runtime.Page
               |> Ash.read!(tenant: site.id, authorize?: false)
               |> Enum.find(&(&1.path == "/about"))
    end

    test "writes as the admin, so a row their permissions do not cover fails", %{site: site} do
      admin = migration_admin!(site, ["admin:dashboard:migration"])
      run = migrate!(site, admin, %{"redirect" => @rows})

      assert run.report.counts == %{created: 0, updated: 0, skipped: 0, failed: 3}
      assert redirects(site) == []
      assert Enum.all?(items(site), &({&1.outcome, &1.reason} == {:failed, "forbidden"}))
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

      assert run.report.counts == %{created: 4, updated: 0, skipped: 0, failed: 0}
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

      assert %{"2" => {:failed, _reason}, "3" => {:skipped, "parent_missing"}} = outcomes(run)
      assert collections(site) == %{}

      again =
        migrate!(site, admin, %{"category" => [category(3, "Guides", 2), category(2, "News")]})

      assert %{"2" => {:created, nil}, "3" => {:created, nil}} = outcomes(again)
      assert parent_name(collections(site), "Guides") == "News"
    end

    test "whose parent the source never lists, or that is its own parent, is settled after the kind",
         %{site: site, admin: admin} do
      rows = [category(3, "Guides", 99), category(4, "Loop", 4), category(2, "News")]
      run = migrate!(site, admin, %{"category" => rows})

      assert %{"2" => {:created, nil}, "3" => {:skipped, "parent_missing"}} = outcomes(run)
      assert %{"4" => {:skipped, "parent_missing"}} = outcomes(run)
      assert Map.keys(collections(site)) == ["News"]
    end
  end

  describe "a source that cannot be read" do
    @tag capture_log: true
    test "is tried again, and its last attempt fails the run with the reason", %{
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

      assert_raise Ash.Error.Invalid, ~r/unauthorized/, fn ->
        perform_job(DryRunWorker, job.args, attempt: 1)
      end

      assert MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id).status ==
               :dry_running

      assert :ok = perform_job(DryRunWorker, job.args, attempt: 3)

      run = MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id)
      assert {run.status, run.reason} == {:failed, "unauthorized"}
      assert is_nil(run.connection_secret)
    end

    test "whose last attempt Oban stops at its timeout fails the run and drops the secret", %{
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
      assert {run.status, run.connection_secret} == {:failed, nil}
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

      assert :ok = perform_job(DryRunWorker, job.args, attempt: 3)

      run = MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id)

      assert {run.status, run.reason, run.connection_secret} ==
               {:failed, "unreadable_secret", nil}
    end
  end

  describe "a source or a target that raises" do
    test "costs only the row a source cannot normalize", %{site: site, admin: admin} do
      run = migrate!(site, admin, %{"redirect" => ["not a row" | @rows]})

      assert run.status == :done
      assert run.report.counts == %{created: 3, updated: 0, skipped: 0, failed: 1}

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

      assert run.report.counts == %{created: 2, updated: 0, skipped: 0, failed: 1}
      assert %{outcome: :failed, target_id: nil} = Enum.find(items(site), &(&1.source_id == "1"))
      refute Enum.any?(redirects(site), &(&1.from_path == "/old-one"))
    end

    @tag capture_log: true
    test "outside an item is tried again, and its last attempt fails the run and drops the secret",
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
      assert is_nil(run.connection_secret)
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
      assert run.report.counts == %{created: 1, updated: 0, skipped: 0, failed: 1}
      assert %{"1" => {:created, nil}, "9" => {:failed, reason}} = outcomes(run)
      assert reason =~ "the skip could not be recorded"
      assert [%{source_id: "1", outcome: :created}] = items(site)
    end
  end
end
