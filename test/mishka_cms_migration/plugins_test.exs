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

  test "a run whose source is not installed fails with the reason" do
    site = create_site!()
    admin = migration_admin!(site)

    run =
      site
      |> create_run!(admin, %{}, %{source: "ghost"})
      |> MishkaCmsMigration.start_dry_run!(actor: admin, tenant: site.id)

    args = %{run_id: run.id, site_id: site.id, actor_id: admin.id}

    assert {:cancel, _reason} =
             perform_job(MishkaCmsMigration.Workers.DryRunWorker, args, attempt: 3)

    assert %{status: :failed, error: error} =
             MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id)

    assert byte_size(error) > 0
  end
end
