# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Activity do
  @moduledoc """
  The runs' log (`MishkaCmsMigration.MigrationLog`) as a source of the core's activity log, so a
  run's steps show where the CMS shows what happened, each in the sentence the bell says
  (`MishkaCmsMigration.Resources.Notifiers.Steps.sentence/2`).

    * The Migration page's Logs, next to the runs table's count, is the core's own feed
      (`MishkaCmsCoreWeb.Live.Admin.Components.ActivityFeed`) over this source alone
      (`MishkaCmsCore.Activity.Behaviours.Source`): the latest entries when it opens, read as the
      admin, and each new one as its broadcast arrives. A master reads every site's, a site admin
      their own site's.
    * The core's full activity log, which the feed's "View all logs" opens, merges the same entries
      as one more branch of its query (`MishkaCmsCore.Activity.Behaviours.UnionSource`), registered
      on `activity:sources`, filed under `MishkaCmsMigration.MigrationRun`, so whoever may read the
      runs (`admin:dashboard:migration`) sees them there.

  An entry's badge says how the step went: connected, started, finished, failed or cancelled. A
  failed step is an error, a cancelled one a warning, and the rest information.
  """

  use MishkaCmsCore.ProviderRegistry, event: "activity:sources", priority: 50
  use Gettext, backend: MishkaCmsCore.Gettext

  @behaviour MishkaCmsCore.Activity.Behaviours.Source
  @behaviour MishkaCmsCore.Activity.Behaviours.UnionSource

  alias MishkaCmsCore.Activity.{Helpers, Query}
  alias MishkaCmsMigration.{MigrationLog, MigrationRun, Report}
  alias MishkaCmsMigration.Resources.Notifiers.Steps

  @resource to_string(MigrationRun)
  @failed [:dry_run_failed, :import_failed]
  @cancelled [:dry_run_cancelled, :import_cancelled, :cancelled]

  @impl MishkaCmsCore.Activity.Behaviours.Source
  def topics(scope) do
    case Helpers.reach(scope[:current_user]) do
      :nothing -> []
      :everything -> ["migration_log:created"]
      {:site, site_id} -> ["migration_log:#{site_id}:created"]
    end
  end

  @impl MishkaCmsCore.Activity.Behaviours.Source
  def handles?(%Phoenix.Socket.Broadcast{
        payload: %Ash.Notifier.Notification{resource: resource}
      }),
      do: resource == MigrationLog

  def handles?(_broadcast), do: false

  @impl MishkaCmsCore.Activity.Behaviours.Source
  def to_entry(%Phoenix.Socket.Broadcast{
        payload: %Ash.Notifier.Notification{resource: MigrationLog, data: entry}
      }),
      do: entry(entry)

  def to_entry(_broadcast), do: nil

  @impl MishkaCmsCore.Activity.Behaviours.Source
  def initial_fetch(scope, limit) do
    case Helpers.reach(scope[:current_user]) do
      :nothing -> []
      reach -> scope.current_user |> read(tenant(reach), limit) |> Enum.map(&entry/1)
    end
  end

  defp tenant({:site, site_id}), do: site_id
  defp tenant(:everything), do: nil

  defp read(user, tenant, limit) do
    MigrationLog
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read(actor: user, tenant: tenant)
    |> case do
      {:ok, entries} -> entries
      {:error, _refused} -> []
    end
  end

  @impl MishkaCmsCore.Activity.Behaviours.UnionSource
  def id, do: "migration"

  @impl MishkaCmsCore.Activity.Behaviours.UnionSource
  def union_branch(%{site_id: site_id, severity: severity, shown: shown}) do
    resource = "'#{@resource}'"

    sql = """
    (SELECT '#{id()}' AS source, #{resource} AS resource,
            step::text AS action,
            run_id::text AS source_id,
            id::text AS event_id,
            site_id::text AS site_id,
            user_id::text AS user_id,
            inserted_at AS inserted_at,
            jsonb_build_object('source_host', source_host, 'counts', counts, 'reason', reason) AS payload
       FROM #{AshPostgres.DataLayer.Info.table(MigrationLog)}
      WHERE TRUE#{Query.version_site_clause(site_id, false)}#{severity_clause(severity)}#{Query.resource_clause(resource)}#{Query.shown_clause(resource, shown)}#{Query.search_clause(["source_host", "step::text", "COALESCE(reason, '')"])}
      ORDER BY inserted_at DESC
      LIMIT $1)\
    """

    {sql, []}
  end

  defp severity_clause("error"), do: " AND step IN (#{steps_sql(@failed)})"
  defp severity_clause("warn"), do: " AND step IN (#{steps_sql(@cancelled)})"
  defp severity_clause("info"), do: " AND step NOT IN (#{steps_sql(@failed ++ @cancelled)})"
  defp severity_clause(_any), do: ""

  defp steps_sql(steps), do: Enum.map_join(steps, ", ", &"'#{&1}'")

  @impl MishkaCmsCore.Activity.Behaviours.UnionSource
  def entry_from_row(row) do
    payload = row["payload"] || %{}

    entry(%{
      id: row["event_id"],
      step: step(row["action"]),
      source_host: payload["source_host"],
      counts: counts(payload["counts"]),
      reason: payload["reason"],
      run_id: row["source_id"],
      site_id: row["site_id"],
      user_id: row["user_id"],
      inserted_at: Helpers.to_datetime(row["inserted_at"])
    })
  end

  defp step(action), do: Enum.find(MigrationLog.steps(), &(Atom.to_string(&1) == action))

  defp counts(%{} = counts),
    do: Map.new(Report.outcomes(), &{&1, Map.get(counts, Atom.to_string(&1), 0)})

  defp counts(_none), do: nil

  @doc """
  One log entry, a `MishkaCmsMigration.MigrationLog` or a map with its fields, as an entry of the
  core's activity log (`t:MishkaCmsCore.Activity.Behaviours.Source.entry/0`).
  """
  @spec entry(map()) :: MishkaCmsCore.Activity.Behaviours.Source.entry()
  def entry(%{step: step} = entry) do
    {badge, tone} = badge(step)

    %{
      id: "migration-#{entry.id}",
      resource_label: label(step),
      action: step,
      severity: severity(step),
      tone: nil,
      badge_label: badge,
      badge_tone: tone,
      inserted_at: entry.inserted_at,
      source_id: entry.run_id,
      site_id: entry.site_id,
      user_id: entry.user_id,
      message: Steps.sentence(step, entry)
    }
  end

  defp severity(step) when step in @failed, do: :error
  defp severity(step) when step in @cancelled, do: :warn
  defp severity(_step), do: :info

  defp badge(:connected), do: {gettext("CONNECTED"), :sky}

  defp badge(step) when step in [:dry_run_started, :import_started],
    do: {gettext("STARTED"), :indigo}

  defp badge(step) when step in [:dry_run_finished, :import_finished],
    do: {gettext("FINISHED"), :emerald}

  defp badge(step) when step in @failed, do: {gettext("FAILED"), :rose}
  defp badge(_cancelled), do: {gettext("CANCELLED"), :amber}

  defp label(step)
       when step in [:dry_run_started, :dry_run_finished, :dry_run_failed, :dry_run_cancelled],
       do: gettext("Dry run")

  defp label(step)
       when step in [:import_started, :import_finished, :import_failed, :import_cancelled],
       do: gettext("Import")

  defp label(_step), do: gettext("Migration")
end
