# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Resources.Notifiers.Steps do
  @moduledoc """
  What a run's steps tell the admins, an Ash notifier on `MishkaCmsMigration.MigrationRun`, run once
  a step is saved.

  When a dry run or an import ends — it finished, its job failed, or an admin cancelled it while it
  ran — the run's user (who created it) and the admin whose job it was (who pressed Dry run or
  Import) are told in the topbar bell, through the core's `MishkaCmsCore.Notify.deliver/2`: a title
  such as "Import finished", one sentence (`sentence/2`), such as "Import of localhost:8089
  finished: 384 created, 371 updated, 185 skipped.", and a link to the Migration page. The admin
  who cancelled a run is not told of it. Nothing told names the run's connection or its secret.
  The step is saved before it is told, so a notification that cannot be sent is logged and changes
  nothing.

  A step is the action and what it ended (`step/1`): a failure is the step of the job that failed,
  its worker (`context.ash_oban.job`, which AshOban hands its trigger's `on_error`, and
  `MishkaCmsMigration.Workers.Helpers.Discarded` hands on), and a cancel the step the run was in.

  Each kind of notification is a type, `"migration:dry_run:finished"` through
  `"migration:import:cancelled"`, which a site may turn off with the setting
  `MishkaCmsCore.Notify.setting_key/1` names; none is registered, so each is on.
  """

  use Ash.Notifier
  use Gettext, backend: MishkaCmsCore.Gettext

  require Logger

  alias MishkaCmsCore.Notify
  alias MishkaCmsMigration.MigrationRun

  @link "/admin/dashboard/migration"

  @workers %{
    "MishkaCmsMigration.Workers.DryRunWorker" => :dry_run,
    "MishkaCmsMigration.Workers.ImportWorker" => :import
  }

  @told %{
    dry_run_finished:
      {"migration:dry_run:finished", gettext_noop("Dry run finished"), :success,
       "hero-check-circle"},
    import_finished:
      {"migration:import:finished", gettext_noop("Import finished"), :success,
       "hero-check-circle"},
    dry_run_failed:
      {"migration:dry_run:failed", gettext_noop("Dry run failed"), :error,
       "hero-exclamation-triangle"},
    import_failed:
      {"migration:import:failed", gettext_noop("Import failed"), :error,
       "hero-exclamation-triangle"},
    dry_run_cancelled:
      {"migration:dry_run:cancelled", gettext_noop("Dry run cancelled"), :warn, "hero-x-circle"},
    import_cancelled:
      {"migration:import:cancelled", gettext_noop("Import cancelled"), :warn, "hero-x-circle"}
  }

  @typedoc "A step of a run's life, as it is told."
  @type step ::
          :dry_run_finished
          | :dry_run_failed
          | :dry_run_cancelled
          | :import_finished
          | :import_failed
          | :import_cancelled
          | :cancelled

  @impl Ash.Notifier
  def notify(%Ash.Notifier.Notification{} = notification) do
    notification |> step() |> told(notification)
    :ok
  rescue
    error ->
      Logger.error("[MishkaCmsMigration] a run's step was not told: #{Exception.message(error)}")
      :ok
  end

  @doc """
  The step a notification of `MishkaCmsMigration.MigrationRun` saved, or `nil` for an action that
  ends none: a cancel of a run that was neither dry running nor importing is `:cancelled`.
  """
  @spec step(Ash.Notifier.Notification.t()) :: step() | nil
  def step(%{action: %{name: :finish_dry_run}}), do: :dry_run_finished
  def step(%{action: %{name: :finish_import}}), do: :import_finished

  def step(%{action: %{name: :fail}, changeset: %{context: %{ash_oban: %{job: job}}}}),
    do: failed(Map.get(@workers, job.worker))

  def step(%{action: %{name: :cancel}, changeset: %{data: %{status: status}}}),
    do: cancelled(status)

  def step(_notification), do: nil

  defp failed(:dry_run), do: :dry_run_failed
  defp failed(:import), do: :import_failed
  defp failed(_unknown), do: nil

  defp cancelled(:dry_running), do: :dry_run_cancelled
  defp cancelled(:importing), do: :import_cancelled
  defp cancelled(_waiting), do: :cancelled

  @doc """
  The sentence that tells `step` of the run whose host, counts and reason `run` carries: a run, or
  any map with its `source_host`, `report` and `reason`.

      sentence(:import_finished, run)
      #=> "Import of localhost:8089 finished: 384 created, 371 updated, 185 skipped."
  """
  @spec sentence(step(), map()) :: String.t()
  def sentence(:dry_run_finished, %{source_host: host, report: report}),
    do: gettext("Dry run of %{host} finished: %{result}.", host: host, result: result(report))

  def sentence(:import_finished, %{source_host: host, report: report}),
    do: gettext("Import of %{host} finished: %{result}.", host: host, result: result(report))

  def sentence(:dry_run_failed, %{source_host: host, reason: reason}) when is_binary(reason),
    do: gettext("Dry run of %{host} failed: %{reason}.", host: host, reason: reason)

  def sentence(:dry_run_failed, %{source_host: host}),
    do: gettext("Dry run of %{host} failed.", host: host)

  def sentence(:import_failed, %{source_host: host, reason: reason}) when is_binary(reason),
    do: gettext("Import of %{host} failed: %{reason}.", host: host, reason: reason)

  def sentence(:import_failed, %{source_host: host}),
    do: gettext("Import of %{host} failed.", host: host)

  def sentence(:dry_run_cancelled, %{source_host: host}),
    do: gettext("Dry run of %{host} was cancelled.", host: host)

  def sentence(:import_cancelled, %{source_host: host}),
    do: gettext("Import of %{host} was cancelled.", host: host)

  def sentence(:cancelled, %{source_host: host}),
    do: gettext("The run of %{host} was cancelled.", host: host)

  defp result(report) do
    case MigrationRun.result_outcomes(report) do
      [] ->
        gettext("nothing to move")

      outcomes ->
        Enum.map_join(outcomes, ", ", fn {outcome, count} ->
          MigrationRun.outcome_count(outcome, count)
        end)
    end
  end

  defp told(step, %{data: run} = notification) when is_map_key(@told, step) do
    {type, title, severity, icon} = Map.fetch!(@told, step)
    actor_id = actor_id(notification)

    Notify.deliver(
      %{
        type: type,
        title: title,
        body: sentence(step, run),
        icon: icon,
        severity: severity,
        link: @link,
        source: "mishka_cms_migration",
        metadata: %{"run_id" => run.id, "source_host" => run.source_host}
      },
      users: Enum.uniq(Enum.reject([run.user_id, actor_id], &is_nil/1)),
      site_id: run.site_id,
      actor: actor_id,
      except: canceller(step, actor_id)
    )
  end

  defp told(_step, _notification), do: :ok

  defp actor_id(%{actor: %{id: id}}), do: id

  defp actor_id(%{changeset: %{context: %{ash_oban: %{job: %{args: %{"actor_id" => id}}}}}}),
    do: id

  defp actor_id(_notification), do: nil

  defp canceller(step, actor_id) when step in [:dry_run_cancelled, :import_cancelled],
    do: List.wrap(actor_id)

  defp canceller(_step, _actor_id), do: []
end
