# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.RunAgainTest do
  @moduledoc """
  Run again on an imported run, against what the seeded WordPress answered: the plans its dry run
  leaves on the Items page. Once it has walked the whole source, an item the source no longer lists
  has no plan; a dry run that stops halfway leaves every item a plan, the new one where it got to
  and the last one after that.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0, stub!: 1, recorded: 1]

  alias MishkaCmsMigration.MigrationItem
  alias MishkaCmsMigration.Workers.DryRunWorker

  @connection %{"url" => "http://localhost:8089", "user" => "admin"}
  @admin ["admin:dashboard:migration", "admin:dashboard:blog:post", "admin:dashboard:setting"]

  setup do
    stub!()
    site = create_site!()
    admin = migration_admin!(site, @admin)

    run =
      %{source: "wordpress", connection: @connection, secret: "app password"}
      |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)
      |> dry_run!(admin)
      |> import!(admin)

    %{site: site, admin: admin, run: run}
  end

  defp plans(site),
    do:
      MigrationItem
      |> Ash.read!(tenant: site.id, authorize?: false)
      |> Map.new(&{{&1.source_kind, &1.source_id}, {&1.plan, &1.plan_reason}})

  test "leaves no plan on an item the source no longer lists, once the dry run has walked it all",
       %{site: site, admin: admin, run: run} do
    [gone | listed] = recorded("tags")
    stub!(%{"/wp-json/wp/v2/tags" => {"application/json", Jason.encode!(listed)}})

    assert %{status: :dry_run} = dry_run!(run, admin)

    plans = plans(site)
    assert plans[{"tag", to_string(gone["id"])}] == {nil, nil}
    assert plans[{"tag", to_string(hd(listed)["id"])}] == {:skipped, "unchanged"}
  end

  @tag capture_log: true
  test "that stops halfway keeps the last plan of every item it did not reach",
       %{site: site, admin: admin, run: run} do
    before = plans(site)
    stub!(%{"/wp-json/wp/v2/menus" => :no_site})

    run = MishkaCmsMigration.start_dry_run!(run, actor: admin, tenant: site.id)
    [job] = assert_triggered(run, :run_dry_run)
    assert :ok = perform_job(DryRunWorker, job.args, attempt: 3)

    assert %{status: :failed} = MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id)

    plans = plans(site)
    assert plans[{"tag", "13"}] == {:skipped, "unchanged"}

    for {{"menu", _id} = key, plan} <- before, do: assert(plans[key] == plan)
    refute Enum.any?(plans, fn {_key, {plan, _reason}} -> is_nil(plan) end)
  end
end
