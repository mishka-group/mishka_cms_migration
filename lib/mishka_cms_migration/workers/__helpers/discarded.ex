# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Workers.Helpers.Discarded do
  @moduledoc """
  Fails the run of a migration job Oban discarded — its last attempt timed out or crashed past
  every rescue, so the job never returned to say so — with Oban's reason, which also clears the
  run's secret (`MishkaCmsMigration.MigrationRun`'s `:fail`). A run no longer dry running or
  importing is left as it is. Attached to Oban's `[:oban, :job, :exception]` telemetry by
  `MishkaCmsMigration.Workers.attach/0`.

  A handler that raises is detached by `:telemetry` for good, so a failure here is logged and the
  handler stays attached.
  """

  require Logger

  alias MishkaCmsMigration.Report

  @workers ["MishkaCmsMigration.Workers.DryRunWorker", "MishkaCmsMigration.Workers.ImportWorker"]

  @doc "Handles one `[:oban, :job, :exception]` event."
  @spec call(list(), map(), map(), term()) :: :ok
  def call(
        _event,
        _measurements,
        %{job: %{worker: worker, args: args}, state: :discard} = meta,
        _config
      )
      when worker in @workers do
    fail(args, Report.reason(meta[:reason]))
  rescue
    error ->
      Logger.error(
        "[MishkaCmsMigration] a discarded job's run was not failed: #{Exception.message(error)}"
      )

      :ok
  end

  def call(_event, _measurements, _meta, _config), do: :ok

  defp fail(%{"run_id" => run_id, "site_id" => site_id}, reason) do
    with {:ok, run} <- MishkaCmsMigration.get_run(run_id, tenant: site_id, authorize?: false) do
      MishkaCmsMigration.fail_run(run, reason, authorize?: false)
    end

    :ok
  end
end
