# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Test.Factory do
  @moduledoc """
  Fixtures for this extension's suite: a migration admin, runs over
  `MishkaCmsMigration.Test.Plugins.FakeSource`, and the steps of a run with its job drained from
  the `migration` queue in the test's own process, as Oban would run it.

  The sites and users underneath are the core's `MishkaCmsCore.Test.Factory`.
  """

  import MishkaCmsCore.Test.Factory, only: [create_user_with_permissions!: 2]

  alias MishkaCmsMigration.Test.Plugins.{FakeSource, RedirectTarget}

  @admin ["admin:dashboard:migration", "admin:dashboard:runtime:redirect"]

  @doc "The fake source's and the redirect target's plugins, with the event each listens on."
  @spec fake_plugins() :: [{module(), String.t()}]
  def fake_plugins,
    do: [
      {FakeSource, MishkaCmsMigration.Source.event()},
      {RedirectTarget, MishkaCmsMigration.Target.event()}
    ]

  @doc """
  A user of `site` who may run migrations and write redirects, or only what `permissions` names.
  """
  def migration_admin!(site, permissions \\ @admin),
    do: create_user_with_permissions!(permissions, site_id: site.id)

  @doc """
  A fake source's redirect row: `id`, its old and new address, and any other field of the row.
  """
  def redirect_row(id, from, to, fields \\ %{}),
    do: Map.merge(%{"id" => id, "title" => "Redirect #{id}", "from" => from, "to" => to}, fields)

  @doc """
  A pending run of `site` by `actor` over the fake source holding `items` (kind to rows). `attrs`
  overrides the run's own input.
  """
  def create_run!(site, actor, items, attrs \\ %{}) do
    %{
      source: "fake",
      source_host: "old.example.com",
      connection: %{"items" => items},
      secret: "letmein"
    }
    |> Map.merge(attrs)
    |> MishkaCmsMigration.create_run!(actor: actor, tenant: site.id)
  end

  @doc "Starts the dry run of `run` as `actor`, drains the job and returns the run as it left it."
  def dry_run!(run, actor) do
    run
    |> MishkaCmsMigration.start_dry_run!(actor: actor, tenant: run.site_id)
    |> drained()
  end

  @doc "Starts the import of `run` as `actor`, drains the job and returns the run as it left it."
  def import!(run, actor) do
    run
    |> MishkaCmsMigration.start_import!(actor: actor, tenant: run.site_id)
    |> drained()
  end

  @doc "A run over the fake source holding `items`, dry-run and imported by `actor`."
  def migrate!(site, actor, items) do
    site
    |> create_run!(actor, items)
    |> dry_run!(actor)
    |> import!(actor)
  end

  defp drained(run) do
    %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)

    MishkaCmsMigration.get_run!(run.id,
      tenant: run.site_id,
      authorize?: false,
      load: [:created_count, :updated_count, :skipped_count, :failed_count]
    )
  end
end
