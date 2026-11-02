# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Workers do
  @moduledoc """
  The `migration` jobs: AshOban's triggers on `MishkaCmsMigration.MigrationRun` generate the two
  workers, `MishkaCmsMigration.Workers.DryRunWorker` (`:run_dry_run`) and
  `MishkaCmsMigration.Workers.ImportWorker` (`:run_import`), each three attempts of an hour, run
  as the admin who started the run (`MishkaCmsMigration.Workers.Helpers.Actor`). What a job does is
  `MishkaCmsMigration.Workers.Helpers.Pipeline`. One run of a site is dry running or importing at a
  time, held by the run's `:one_active_per_site` identity. Oban stops an attempt that runs longer
  than its hour and tries the job again; an import's next attempt skips what the last one wrote and
  recorded, so a large site goes on where it stopped.

  This module attaches the handler that fails the run of a job Oban discards (`attach/0`), the one
  ending AshOban's `on_error` cannot reach.
  """

  @handler "mishka-cms-migration-discarded-jobs"

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
