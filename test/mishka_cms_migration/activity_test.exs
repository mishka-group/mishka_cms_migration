# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.ActivityTest do
  @moduledoc """
  A run's log (`MishkaCmsMigration.MigrationLog`) as the admins read it: every step of a run is an
  entry, written once the step is saved, in the sentence the bell says; the Migration page's Logs
  read it through the core's feed (`MishkaCmsMigration.Activity` as a
  `MishkaCmsCore.Activity.Behaviours.Source`), a site's admins their own site's and a master every
  site's, and each new entry is broadcast to them; and the core's full activity log merges the same
  entries (`MishkaCmsCore.Activity.Query`, through the `activity:sources` branch).
  """
  use MishkaCmsMigration.DataCase, async: false

  alias MishkaCmsCore.Activity.Query
  alias MishkaCmsMigration.{Activity, MigrationLog}
  alias MishkaCmsMigration.Workers.DryRunWorker

  @rows [
    %{"id" => 1, "from" => "/old-one", "to" => "/one"},
    %{"id" => 2, "from" => "/old-two", "to" => "/two"},
    %{"id" => 3, "from" => "/old-three", "to" => "/three"}
  ]

  setup do
    for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)

    site = create_site!()
    %{site: site, admin: migration_admin!(site)}
  end

  defp logs(user), do: Activity.initial_fetch(%{current_user: user}, 50)

  defp said(entries), do: entries |> Enum.reverse() |> Enum.map(&{&1.action, &1.message})

  describe "a run's log" do
    test "has an entry for each step, in the sentence the bell says, and who took it", %{
      site: site,
      admin: admin
    } do
      run = migrate!(site, admin, %{"redirect" => @rows})

      assert said(logs(admin)) == [
               {:connected, "Connected to old.example.com."},
               {:dry_run_started, "Dry run of old.example.com started."},
               {:dry_run_finished, "Dry run of old.example.com finished: 3 created."},
               {:import_started, "Import of old.example.com started."},
               {:import_finished, "Import of old.example.com finished: 3 created."}
             ]

      for entry <- logs(admin) do
        assert {entry.source_id, entry.site_id, entry.user_id} == {run.id, site.id, admin.id}
      end

      assert [%{severity: :info, badge_label: "FINISHED", resource_label: "Import"} | _rest] =
               logs(admin)
    end

    @tag capture_log: true
    test "tells why a dry run failed, and that a run was cancelled", %{site: site, admin: admin} do
      run = create_run!(site, admin, %{"redirect" => @rows})

      Repo.query!(
        ~s(UPDATE mishka_cms_migration_runs SET connection = connection || '{"revoked": true}' WHERE id = $1),
        [Ecto.UUID.dump!(run.id)]
      )

      run = MishkaCmsMigration.start_dry_run!(run, actor: admin, tenant: site.id)
      [job] = assert_triggered(run, :run_dry_run)
      assert {:ok, %{status: :failed}} = perform_job(DryRunWorker, job.args, attempt: 3)

      site
      |> create_run!(admin, %{"redirect" => @rows})
      |> MishkaCmsMigration.cancel_run!(actor: admin, tenant: site.id)

      assert [cancelled, _connected, failed | _started] = logs(admin)
      assert {failed.action, failed.severity} == {:dry_run_failed, :error}

      assert failed.message ==
               "Dry run of old.example.com failed: The source refused the user or the password."

      assert failed.user_id == admin.id
      assert {cancelled.action, cancelled.severity} == {:cancelled, :warn}
      assert cancelled.message == "The run of old.example.com was cancelled."
    end

    test "keeps nothing of the connection or its secret", %{site: site, admin: admin} do
      migrate!(site, admin, %{"redirect" => @rows})

      for entry <- Ash.read!(MigrationLog, authorize?: false) do
        refute inspect(entry) =~ "letmein"
        refute inspect(entry) =~ "items"
      end
    end

    test "is refused to every actor to write", %{site: site, admin: admin} do
      run = create_run!(site, admin, %{"redirect" => @rows})

      assert {:error, %Ash.Error.Forbidden{}} =
               MishkaCmsMigration.record_log(
                 %{step: :connected, source_host: "forged.example.com", run_id: run.id},
                 actor: admin,
                 tenant: site.id
               )
    end
  end

  describe "the Logs" do
    test "show a site's admin their own site's entries and a master every site's", %{
      site: site,
      admin: admin
    } do
      other_site = create_site!()
      other_admin = migration_admin!(other_site)
      master = create_user_with_permissions!(["admin:dashboard:migration"])
      no_migration = migration_admin!(site, ["admin:dashboard:runtime:redirect"])

      create_run!(site, admin, %{})
      create_run!(other_site, other_admin, %{})

      assert [%{site_id: site_id}] = logs(admin)
      assert site_id == site.id
      assert [%{site_id: other_site_id}] = logs(other_admin)
      assert other_site_id == other_site.id

      assert Enum.sort(Enum.map(logs(master), & &1.site_id)) ==
               Enum.sort([site.id, other_site.id])

      assert logs(no_migration) == []
      assert logs(nil) == []
    end

    test "follow each new entry of the site's runs as it is broadcast", %{
      site: site,
      admin: admin
    } do
      [topic] = Activity.topics(%{current_user: admin})
      :ok = MishkaCmsMigration.TestEndpoint.subscribe(topic)

      create_run!(site, admin, %{})

      assert_receive %Phoenix.Socket.Broadcast{} = broadcast
      assert Activity.handles?(broadcast)

      assert %{action: :connected, message: "Connected to old.example.com."} =
               Activity.to_entry(broadcast)

      assert Activity.topics(%{current_user: nil}) == []
    end
  end

  describe "the core's activity log" do
    test "merges a site's run steps, filed under the runs, and filters them by severity", %{
      site: site,
      admin: admin
    } do
      run = create_run!(site, admin, %{"redirect" => @rows})
      MishkaCmsMigration.cancel_run!(run, actor: admin, tenant: site.id)

      entries =
        Query.page(%{
          site_id: site.id,
          limit: 20,
          resource: to_string(MishkaCmsMigration.MigrationRun)
        })

      assert Enum.map(entries, &{&1.action, &1.message}) == [
               {:cancelled, "The run of old.example.com was cancelled."},
               {:connected, "Connected to old.example.com."}
             ]

      assert [%{action: :cancelled}] =
               Query.page(%{
                 site_id: site.id,
                 limit: 20,
                 severity: "warn",
                 resource: to_string(MishkaCmsMigration.MigrationRun)
               })

      assert Query.page(%{
               site_id: create_site!().id,
               limit: 20,
               resource: to_string(MishkaCmsMigration.MigrationRun)
             }) == []
    end
  end
end
