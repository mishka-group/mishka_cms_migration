# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.TelemetryTest do
  @moduledoc """
  What a run's jobs and the New import form's check tell `:telemetry` ("Telemetry" in
  `MishkaCmsMigration.Workers`): each attempt as a span that says how it ended, each kind the source
  listed, each item settled, and a source that refused to connect. The handler is attached for the
  test and the jobs run in the test's own process, so every event is in the mailbox once a job
  returns.
  """
  use MishkaCmsMigration.DataCase, async: false

  alias MishkaCmsMigration.Events
  alias MishkaCmsMigration.Test.Plugins.ItemGate
  alias MishkaCmsMigration.Workers.{DryRunWorker, ImportWorker}

  @events [
    [:mishka_cms_migration, :run, :start],
    [:mishka_cms_migration, :run, :stop],
    [:mishka_cms_migration, :run, :exception],
    [:mishka_cms_migration, :kind, :listed],
    [:mishka_cms_migration, :item, :settled],
    [:mishka_cms_migration, :connect, :refused]
  ]

  @rows [
    %{"id" => 1, "from" => "/old-one", "to" => "/one"},
    %{"id" => 2, "from" => "/old-two", "to" => "/two"},
    %{"id" => 3, "from" => "/old-three", "to" => "/three"}
  ]

  setup do
    for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)

    handler = "migration-telemetry-test"
    :ok = :telemetry.attach_many(handler, @events, &__MODULE__.relay/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    site = create_site!()
    %{site: site, admin: migration_admin!(site)}
  end

  @doc false
  def relay(event, measurements, metadata, test),
    do: send(test, {:telemetry, event, measurements, metadata})

  defp received(event, gathered \\ []) do
    receive do
      {:telemetry, ^event, measurements, metadata} ->
        received(event, [{measurements, metadata} | gathered])
    after
      0 -> Enum.reverse(gathered)
    end
  end

  describe "an attempt" do
    test "of a dry run is a span that ends finished, with the report's counts", %{
      site: site,
      admin: admin
    } do
      run = site |> create_run!(admin, %{"redirect" => @rows}) |> dry_run!(admin)
      run_id = run.id
      site_id = site.id

      assert [{%{system_time: _, monotonic_time: _}, start}] =
               received([:mishka_cms_migration, :run, :start])

      assert %{
               run_id: ^run_id,
               site_id: ^site_id,
               source: "fake",
               source_host: "old.example.com",
               mode: :dry_run
             } = start

      assert [{stop_measurements, stop}] = received([:mishka_cms_migration, :run, :stop])
      assert %{created: 3, updated: 0, skipped: 0, failed: 0} = stop_measurements
      assert is_integer(stop_measurements.duration)
      assert %{run_id: ^run_id, mode: :dry_run, result: :finished} = stop
      assert received([:mishka_cms_migration, :run, :exception]) == []
    end

    test "of an import ends finished, with what it wrote", %{site: site, admin: admin} do
      run = migrate!(site, admin, %{"redirect" => @rows})
      run_id = run.id

      assert [{_dry_run, %{mode: :dry_run}}, {measurements, %{mode: :import} = stop}] =
               received([:mishka_cms_migration, :run, :stop])

      assert %{created: 3, failed: 0} = measurements
      assert %{run_id: ^run_id, result: :finished} = stop
    end

    @tag capture_log: true
    test "the source refuses ends failed with the reason, and tells of the refusal", %{
      site: site,
      admin: admin
    } do
      run = create_run!(site, admin, %{"redirect" => @rows})
      run_id = run.id

      Repo.query!(
        ~s(UPDATE mishka_cms_migration_runs SET connection = connection || '{"revoked": true}' WHERE id = $1),
        [Ecto.UUID.dump!(run.id)]
      )

      run = MishkaCmsMigration.start_dry_run!(run, actor: admin, tenant: site.id)
      [job] = assert_triggered(run, :run_dry_run)

      assert :ok = perform_job(DryRunWorker, job.args, attempt: 3)

      assert [{%{system_time: _}, refused}] =
               received([:mishka_cms_migration, :connect, :refused])

      assert %{source: "fake", reason: "unauthorized", run_id: ^run_id, mode: :dry_run} = refused

      assert [{measurements, stop}] = received([:mishka_cms_migration, :run, :stop])
      refute Map.has_key?(measurements, :created)
      assert %{result: :failed, reason: "unauthorized"} = stop
      assert received([:mishka_cms_migration, :kind, :listed]) == []
    end

    test "whose run is cancelled while it walks ends cancelled", %{site: site, admin: admin} do
      register_plugin!(ItemGate, Events.before_import_event())

      run =
        site
        |> create_run!(admin, %{
          "redirect" => [redirect_row(1, "/one", "/a", %{"gate" => "cancel"})]
        })
        |> dry_run!(admin)
        |> MishkaCmsMigration.start_import!(actor: admin, tenant: site.id)

      [job] = assert_triggered(run, :run_import)
      assert {:cancel, :not_running} = perform_job(ImportWorker, job.args)

      assert [{_dry_run, %{result: :finished}}, {_import, %{mode: :import, result: :cancelled}}] =
               received([:mishka_cms_migration, :run, :stop])
    end
  end

  describe "a walk" do
    test "tells of each kind the source listed, with its rows and pages", %{
      site: site,
      admin: admin
    } do
      site
      |> create_run!(admin, %{"redirect" => @rows, "note" => [%{"id" => 9}]})
      |> dry_run!(admin)

      listed =
        for {measurements, metadata} <- received([:mishka_cms_migration, :kind, :listed]),
            do: {metadata.kind, measurements.count, measurements.pages}

      assert listed == [{"redirect", 3, 2}, {"note", 1, 1}, {"page", 0, 1}, {"category", 0, 1}]
    end

    test "tells of each item it settles, with its outcome and why", %{site: site, admin: admin} do
      items = %{
        "redirect" => [%{"id" => 1, "from" => "/a", "to" => "/b"}, %{"id" => 1, "from" => "/a"}],
        "note" => [%{"id" => 9}, %{"id" => 10, "unreadable" => true}]
      }

      site |> create_run!(admin, items) |> import_all!(admin)

      settled =
        for {%{duration: duration}, metadata} <-
              received([:mishka_cms_migration, :item, :settled]),
            is_integer(duration),
            do:
              {metadata.mode, metadata.kind, metadata.source_id, metadata.outcome,
               metadata.reason}

      assert {:dry_run, "redirect", "1", :created, nil} in settled
      assert {:import, "redirect", "1", :created, nil} in settled
      assert {:import, "redirect", "1", :skipped, "duplicate_in_source"} in settled
      assert {:import, "note", "9", :skipped, "no_target"} in settled
      assert {:import, "note", nil, :failed, "unreadable"} in settled
      assert length(settled) == 8
    end
  end

  describe "the New import form's check" do
    test "tells of a source that refuses, with the site and host, and no run", %{
      site: site,
      admin: admin
    } do
      site_id = site.id

      assert {:error, _refused} =
               MishkaCmsMigration.create_run(
                 %{
                   source: "fake",
                   source_host: "old.example.com",
                   connection: %{"items" => %{}},
                   secret: "wrong"
                 },
                 actor: admin,
                 tenant: site.id
               )

      assert [{_measurements, refused}] = received([:mishka_cms_migration, :connect, :refused])

      assert %{
               source: "fake",
               source_host: "old.example.com",
               site_id: ^site_id,
               reason: "unauthorized"
             } = refused

      refute Map.has_key?(refused, :run_id)
      refute Enum.any?(Map.values(refused), &(&1 == "wrong"))
    end
  end

  defp import_all!(run, admin), do: run |> dry_run!(admin) |> import!(admin)
end
