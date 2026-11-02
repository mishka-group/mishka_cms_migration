# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Workers.Helpers.Pipeline do
  @moduledoc """
  What a `migration` job does with its run: the manual `update/3` behind
  `MishkaCmsMigration.MigrationRun`'s `:run_dry_run` and `:run_import`, the actions AshOban's
  triggers of the same names run (`MishkaCmsMigration.Workers.DryRunWorker`,
  `MishkaCmsMigration.Workers.ImportWorker`). It walks the run's source as the admin who started
  the run and saves what came of it on the run.

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

  An item to write that sits under another of its kind (`MishkaCmsMigration.Source.Item`'s
  `parent`) waits until that parent is settled, on the same page or a later one, whichever the
  source lists first, and is settled right after it, so the parent's CMS record is there for the
  target to point at. Its children wait in turn, so a tree is written from the top down. An item
  whose parent the kind never lists, or one in a loop of parents, is settled once the kind's last
  page is walked. An item left as it is (unchanged, or kept for an admin's edit) never waits.

  A source id met again in the same kind, on the same page or a later one, is skipped as
  `"duplicate_in_source"` and not recorded: the first row with that id is the one written and
  remembered. A row the source cannot normalize fails alone, and the report says why, also when
  `normalize/3` raises or exits: a plugin's mistake costs that item, not the run.

  Every action the job runs on the run and its items carries the trigger's context
  (`scope: context`), so the policies' `AshOban.Checks.AshObanInteraction` bypass lets the job
  through where every actor is refused. A target writes as the admin alone, under the CMS's own
  policies.

  ## Dry run and import

  A dry run decides and reports; it writes nothing and fires no event. An import writes each item
  as the admin who pressed Import, and once every kind is walked its report and the source's facts
  are saved on the run and the report is handed to `migration:import:finished`
  (`MishkaCmsMigration.Events`).

  ## When the job stops

  A run that is no longer waiting for its job — an admin cancelled it — cancels the job: at its
  start, when AshOban's worker finds the run out of the trigger's `where`; at the first page whose
  progress the run refuses for its status; and when it refuses the report for its status
  (`AshOban.Errors.CancelJob`, reason `:not_running`). Any other error saving the progress or the
  report fails the attempt, as an error of the walk does.

  An error from `connect/2` or `list/3`, a raise outside a single item, a secret that can no longer
  be opened, or a source whose cursors never end — `{:cursor_repeated, kind}` when `list/3` answers
  a cursor it already answered for that kind, `{:too_many_pages, kind}` after 10,000 pages of one
  kind — fails the job with its reason in words (`MishkaCmsMigration.Report.reason/1`). AshOban
  tries it again, and after the last attempt runs the trigger's `on_error`, the run's `:fail`,
  which keeps the reason and clears the secret. A last attempt that never returns — Oban stops it at
  its timeout, or it crashes past every rescue — fails its run through Oban's own telemetry
  (`MishkaCmsMigration.Workers.Helpers.Discarded`).
  """

  use Ash.Resource.ManualUpdate

  alias Ash.Error.Changes.InvalidAttribute
  alias AshOban.Errors.CancelJob
  alias MishkaCmsMigration.{Events, MigrationRun, Report, Source}
  alias MishkaCmsMigration.MigrationRun.Options
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Workers.Helpers.{Decision, Writer}

  @max_pages 10_000

  @typedoc "Whether a job only reports, or writes."
  @type mode :: :dry_run | :import

  @doc """
  Walks the run of `changeset` in `opts[:mode]` as `context.actor` and answers the run as its
  finish left it, an `AshOban.Errors.CancelJob` when the run stopped waiting, or the reason the
  walk could not go on.
  """
  @impl Ash.Resource.ManualUpdate
  def update(%Ash.Changeset{data: run}, opts, context) do
    run
    |> walked(opts[:mode], context)
    |> finished(run, opts[:mode], context)
    |> answered()
  end

  defp walked(run, mode, context) do
    walk(run, mode, context)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp finished({:ok, report, extra}, run, mode, context),
    do: finish(run, mode, Report.done(report), extra, context)

  defp finished({:error, reason}, _run, _mode, _context), do: {:error, reason}

  defp answered({:ok, run}), do: {:ok, run}
  defp answered({:error, :not_running}), do: {:error, CancelJob.exception(reason: :not_running)}
  defp answered({:error, reason}), do: {:error, Report.reason(reason)}

  defp finish(run, :dry_run, report, extra, context),
    do: run |> MishkaCmsMigration.finish_dry_run(report, extra, scope: context) |> saved()

  defp finish(run, :import, report, extra, context) do
    with {:ok, run} <-
           run |> MishkaCmsMigration.finish_import(report, extra, scope: context) |> saved() do
      Events.finished(report, run, context.actor)
      {:ok, run}
    end
  end

  defp saved({:ok, run}), do: {:ok, run}

  defp saved({:error, %Ash.Error.Invalid{errors: [%InvalidAttribute{field: :status} | _]}}),
    do: {:error, :not_running}

  defp saved({:error, error}), do: {:error, error}

  defp walk(run, mode, context) do
    with {:ok, options} <- Options.builder(run.options),
         {:ok, source} <- Source.fetch(run.source),
         {:ok, secret} <- MigrationRun.open_secret(run),
         {:ok, conn} <- source.connect(run.connection, secret),
         extra = source.extra(conn),
         {:ok, report} <-
           walk_kinds(%{
             run: run,
             mode: mode,
             actor: context.actor,
             scope: context,
             source: source,
             conn: conn,
             options: options
           }) do
      {:ok, report, extra}
    end
  end

  defp walk_kinds(state) do
    Enum.reduce_while(state.source.kinds(), {:ok, Report.new()}, fn kind, {:ok, report} ->
      walk = %{
        kind: kind,
        cursor: nil,
        cursors: %{},
        source_ids: %{},
        settled: %{},
        waiting: %{},
        pages: 0
      }

      state |> walk_kind(walk, report) |> walked_kind()
    end)
  end

  defp walked_kind({:ok, report}), do: {:cont, {:ok, report}}
  defp walked_kind({:error, reason}), do: {:halt, {:error, reason}}

  defp walk_kind(_state, %{pages: @max_pages, kind: kind}, _report),
    do: {:error, {:too_many_pages, kind}}

  defp walk_kind(state, walk, report) do
    with {:ok, rows, next} <- state.source.list(state.conn, walk.kind, walk.cursor),
         {report, walk} = page(state, walk, rows, report),
         :ok <- progress(state, walk.kind, rows, report.counts) do
      walk_on(state, %{walk | pages: walk.pages + 1}, next, report)
    end
  end

  defp walk_on(state, walk, nil, report), do: {:ok, unheld(state, walk, report)}

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

    Enum.reduce(built, {report, %{walk | source_ids: source_ids}}, &place(state, plans, &1, &2))
  end

  defp place(state, plans, {:ok, item}, placed),
    do: hold(state, {item, Map.fetch!(plans, item.source_id)}, placed)

  defp place(state, _plans, built, {report, walk}),
    do: {Report.add(report, settle(state, built)), walk}

  defp hold(_state, {%Item{parent: parent}, {outcome, _target, _record}} = held, {report, walk})
       when outcome in [:created, :updated] and is_binary(parent) and
              not is_map_key(walk.settled, parent),
       do: {report, %{walk | waiting: Map.update(walk.waiting, parent, [held], &(&1 ++ [held]))}}

  defp hold(state, held, placed), do: settle_tree(state, held, placed)

  defp settle_tree(state, {item, plan}, {report, walk}) do
    report = Report.add(report, Writer.call(state, item, plan))
    {children, waiting} = Map.pop(walk.waiting, item.source_id, [])
    walk = %{walk | settled: Map.put(walk.settled, item.source_id, true), waiting: waiting}

    Enum.reduce(children, {report, walk}, &hold(state, &1, &2))
  end

  defp unheld(_state, %{waiting: waiting}, report) when map_size(waiting) == 0, do: report

  defp unheld(state, walk, report) do
    [{parent, children}] = Enum.take(walk.waiting, 1)
    placed = {report, %{walk | waiting: Map.delete(walk.waiting, parent)}}
    {report, walk} = Enum.reduce(children, placed, &settle_tree(state, &1, &2))
    unheld(state, walk, report)
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

  defp settle(state, {:duplicate, item}), do: Writer.call(state, item, :duplicate)

  defp settle(state, {:failed, item, reason}),
    do: Writer.call(state, item, {:failed, Report.reason(reason)})

  defp progress(_state, _kind, [], _counts), do: :ok

  defp progress(state, kind, _rows, counts) do
    state.run
    |> MishkaCmsMigration.record_progress(%{kind: kind, counts: counts}, scope: state.scope)
    |> saved()
    |> progressed()
  end

  defp progressed({:ok, _run}), do: :ok
  defp progressed(error), do: error

  defp source_context(state),
    do: %{
      site_id: state.run.site_id,
      run_id: state.run.id,
      source_host: state.run.source_host,
      options: state.options,
      conn: state.conn
    }
end
