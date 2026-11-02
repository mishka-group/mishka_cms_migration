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
  alias MishkaCmsMigration.{MigrationItem, Progress}
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
      assert run.report.counts == %{create: 3, update: 0, skip: 0, fail: 0}
      assert [%{kind: "redirect", create: 3}] = run.report.kinds
      assert Enum.map(run.report.entries, & &1.source_id) == ["1", "2", "3"]
      assert redirects(site) == []
      assert items(site) == []
    end

    test "broadcasts its progress page by page on the run's topic", %{site: site, admin: admin} do
      run = create_run!(site, admin, %{"redirect" => @rows})
      :ok = Progress.subscribe(run.id)
      run_id = run.id

      dry_run!(run, admin)

      assert_receive {:migration_progress,
                      %{run_id: ^run_id, mode: :dry_run, kind: "redirect", counts: %{create: 2}}}

      assert_receive {:migration_progress,
                      %{run_id: ^run_id, mode: :dry_run, kind: "redirect", counts: %{create: 3}}}
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

      assert run.report.counts == %{create: 0, update: 0, skip: 1, fail: 1}
      assert %{nil => {:fail, "unreadable"}, "9" => {:skip, "no_target"}} = outcomes(run)
    end
  end

  describe "an import" do
    test "writes every item through the target as the admin and records it", %{
      site: site,
      admin: admin
    } do
      run = migrate!(site, admin, %{"redirect" => @rows})

      assert run.status == :done
      assert run.report.counts == %{create: 3, update: 0, skip: 0, fail: 0}
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

      assert second.report.counts == %{create: 0, update: 1, skip: 2, fail: 0}
      assert %{"2" => {:update, nil}, "1" => {:skip, "unchanged"}} = outcomes(second)
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

      assert run.report.counts == %{create: 0, update: 1, skip: 2, fail: 0}
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

      assert %{"1" => {:skip, "edited_in_cms"}} = outcomes(run)
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

      assert %{"1" => {:skip, "target_missing"}} = outcomes(run)
      refute Enum.any?(redirects(site), &(&1.from_path == "/old-one"))
    end

    test "records a row the CMS action refuses as failed, with its reason, and goes on", %{
      site: site,
      admin: admin
    } do
      rows = [%{"id" => 1, "from" => "/loop", "to" => "/loop"} | tl(@rows)]
      run = migrate!(site, admin, %{"redirect" => rows})

      assert run.status == :done
      assert run.report.counts == %{create: 2, update: 0, skip: 0, fail: 1}
      assert %{"1" => {:fail, reason}} = outcomes(run)
      assert byte_size(reason) > 0

      assert %{outcome: :failed, target_id: nil, reason: ^reason} =
               Enum.find(items(site), &(&1.source_id == "1"))

      assert length(redirects(site)) == 2
    end

    test "writes as the admin, so a row their permissions do not cover fails", %{site: site} do
      admin = migration_admin!(site, ["admin:dashboard:migration"])
      run = migrate!(site, admin, %{"redirect" => @rows})

      assert run.report.counts == %{create: 0, update: 0, skip: 0, fail: 3}
      assert redirects(site) == []
      assert Enum.all?(items(site), &(&1.outcome == :failed))
    end

    test "a failed item is created on the next run once the CMS accepts it", %{
      site: site,
      admin: admin
    } do
      migrate!(site, admin, %{"redirect" => [%{"id" => 1, "from" => "/loop", "to" => "/loop"}]})

      run =
        migrate!(site, admin, %{"redirect" => [%{"id" => 1, "from" => "/loop", "to" => "/fixed"}]})

      assert %{"1" => {:create, nil}} = outcomes(run)
      assert [%{from_path: "/loop", to: "/fixed"}] = redirects(site)
    end
  end

  describe "a source that cannot be read" do
    test "is tried again, and its last attempt fails the run with the reason", %{
      site: site,
      admin: admin
    } do
      run =
        site
        |> create_run!(admin, %{"redirect" => @rows}, %{secret: "wrong"})
        |> MishkaCmsMigration.start_dry_run!(actor: admin, tenant: site.id)

      args = %{run_id: run.id, site_id: site.id, actor_id: admin.id}

      assert {:error, :unauthorized} = perform_job(DryRunWorker, args, attempt: 1)

      assert MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id).status ==
               :dry_running

      assert {:cancel, :unauthorized} = perform_job(DryRunWorker, args, attempt: 3)

      run = MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id)
      assert {run.status, run.error} == {:failed, "unauthorized"}
      assert is_nil(run.connection_secret)
    end

    test "fails the run when listing breaks, and nothing is written", %{site: site, admin: admin} do
      run =
        site
        |> create_run!(admin, %{"redirect" => @rows}, %{connection: %{"broken" => "list"}})
        |> MishkaCmsMigration.start_dry_run!(actor: admin, tenant: site.id)

      args = %{run_id: run.id, site_id: site.id, actor_id: admin.id}

      assert {:cancel, :source_unreachable} = perform_job(DryRunWorker, args, attempt: 3)
      assert MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id).status == :failed
      assert redirects(site) == []
    end
  end

  describe "a job" do
    test "whose run is not waiting for it is cancelled and changes nothing", %{
      site: site,
      admin: admin
    } do
      run = create_run!(site, admin, %{"redirect" => @rows})
      args = %{run_id: run.id, site_id: site.id, actor_id: admin.id}

      assert {:cancel, :not_running} = perform_job(ImportWorker, args)
      assert MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id).status == :pending
      assert redirects(site) == []
    end
  end
end
