# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Workers do
  @moduledoc """
  What the two `migration` workers share (`MishkaCmsMigration.Workers.DryRunWorker`,
  `MishkaCmsMigration.Workers.ImportWorker`): one job of a site at a time (`unique/0`), an hour an
  attempt (`timeout/1`), and the handler that fails the run of a job Oban discards (`attach/0`).
  What a job does is `MishkaCmsMigration.Workers.Helpers.Pipeline`.
  """

  @handler "mishka-cms-migration-discarded-jobs"

  @doc """
  Oban's `unique` option for both workers: one job of a site on the `migration` queue, whichever
  run and worker it is, until that job is done.
  """
  @spec unique() :: keyword()
  def unique,
    do: [fields: [:queue, :args], keys: [:site_id], states: :incomplete, period: :infinity]

  @doc """
  How long one attempt of either worker may run: an hour. Oban stops an attempt that runs longer and
  tries the job again; an import's next attempt skips what the last one wrote and recorded, so a
  large site goes on where it stopped. A job stopped on its last attempt fails its run (`attach/0`).
  """
  @spec timeout(Oban.Job.t()) :: pos_integer()
  def timeout(%Oban.Job{}), do: :timer.hours(1)

  @doc """
  Attaches `MishkaCmsMigration.Workers.Helpers.Discarded.call/4` to Oban's own
  `[:oban, :job, :exception]` telemetry, so a migration job Oban discards — its last attempt timed
  out or crashed past every rescue — fails its run. `MishkaCmsMigration.Application` attaches it
  at boot; attaching again replaces it. Only a job lost with its node, which Oban's lifeline puts
  back without that event, leaves its run where it was, for an admin to cancel.
  """
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.detach(@handler)

    :telemetry.attach(
      @handler,
      [:oban, :job, :exception],
      &MishkaCmsMigration.Workers.Helpers.Discarded.call/4,
      nil
    )
  end
end
