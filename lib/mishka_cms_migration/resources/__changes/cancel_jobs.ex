# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Resources.Changes.CancelJobs do
  @moduledoc """
  Cancels a run's jobs that are not done — waiting, scheduled, waiting to be tried again or
  running — with `Oban.cancel_all_jobs/1`, in the same transaction as the action, once the run is
  written. A job AshOban queued for one of the run's triggers would find the run out of the
  trigger's `where` when it ran and stop there; cancelling it now leaves nothing waiting in the
  queue for a run that is over.

      update :cancel do
        change MishkaCmsMigration.Resources.Changes.CancelJobs
      end
  """

  use Ash.Resource.Change

  import Ecto.Query, only: [where: 3]

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.after_action(changeset, fn _changeset, run -> cancel(run) end)

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp cancel(%resource{} = run) do
    workers = resource |> AshOban.Info.oban_triggers() |> Enum.map(&inspect(&1.worker))

    {:ok, _cancelled} =
      Oban.Job
      |> where([job], job.worker in ^workers)
      |> where([job], fragment("?->'primary_key'->>'id'", job.args) == ^run.id)
      |> Oban.cancel_all_jobs()

    {:ok, run}
  end
end
