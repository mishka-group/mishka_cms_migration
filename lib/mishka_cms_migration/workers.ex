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

  ## Telemetry

  Each attempt of a job, and the New import form's connection check, tell `:telemetry` what they
  do, so a host can attach its own handlers for metrics or logs. Every event's name starts with
  `:mishka_cms_migration`. A reason is in words (`MishkaCmsMigration.Report.reason/1`), and no
  event carries a connection or its secret. Durations are in `:native` time units.

    * `[:mishka_cms_migration, :run, :start]` — an attempt of a dry run or an import begins
      (`:telemetry.span/3`). Measurements: `system_time`, `monotonic_time`. Metadata: `run_id`,
      `site_id`, `source` (the source's id), `source_host` and `mode` (`:dry_run` or `:import`).
    * `[:mishka_cms_migration, :run, :stop]` — the attempt ended. Measurements: `duration`,
      `monotonic_time` and, for a finished one, its report's `created`, `updated`, `skipped` and
      `failed` counts. Metadata: the start's, and `result`: `:finished`; `:cancelled` when the run
      no longer waited for its job; or `:failed`, with its `reason`, which AshOban tries again and,
      after the last attempt, fails the run on.
    * `[:mishka_cms_migration, :run, :exception]` — the attempt raised past the walk's own rescue.
      Measurements: `duration`, `monotonic_time`. Metadata: the start's, and `kind`, `reason` and
      `stacktrace`.
    * `[:mishka_cms_migration, :kind, :listed]` — the source answered the last page of a kind.
      Measurements: `count`, the rows it listed, and `pages`. Metadata: the run's, and `kind`.
    * `[:mishka_cms_migration, :item, :settled]` — an item was written and recorded, recorded as
      skipped or failed, or, in a dry run, reported. Measurements: `duration`. Metadata: the run's,
      and the item's `kind`, `source_id`, `outcome` (`:created`, `:updated`, `:skipped` or
      `:failed`) and `reason`.
    * `[:mishka_cms_migration, :connect, :refused]` — a source refused to connect, at the form's
      check or in a job (`MishkaCmsMigration.Source.connect/4`). Measurements: `system_time`.
      Metadata: `source`, `source_host`, `site_id` and `reason`, and from a job the run's `run_id`
      and `mode`.

  A handler runs in the process that emits the event, the job's or the form's, so it should be
  quick, and one that raises is detached by `:telemetry`:

      :telemetry.attach(
        "imports-to-metrics",
        [:mishka_cms_migration, :run, :stop],
        &MyApp.Metrics.handle_migration/4,
        nil
      )
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
