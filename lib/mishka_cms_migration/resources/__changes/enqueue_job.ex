# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Resources.Changes.EnqueueJob do
  @moduledoc """
  Queues a run's job (`:worker`) in the same transaction as the action, once the run is written.

      update :start_dry_run do
        change {MishkaCmsMigration.Resources.Changes.EnqueueJob,
                worker: MishkaCmsMigration.Workers.DryRunWorker}
      end

  The job carries the run's id, its site, who asked (`actor_id`) and the resource, the shape the
  activity log reads a job by (`MishkaCmsCore.Activity.Sources.Oban`). The workers allow one job per
  site on the `migration` queue until it is done (`MishkaCmsMigration.Workers.DryRunWorker`); when
  one is already waiting or running, the action is refused and the run is left as it was.
  """

  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  alias Ash.Error.Changes.InvalidChanges
  alias MishkaCmsMigration.MigrationRun

  @busy dgettext_noop(
          "errors",
          "Another migration of this site is still waiting or running. Try again once it is done."
        )

  @impl true
  def init(opts) do
    case opts[:worker] do
      worker when is_atom(worker) and worker != nil -> {:ok, opts}
      other -> {:error, "expected :worker to be an Oban worker, got: #{inspect(other)}"}
    end
  end

  @impl true
  def change(changeset, opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, run ->
      enqueue(opts[:worker], run, context.actor)
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp enqueue(worker, run, actor) do
    %{
      run_id: run.id,
      site_id: run.site_id,
      actor_id: actor_id(actor),
      resource: inspect(MigrationRun)
    }
    |> worker.new()
    |> Oban.insert()
    |> case do
      {:ok, %Oban.Job{conflict?: true}} -> {:error, InvalidChanges.exception(message: @busy)}
      {:ok, %Oban.Job{}} -> {:ok, run}
      {:error, reason} -> {:error, reason}
    end
  end

  defp actor_id(%{id: id}) when is_binary(id), do: id
  defp actor_id(_nobody), do: nil
end
