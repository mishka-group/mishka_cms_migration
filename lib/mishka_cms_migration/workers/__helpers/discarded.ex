# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Workers.Helpers.Discarded do
  @moduledoc """
  Fails the run of a migration job Oban discarded — its last attempt timed out or crashed past
  every rescue, so AshOban never ran the trigger's `on_error` — with Oban's reason
  (`MishkaCmsMigration.MigrationRun`'s `:fail`), which an admin can Run again. It runs outside any job,
  so it acts as the system (`authorize?: false`), and hands `:fail` the job as AshOban hands it its
  trigger's `on_error` (`context.ash_oban.job`), so what the run's steps tell says which step failed
  (`MishkaCmsMigration.Resources.Notifiers.Steps`). A run no longer dry running or importing is left
  as it is. Attached to Oban's `[:oban, :job, :exception]` telemetry by
  `MishkaCmsMigration.Workers.attach/0`.

  A handler that raises is detached by `:telemetry` for good, so a failure here is logged and the
  handler stays attached.
  """

  require Logger

  @workers ["MishkaCmsMigration.Workers.DryRunWorker", "MishkaCmsMigration.Workers.ImportWorker"]

  @doc "Handles one `[:oban, :job, :exception]` event."
  @spec call(list(), map(), map(), term()) :: :ok
  def call(
        _event,
        _measurements,
        %{job: %{worker: worker} = job, state: :discard} = meta,
        _config
      )
      when worker in @workers do
    fail(job, meta[:reason])
  rescue
    error ->
      Logger.error(
        "[MishkaCmsMigration] a discarded job's run was not failed: #{Exception.message(error)}"
      )

      :ok
  end

  def call(_event, _measurements, _meta, _config), do: :ok

  defp fail(%{args: %{"primary_key" => %{"id" => run_id}, "tenant" => site_id}} = job, error) do
    with {:ok, run} <- MishkaCmsMigration.get_run(run_id, tenant: site_id, authorize?: false) do
      MishkaCmsMigration.fail_run(run, error,
        authorize?: false,
        context: %{ash_oban: %{job: job}}
      )
    end

    :ok
  end
end
