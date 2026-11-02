# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.PluginsTest do
  @moduledoc """
  Sources and targets are Mishka Installer plugins: they are found only while registered on their
  event, and a run whose source is not installed fails rather than reading anything.
  """
  use MishkaCmsMigration.DataCase, async: false

  alias MishkaCmsMigration.{Source, Target}
  alias MishkaCmsMigration.Test.Plugins.{FakeSource, RedirectTarget}

  test "a source and a target are found by id only while their plugins are registered" do
    assert {:error, _unknown} = Source.fetch("fake")
    assert {:error, _unknown} = Target.fetch("redirect")

    with_plugin(FakeSource, Source.event(), fn ->
      with_plugin(RedirectTarget, Target.event(), fn ->
        assert {:ok, FakeSource} = Source.fetch("fake")
        assert FakeSource in Source.all()
        assert {:ok, RedirectTarget} = Target.fetch("redirect")
        assert {:error, _unknown} = Target.fetch("note")
      end)
    end)

    assert {:error, _unknown} = Source.fetch("fake")
  end

  test "a stopped source is no longer installed, and a run of it is refused" do
    register_plugin!(FakeSource, Source.event())
    site = create_site!()
    admin = migration_admin!(site)
    assert FakeSource in Source.all()

    {:ok, _stopped} = MishkaInstaller.Event.Event.stop(:name, FakeSource, false)

    refute FakeSource in Source.all()
    assert {:error, :not_installed} = Source.fetch("fake")

    assert {:error, %Ash.Error.Invalid{errors: [%{field: :source}]}} =
             MishkaCmsMigration.create_run(%{source: "fake", source_host: "old.example.com"},
               actor: admin,
               tenant: site.id
             )
  end

  test "a stopped target writes nothing, and its kind is skipped as having no target" do
    for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)
    site = create_site!()
    admin = migration_admin!(site)

    {:ok, _stopped} = MishkaInstaller.Event.Event.stop(:name, RedirectTarget, false)

    assert {:error, :not_installed} = Target.fetch("redirect")
    run = migrate!(site, admin, %{"redirect" => [redirect_row(1, "/old", "/new")]})
    assert [%{outcome: :skipped, reason: "no_target"}] = run.report.entries
  end

  @tag capture_log: true
  test "a run whose source plugin is gone when its job runs fails with the reason" do
    site = create_site!()
    admin = migration_admin!(site)

    run =
      with_plugin(FakeSource, Source.event(), fn ->
        site
        |> create_run!(admin, %{})
        |> MishkaCmsMigration.start_dry_run!(actor: admin, tenant: site.id)
      end)

    [job] = assert_triggered(run, :run_dry_run)

    assert :ok = perform_job(MishkaCmsMigration.Workers.DryRunWorker, job.args, attempt: 3)

    assert %{status: :failed, reason: "not_installed"} =
             MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id)
  end
end
