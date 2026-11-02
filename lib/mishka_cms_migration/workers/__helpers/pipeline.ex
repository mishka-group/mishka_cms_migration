# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Workers.Helpers.Pipeline do
  @moduledoc """
  What a `migration` job does with its run (`call/2`, for `MishkaCmsMigration.Workers.DryRunWorker`
  and `MishkaCmsMigration.Workers.ImportWorker`): find the run waiting for it and who asked, walk
  the run's source, and save what came of it on the run.

  ## The walk

  The job connects once with the run's connection and its opened secret
  (`MishkaCmsMigration.MigrationRun.open_secret/1`) and reads the source's facts (`extra/1`), then
  walks the kinds in the order the source's `kinds/0` gives them, and pages through each with
  `list/3` until the source answers no cursor. Each row is normalized into an item
  (`MishkaCmsMigration.Source.Item`), decided (`MishkaCmsMigration.Workers.Helpers.Decision`) and
  settled (`MishkaCmsMigration.Workers.Helpers.Writer`): written in an import, reported in a dry
  run. After each page with rows the job saves how far it is on the run
  (`MishkaCmsMigration.MigrationRun`'s `:record_progress`: the kind and the counts so far), and the
  run's own Ash notifier broadcasts it on `"migration_run:<site_id>:updated"`.

  A source id met again in the same kind, on the same page or a later one, is skipped as
  `"duplicate_in_source"` and not recorded: the first row with that id is the one written and
  remembered. A row the source cannot normalize fails alone, and the report says why, also when
  `normalize/3` raises or exits: a plugin's mistake costs that item, not the run.

  ## Dry run and import

  A dry run decides and reports; it writes nothing and fires no event. An import writes each item
  as the admin who pressed Import, and once every kind is walked its report and the source's facts
  are saved on the run and the report is handed to `migration:import:finished`
  (`MishkaCmsMigration.Events`).

  ## When the job stops

  A run that is no longer waiting for its job — an admin cancelled it — cancels the job: at its
  start, at the first page whose progress the run no longer takes, and when the run refuses the
  report. A job whose run is gone is cancelled too.

  An error from `connect/2` or `list/3`, a raise outside a single item, a secret that can no longer
  be opened, or a source whose cursors never end — `{:cursor_repeated, kind}` when `list/3` answers
  a cursor it already answered for that kind, `{:too_many_pages, kind}` after 10,000 pages of one
  kind — fails the job. Oban tries it again, and the last attempt fails the run with the reason
  (`MishkaCmsMigration.MigrationRun`'s `:fail`), which also clears its secret. A last attempt that
  never returns — Oban stops it at its timeout, or it crashes past every rescue — fails its run
  through Oban's own telemetry (`MishkaCmsMigration.Workers.Helpers.Discarded`).
  """

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsMigration.{Events, MigrationRun, Report, Source}
  alias MishkaCmsMigration.MigrationRun.Options
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Workers.Helpers.{Decision, Writer}

  @running %{dry_run: :dry_running, import: :importing}
  @max_pages 10_000

  @typedoc "Whether a job only reports, or writes."
  @type mode :: :dry_run | :import

  @doc "Runs `job` of a run in `mode` and answers as an `Oban.Worker` does."
  @spec call(Oban.Job.t(), mode()) :: :ok | {:error, term()} | {:cancel, term()}
  def call(%Oban.Job{args: args} = job, mode) do
    with {:ok, run} <- running(args, mode) do
      run |> walked(mode, args) |> settled(run, mode, job)
    end
  end

  defp running(%{"run_id" => run_id, "site_id" => site_id}, mode) do
    run_id
    |> MishkaCmsMigration.get_run(tenant: site_id, authorize?: false)
    |> waiting(Map.fetch!(@running, mode))
  end

  defp waiting({:ok, %{status: status} = run}, status), do: {:ok, run}
  defp waiting({:ok, _run}, _status), do: {:cancel, :not_running}
  defp waiting({:error, _error}, _status), do: {:cancel, :run_not_found}

  defp walked(run, mode, args) do
    with {:ok, actor} <- actor(args),
         {:ok, report, extra} <- walk(run, mode, actor) do
      {:ok, report, extra, actor}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp settled({:ok, report, extra, actor}, run, mode, _job),
    do: finish(run, mode, Report.done(report), extra, actor)

  defp settled({:error, :not_running}, _run, _mode, _job), do: {:cancel, :not_running}

  defp settled({:error, reason}, run, _mode, %{attempt: attempt, max_attempts: attempt}) do
    MishkaCmsMigration.fail_run(run, Report.reason(reason), authorize?: false)
    {:cancel, reason}
  end

  defp settled({:error, reason}, _run, _mode, _job), do: {:error, reason}

  defp actor(%{"actor_id" => id}) when is_binary(id),
    do: MishkaCmsCore.Accounts.User |> Ash.get(id, authorize?: false) |> found_actor()

  defp actor(_args), do: {:error, :actor_not_found}

  defp found_actor({:ok, user}), do: {:ok, AccessPermissions.with_permissions(user)}
  defp found_actor({:error, _error}), do: {:error, :actor_not_found}

  defp finish(run, :dry_run, report, extra, _actor),
    do: run |> MishkaCmsMigration.finish_dry_run(report, extra, authorize?: false) |> saved()

  defp finish(run, :import, report, extra, actor) do
    with {:ok, run} <-
           run |> MishkaCmsMigration.finish_import(report, extra, authorize?: false) |> saved() do
      Events.finished(report, run, actor)
    end
  end

  defp saved({:ok, run}), do: {:ok, run}
  defp saved({:error, _refused}), do: {:cancel, :not_running}

  defp walk(run, mode, actor) do
    with {:ok, options} <- Options.builder(run.options),
         {:ok, source} <- Source.fetch(run.source),
         {:ok, secret} <- MigrationRun.open_secret(run),
         {:ok, conn} <- source.connect(run.connection, secret),
         extra = source.extra(conn),
         {:ok, report} <-
           walk_kinds(%{
             run: run,
             mode: mode,
             actor: actor,
             source: source,
             conn: conn,
             options: options
           }) do
      {:ok, report, extra}
    end
  end

  defp walk_kinds(state) do
    Enum.reduce_while(state.source.kinds(), {:ok, Report.new()}, fn kind, {:ok, report} ->
      walk = %{kind: kind, cursor: nil, cursors: %{}, source_ids: %{}, pages: 0}
      state |> walk_kind(walk, report) |> walked_kind()
    end)
  end

  defp walked_kind({:ok, report}), do: {:cont, {:ok, report}}
  defp walked_kind({:error, reason}), do: {:halt, {:error, reason}}

  defp walk_kind(_state, %{pages: @max_pages, kind: kind}, _report),
    do: {:error, {:too_many_pages, kind}}

  defp walk_kind(state, walk, report) do
    with {:ok, rows, next} <- state.source.list(state.conn, walk.kind, walk.cursor),
         {report, source_ids} = page(state, walk, rows, report),
         :ok <- progress(state, walk.kind, rows, report.counts) do
      walk_on(state, %{walk | source_ids: source_ids, pages: walk.pages + 1}, next, report)
    end
  end

  defp walk_on(_state, _walk, nil, report), do: {:ok, report}

  defp walk_on(_state, %{cursors: cursors, kind: kind}, next, _report)
       when is_map_key(cursors, next),
       do: {:error, {:cursor_repeated, kind}}

  defp walk_on(state, walk, next, report),
    do:
      walk_kind(state, %{walk | cursor: next, cursors: Map.put(walk.cursors, next, true)}, report)

  defp page(state, walk, rows, report) do
    {built, source_ids} =
      rows
      |> Enum.map(&build(state, walk.kind, &1))
      |> Enum.map_reduce(walk.source_ids, &once/2)

    plans = Decision.call(state, walk.kind, for({:ok, item} <- built, do: item))

    {Enum.reduce(built, report, &Report.add(&2, settle(state, plans, &1))), source_ids}
  end

  defp once({:ok, %Item{source_id: source_id} = item}, source_ids)
       when is_map_key(source_ids, source_id),
       do: {{:duplicate, item}, source_ids}

  defp once({:ok, item}, source_ids), do: {{:ok, item}, Map.put(source_ids, item.source_id, true)}
  defp once(failed, source_ids), do: {failed, source_ids}

  defp build(state, kind, row) do
    row
    |> state.source.normalize(kind, source_context(state))
    |> built(kind)
  rescue
    error -> {:failed, %Item{kind: kind, source_id: nil}, error}
  catch
    :exit, reason -> {:failed, %Item{kind: kind, source_id: nil}, {:exit, reason}}
  end

  defp built({:ok, attrs}, kind),
    do: attrs |> Map.put(:kind, kind) |> Item.build() |> item_built(kind, attrs)

  defp built({:error, reason}, kind), do: {:failed, %Item{kind: kind, source_id: nil}, reason}

  defp item_built({:ok, item}, _kind, _attrs), do: {:ok, item}

  defp item_built({:error, errors}, kind, attrs),
    do: {:failed, %Item{kind: kind, source_id: source_id(attrs)}, errors}

  defp source_id(%{source_id: id}) when is_binary(id) or is_integer(id), do: to_string(id)
  defp source_id(%{"source_id" => id}) when is_binary(id) or is_integer(id), do: to_string(id)
  defp source_id(_attrs), do: nil

  defp settle(state, plans, {:ok, item}),
    do: Writer.call(state, item, Map.fetch!(plans, item.source_id))

  defp settle(state, _plans, {:duplicate, item}), do: Writer.call(state, item, :duplicate)

  defp settle(state, _plans, {:failed, item, reason}),
    do: Writer.call(state, item, {:failed, Report.reason(reason)})

  defp progress(_state, _kind, [], _counts), do: :ok

  defp progress(state, kind, _rows, counts) do
    state.run
    |> MishkaCmsMigration.record_progress(%{kind: kind, counts: counts}, authorize?: false)
    |> progressed()
  end

  defp progressed({:ok, _run}), do: :ok
  defp progressed({:error, _refused}), do: {:error, :not_running}

  defp source_context(state),
    do: %{
      site_id: state.run.site_id,
      run_id: state.run.id,
      source_host: state.run.source_host,
      options: state.options
    }
end
