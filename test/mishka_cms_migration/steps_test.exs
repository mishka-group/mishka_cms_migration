# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.StepsTest do
  @moduledoc """
  What a run's steps tell the admins (`MishkaCmsMigration.Resources.Notifiers.Steps`): when a dry
  run or an import finishes, fails or is cancelled, the run's user and the admin whose job it was
  find it in their bell, read the way the bell reads it (the core's `:feed`), and nobody else does.
  The core's delivery writes the rows inline under test, so they are there once the step returns.
  """
  use MishkaCmsMigration.DataCase, async: false

  alias MishkaCmsCore.Notify.Notification
  alias MishkaCmsMigration.Workers.{DryRunWorker, ImportWorker}

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

  defp feed(user) do
    Notification
    |> Ash.Query.for_read(:feed)
    |> Ash.read!(actor: user, tenant: user.site_id, page: false)
    |> Enum.filter(&String.starts_with?(&1.type, "migration:"))
  end

  defp revoke!(run) do
    Repo.query!(
      ~s(UPDATE mishka_cms_migration_runs SET connection = connection || '{"revoked": true}' WHERE id = $1),
      [Ecto.UUID.dump!(run.id)]
    )
  end

  describe "a finished step" do
    test "tells the admin who ran it, with what it found and a link to the Migration page", %{
      site: site,
      admin: admin
    } do
      run = site |> create_run!(admin, %{"redirect" => @rows}) |> dry_run!(admin)

      assert [told] = feed(admin)
      assert told.type == "migration:dry_run:finished"
      assert told.title == "Dry run finished"
      assert told.body == "Dry run of old.example.com finished: 3 created."
      assert told.link == "/admin/dashboard/migration"
      assert told.severity == :success
      assert told.metadata["run_id"] == run.id
    end

    test "of an import says what it wrote, and nothing it told names the secret", %{
      site: site,
      admin: admin
    } do
      migrate!(site, admin, %{"redirect" => @rows, "note" => [%{"id" => 9}]})

      assert [import, dry_run] = feed(admin)
      assert dry_run.type == "migration:dry_run:finished"
      assert import.type == "migration:import:finished"
      assert import.body == "Import of old.example.com finished: 3 created, 1 skipped."

      for told <- [import, dry_run],
          text <- [told.title, told.body, inspect(told.metadata)],
          do: refute(text =~ "letmein")
    end

    test "of a source with nothing to move says so", %{site: site, admin: admin} do
      site |> create_run!(admin, %{}) |> dry_run!(admin)

      assert [%{body: "Dry run of old.example.com finished: nothing to move."}] = feed(admin)
    end

    test "tells the run's user and the admin who pressed it, and no other admin of the site", %{
      site: site,
      admin: admin
    } do
      presser = migration_admin!(site)
      bystander = migration_admin!(site)

      site |> create_run!(admin, %{"redirect" => @rows}) |> dry_run!(presser)

      assert [%{type: "migration:dry_run:finished"}] = feed(admin)
      assert [%{type: "migration:dry_run:finished", actor_id: actor_id}] = feed(presser)
      assert actor_id == presser.id
      assert feed(bystander) == []
    end
  end

  describe "a failed step" do
    @tag capture_log: true
    test "tells why its last attempt failed", %{site: site, admin: admin} do
      run = create_run!(site, admin, %{"redirect" => @rows})
      revoke!(run)
      run = MishkaCmsMigration.start_dry_run!(run, actor: admin, tenant: site.id)
      [job] = assert_triggered(run, :run_dry_run)

      assert {:ok, %{status: :failed}} = perform_job(DryRunWorker, job.args, attempt: 1)

      assert [told] = feed(admin)
      assert told.type == "migration:dry_run:failed"
      assert told.severity == :error

      assert told.body ==
               "Dry run of old.example.com failed: The source refused the user or the password."
    end

    test "Oban discarded at its timeout tells the admin who pressed Import", %{
      site: site,
      admin: admin
    } do
      run =
        site
        |> create_run!(admin, %{"redirect" => @rows})
        |> dry_run!(admin)
        |> MishkaCmsMigration.start_import!(actor: admin, tenant: site.id)

      [job] = assert_triggered(run, :run_import)

      :telemetry.execute([:oban, :job, :exception], %{duration: 0}, %{
        job: %{job | attempt: 3},
        state: :discard,
        kind: :error,
        reason: Oban.TimeoutError.exception({ImportWorker, :timer.hours(1)})
      })

      assert [told, %{type: "migration:dry_run:finished"}] = feed(admin)
      assert told.type == "migration:import:failed"
      assert told.body =~ "Import of old.example.com failed: "
      assert told.body =~ "timed out"
    end
  end

  describe "a cancelled step" do
    test "tells the run's user, not the admin who cancelled it", %{site: site, admin: admin} do
      canceller = migration_admin!(site)

      site
      |> create_run!(admin, %{"redirect" => @rows})
      |> dry_run!(admin)
      |> MishkaCmsMigration.start_import!(actor: admin, tenant: site.id)
      |> MishkaCmsMigration.cancel_run!(actor: canceller, tenant: site.id)

      assert [told, %{type: "migration:dry_run:finished"}] = feed(admin)
      assert told.type == "migration:import:cancelled"
      assert told.body == "Import of old.example.com was cancelled."
      assert told.severity == :warn
      assert feed(canceller) == []
    end

    test "by the admin who started it, or of a run that was not running, tells nobody", %{
      site: site,
      admin: admin
    } do
      other = migration_admin!(site)

      site
      |> create_run!(admin, %{"redirect" => @rows})
      |> MishkaCmsMigration.start_dry_run!(actor: admin, tenant: site.id)
      |> MishkaCmsMigration.cancel_run!(actor: admin, tenant: site.id)

      site
      |> create_run!(admin, %{"redirect" => @rows})
      |> MishkaCmsMigration.cancel_run!(actor: other, tenant: site.id)

      assert feed(admin) == []
      assert feed(other) == []
    end
  end
end
