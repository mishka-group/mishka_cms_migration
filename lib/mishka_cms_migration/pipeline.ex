# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Pipeline do
  @moduledoc """
  The life of a `migration` job (`MishkaCmsMigration.Workers.DryRunWorker`,
  `MishkaCmsMigration.Workers.ImportWorker`): find the run waiting for it and who asked, walk the
  run's source (`MishkaCmsMigration.Walker`), and save what came of it on the run.

  A dry run decides and reports; it writes nothing and fires no event. An import writes each item
  as the admin who pressed Import, and once every kind is walked its report is saved on the run and
  handed to `migration:import:finished` (`MishkaCmsMigration.Events`).

  A walk that fails, or raises or exits in a plugin's code outside a single row, is tried again by
  Oban; the last attempt fails the run with the reason (`MishkaCmsMigration.MigrationRun`'s
  `:fail`), which also clears its secret. A job whose run is gone, or is not waiting for it (it was
  cancelled meanwhile), is cancelled, and so is one whose run refuses its report.
  """

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsMigration.{Events, Report, Walker}

  @running %{dry_run: :dry_running, import: :importing}

  @typedoc "Whether a job only reports, or writes."
  @type mode :: :dry_run | :import

  @doc """
  The `unique` option both workers share: one job of a site on the `migration` queue, whichever
  run and worker it is, until that job is done.
  """
  @spec unique() :: keyword()
  def unique,
    do: [fields: [:queue, :args], keys: [:site_id], states: :incomplete, period: :infinity]

  @doc """
  How long one attempt of either worker may run: an hour. Oban stops an attempt that runs longer and
  tries the job again; an import's next attempt skips what the last one wrote and recorded, so a
  large site goes on where it stopped. A job stopped on its last attempt leaves its run where it
  was, for an admin to cancel (`MishkaCmsMigration.MigrationRun`'s `:cancel`).
  """
  @spec timeout(Oban.Job.t()) :: pos_integer()
  def timeout(%Oban.Job{}), do: :timer.hours(1)

  @doc """
  Runs `job` of a run in `mode` and answers as an `Oban.Worker` does.
  """
  @spec perform(Oban.Job.t(), mode()) :: :ok | {:error, term()} | {:cancel, term()}
  def perform(%Oban.Job{args: args} = job, mode) do
    case running(args, mode) do
      {:ok, run} -> settle(run, mode, job)
      {:error, reason} -> {:cancel, reason}
    end
  end

  defp running(%{"run_id" => run_id, "site_id" => site_id}, mode) do
    status = Map.fetch!(@running, mode)

    case MishkaCmsMigration.get_run(run_id, tenant: site_id, authorize?: false) do
      {:ok, %{status: ^status} = run} -> {:ok, run}
      {:ok, _run} -> {:error, :not_running}
      {:error, _error} -> {:error, :run_not_found}
    end
  end

  defp settle(run, mode, job) do
    case walked(run, mode, job.args) do
      {:ok, report, actor} -> finish(run, mode, Report.done(report), actor)
      {:error, reason} -> retry_or_fail(run, reason, job.attempt >= job.max_attempts)
    end
  end

  defp walked(run, mode, args) do
    with {:ok, actor} <- actor(args),
         {:ok, report} <- Walker.walk(run, mode, actor) do
      {:ok, report, actor}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp actor(%{"actor_id" => id}) when is_binary(id) do
    case Ash.get(MishkaCmsCore.Accounts.User, id, authorize?: false) do
      {:ok, user} -> {:ok, AccessPermissions.with_permissions(user)}
      {:error, _error} -> {:error, :actor_not_found}
    end
  end

  defp actor(_args), do: {:error, :actor_not_found}

  defp finish(run, :dry_run, report, _actor) do
    case MishkaCmsMigration.finish_dry_run(run, report, authorize?: false) do
      {:ok, _run} -> :ok
      {:error, error} -> {:cancel, error}
    end
  end

  defp finish(run, :import, report, actor) do
    case MishkaCmsMigration.finish_import(run, report, authorize?: false) do
      {:ok, run} -> Events.finished(report, run, actor)
      {:error, error} -> {:cancel, error}
    end
  end

  defp retry_or_fail(run, reason, true) do
    MishkaCmsMigration.fail_run(run, Report.reason(reason), authorize?: false)
    {:cancel, reason}
  end

  defp retry_or_fail(_run, reason, false), do: {:error, reason}
end
