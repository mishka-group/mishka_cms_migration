# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Resources.Changes.CancelJobs do
  @moduledoc """
  Cancels a run's jobs on the `migration` queue that are not done — waiting, scheduled, waiting to
  be tried again or running — with `Oban.cancel_all_jobs/1`, in the same transaction as the action,
  once the run is written. A cancelled job no longer holds the site's one migration job, so the
  site can start another run.

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

  defp cancel(run) do
    {:ok, _cancelled} =
      Oban.Job
      |> where([job], job.queue == "migration")
      |> where([job], fragment("?->>'run_id'", job.args) == ^run.id)
      |> Oban.cancel_all_jobs()

    {:ok, run}
  end
end
