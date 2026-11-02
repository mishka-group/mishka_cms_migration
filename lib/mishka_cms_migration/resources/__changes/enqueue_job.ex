# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Resources.Changes.EnqueueJob do
  @moduledoc """
  Queues the job of a run's AshOban trigger (`:trigger`) with `AshOban.run_trigger/3`, in the same
  transaction as the action, once the run is written, as the actor who asked.

      update :start_dry_run do
        change {MishkaCmsMigration.Resources.Changes.EnqueueJob, trigger: :run_dry_run}
      end

  Besides what AshOban keeps in it (the run's id, its site as the tenant, the actor through
  `MishkaCmsMigration.Workers.Helpers.Actor`), the job carries its site, who asked (`actor_id`) and
  the resource, the shape the activity log reads a job by
  (`MishkaCmsCore.Activity.Sources.Oban`). AshOban's own `run_oban_trigger` change takes no
  per-action arguments, so it cannot say who asked.
  """

  use Ash.Resource.Change

  alias MishkaCmsMigration.MigrationRun

  @impl true
  def init(opts), do: trigger(opts[:trigger], opts)

  @impl true
  def change(changeset, opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, run ->
      enqueue(run, opts[:trigger], context.actor)
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp enqueue(run, trigger, actor) do
    AshOban.run_trigger(run, trigger,
      actor: actor,
      tenant: run.site_id,
      args: %{site_id: run.site_id, actor_id: actor_id(actor), resource: inspect(MigrationRun)}
    )

    {:ok, run}
  end

  defp trigger(trigger, opts) when is_atom(trigger) and trigger != nil, do: {:ok, opts}

  defp trigger(other, _opts),
    do: {:error, "expected :trigger to be an AshOban trigger's name, got: #{inspect(other)}"}

  defp actor_id(%{id: id}) when is_binary(id), do: id
  defp actor_id(_nobody), do: nil
end
