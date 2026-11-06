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
  (`MishkaCmsMigration.MigrationRun.open_secret/1`, through `MishkaCmsMigration.Source.connect/4`)
  and reads the source's facts (`extra/1`), then
  walks the kinds in the order the source's `kinds/0` gives them, and pages through each with
  `list/3` until the source answers no cursor. Each row is normalized into an item
  (`MishkaCmsMigration.Source.Item`), decided (`MishkaCmsMigration.Workers.Helpers.Decision`) and
  settled (`MishkaCmsMigration.Workers.Helpers.Writer`): written in an import, reported in a dry
  run. After each page with rows the job saves how far it is on the run
  (`MishkaCmsMigration.MigrationRun`'s `:record_progress`: the kind and the counts so far), and the
  run's own Ash notifier broadcasts it on `"migration_run:<site_id>:updated"`.

  An item that points at a CMS record an admin archived or deleted for good, such as a post at its
  tag, waits for the admin's decision on that record (`MishkaCmsMigration.Workers.Helpers.Needs`),
  skipped as `"waits_for: <kinds>"`, once the record's own kind, walked first, met it.

  An item that sits under another of its kind (`MishkaCmsMigration.Source.Item`'s `parent`) waits
  until that parent is settled, on the same page or a later one, whichever the source lists first,
  and is settled right after it, so the parent's CMS record is there for the target to point at.
  Its children wait in turn, so a tree is settled from the top down. An item whose parent the kind
  never lists, or one in a loop of parents, is settled once the kind's last page is walked.

  A parent an admin left out takes its children with it: an item whose parent was settled as
  `"left_out_by_admin"` or `"parent_left_out"` is skipped as `"parent_left_out"`, in a dry run and
  in an import, however deep it sits and whatever its own plan was, unless the admin chose for the
  item itself (left it out, or mapped it to a CMS record) or its CMS record is archived or deleted
  for good and waits for the admin's decision, which what points at it waits for too. Its CMS
  record, if an earlier import wrote one, is kept. An item under one an admin mapped goes under the
  record it was mapped to.

  A source id met again in the same kind, on the same page or a later one, is skipped as
  `"duplicate_in_source"` and not recorded: the first row with that id is the one written and
  remembered. A row the source cannot normalize fails alone, and the report says why, also when
  `normalize/3` raises or exits: a plugin's mistake costs that item, not the run.

  Every action the job runs on the run and its items carries the trigger's context
  (`scope: context`), so the policies' `AshOban.Checks.AshObanInteraction` bypass lets the job
  through where every actor is refused. A target writes as the admin alone, under the CMS's own
  policies.

  ## Dry run and import

  A dry run decides and reports; it writes nothing in the CMS and fires no event, and records what
  it would do with each item as the item's plan (`MishkaCmsMigration.MigrationItem`'s
  `:record_plan`), which the Items page shows before anything is imported. Once it has walked every
  kind, it empties, in one update (`:forget_plan`), the plan of each item of the run's source host
  on its site that it did not meet (one whose plan it did not record since it started), so a first
  dry run and a Run again alike leave a plan only on the items the source lists now; a dry run that
  stops halfway leaves every item the plan it had. An import writes each item as the admin who
  pressed Import, and once every kind is walked its report and the source's
  facts are saved on the run and the report is handed to `migration:import:finished`
  (`MishkaCmsMigration.Events`).

  ## Picked items

  A job of picked items (`MishkaCmsMigration.MigrationRun`'s "Picked items") is handed their source
  ids by kind (`items`) and the status its run goes back to (`back_to`). It walks only their kinds,
  in the source's order, so a picked category is settled before a picked post, and reads only
  their rows (`c:MishkaCmsMigration.Source.rows/3`, or the kind's pages from `list/3` for a source
  without it), keeping the picked ones once normalized. An item the source no longer answers is
  left as it is. Each page is decided as a whole run's is, so an admin's choices and the run's
  options hold, after its needs are read (`MishkaCmsMigration.Workers.Helpers.Needs`): an item the
  walk would create or update while its parent, or what its record points at, has no CMS record
  yet is skipped with the reason, and one under a parent an admin left out is skipped as
  `"parent_left_out"`. It saves no progress, empties no plan, and once walked hands its report to
  `MishkaCmsMigration.Report.merge/2` and the run to `:finish_items`; an import of picked items
  hands its own report to `migration:import:finished`. What fails a whole run fails a job of picked
  items only in part: a kind the source cannot answer, or that raises, fails its picked items
  alone, each recorded as failed with the reason and with what earlier runs kept of it (its title,
  slug, parent and CMS record), and the job goes on to the next kind; a source it cannot connect to
  fails every picked item so. The run then goes back where it was, as after any job of picked
  items. Every item it records is broadcast on
  `"migration_item:<site_id>:updated"` (`MishkaCmsMigration.MigrationItem`), which its actions'
  shared context (`picked_items?`) marks, so the Items page draws those rows again.

  ## When the job stops

  A run that is no longer waiting for its job — an admin cancelled it — cancels the job: at its
  start, when AshOban's worker finds the run out of the trigger's `where`; at the first page whose
  progress the run refuses for its status; and when it refuses the report for its status
  (`AshOban.Errors.CancelJob`, reason `:not_running`). Any other error saving the progress or the
  report fails the attempt, as an error of the walk does.

  A source that refuses what the run connects with — the password (`:unauthorized`, WordPress's
  401), a secret that can no longer be opened (`:unreadable_secret`), a file that is gone or not an
  export (`:no_file`, `:unreadable_file`) — fails the run at once through its `:fail`, as its
  `on_error` would, and the job ends without raising: trying again would meet the same refusal and
  hold the site for nothing. The run reads why in words
  (`MishkaCmsMigration.MigrationRun.reason_label/1`, its expanded row, the bell). Any other error
  from `connect/2` or `list/3`, a raise outside a single item, or a source whose cursors never end
  — `{:cursor_repeated, kind}` when `list/3` answers a cursor it already answered for that kind,
  `{:too_many_pages, kind}` after 10,000 pages of one kind — fails the job with its reason in words (`MishkaCmsMigration.Report.reason/1`). AshOban
  tries it again, and after the last attempt runs the trigger's `on_error`, the run's `:fail`,
  which keeps the reason; the run keeps its secret, so it can run again. A last attempt that never returns — Oban stops it at
  its timeout, or it crashes past every rescue — fails its run through Oban's own telemetry
  (`MishkaCmsMigration.Workers.Helpers.Discarded`).

  Each attempt is a `[:mishka_cms_migration, :run]` telemetry span, and the walk tells telemetry of
  each kind the source has listed and each item it settles (see "Telemetry" in
  `MishkaCmsMigration.Workers`).
  """

  use Ash.Resource.ManualUpdate

  require Ash.Query

  alias Ash.Error.Changes.InvalidAttribute
  alias AshOban.Errors.CancelJob
  alias MishkaCmsMigration.{Events, MigrationItem, MigrationRun, Report, Source}
  alias MishkaCmsMigration.MigrationRun.Options
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Workers.Helpers.{Decision, Needs, Writer}

  @max_pages 10_000
  @record_conflicts Decision.record_conflicts()
  @picked %{picked_items?: true}
  @refused [:unauthorized, :unreadable_secret, :no_file, :unreadable_file]

  @typedoc "Whether a job only reports, or writes."
  @type mode :: :dry_run | :import

  @doc """
  Walks the run of `changeset` in `opts[:mode]` as `context.actor` and answers the run as its
  finish left it, an `AshOban.Errors.CancelJob` when the run stopped waiting, or the reason the
  walk could not go on.
  """
  @impl Ash.Resource.ManualUpdate
  def update(%Ash.Changeset{data: run} = changeset, opts, context) do
    job = %{
      mode: opts[:mode],
      picked: Ash.Changeset.get_argument(changeset, :items),
      back_to: Ash.Changeset.get_argument(changeset, :back_to)
    }

    context = scope(context, job.picked)
    telemetry = telemetry(run, job.mode)

    :telemetry.span([:mishka_cms_migration, :run], telemetry, fn ->
      result = run |> walked(job, context, telemetry) |> finished(run, job, context)

      {answered(result), measured(result), Map.merge(telemetry, ended(result))}
    end)
  end

  defp scope(context, nil), do: context

  defp scope(%{source_context: source} = context, _picked),
    do: %{context | source_context: Map.update(source, :shared, @picked, &Map.merge(&1, @picked))}

  defp walked(run, job, context, telemetry) do
    walk(run, job, context, telemetry)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp finished({:ok, report, extra}, run, job, context),
    do: finish(run, job, Report.done(report), extra, context)

  defp finished({:error, reason}, run, %{picked: picked} = job, context) when is_map(picked) do
    state = %{run: run, mode: job.mode, picked: picked, scope: context}

    report =
      picked |> Map.keys() |> Enum.reduce(Report.new(), &failed(state, &1, reason, &2))

    finish(run, job, Report.done(report), %{}, context)
  end

  defp finished({:error, reason}, run, _job, context) when reason in @refused do
    run
    |> MishkaCmsMigration.fail_run(reason,
      scope: context,
      context: Map.take(context.source_context, [:shared, :ash_oban])
    )
    |> failed_at_once(reason)
  end

  defp finished({:error, reason}, _run, _job, _context), do: {:error, reason}

  defp failed_at_once({:ok, run}, reason), do: {:failed, run, reason}
  defp failed_at_once({:error, _error}, reason), do: {:error, reason}

  defp answered({:ok, run}), do: {:ok, run}
  defp answered({:failed, run, _reason}), do: {:ok, run}
  defp answered({:error, :not_running}), do: {:error, CancelJob.exception(reason: :not_running)}
  defp answered({:error, reason}), do: {:error, Report.reason(reason)}

  defp measured({:ok, %{report: %{counts: counts}}}), do: counts
  defp measured(_result), do: %{}

  defp ended({:ok, _run}), do: %{result: :finished}
  defp ended({:error, :not_running}), do: %{result: :cancelled}
  defp ended({:failed, _run, reason}), do: %{result: :failed, reason: Report.reason(reason)}
  defp ended({:error, reason}), do: %{result: :failed, reason: Report.reason(reason)}

  defp finish(run, %{picked: nil, mode: :dry_run}, report, extra, context),
    do: run |> MishkaCmsMigration.finish_dry_run(report, extra, scope: context) |> saved()

  defp finish(run, %{picked: nil, mode: :import}, report, extra, context),
    do:
      run
      |> MishkaCmsMigration.finish_import(report, extra, scope: context)
      |> saved()
      |> told(:import, report, context)

  defp finish(run, %{mode: mode, back_to: back_to}, report, _extra, context),
    do:
      run
      |> MishkaCmsMigration.finish_items(Report.merge(run.report, report), back_to,
        scope: context
      )
      |> saved()
      |> told(mode, report, context)

  defp told({:ok, run}, :import, report, context) do
    Events.finished(report, run, context.actor)
    {:ok, run}
  end

  defp told(answer, _mode, _report, _context), do: answer

  defp saved({:ok, run}), do: {:ok, run}

  defp saved({:error, %Ash.Error.Invalid{errors: [%InvalidAttribute{field: :status} | _]}}),
    do: {:error, :not_running}

  defp saved({:error, error}), do: {:error, error}

  defp walk(run, %{mode: mode} = job, context, telemetry) do
    with {:ok, options} <- Options.builder(run.options),
         {:ok, source} <- Source.fetch(run.source),
         {:ok, secret} <- MigrationRun.open_secret(run),
         {:ok, conn} <- Source.connect(source, run.connection, secret, telemetry),
         extra = source.extra(conn),
         started = DateTime.utc_now(),
         {:ok, report} <-
           walk_kinds(%{
             run: run,
             mode: mode,
             picked: job.picked,
             actor: context.actor,
             scope: context,
             source: source,
             conn: conn,
             options: options,
             context: target_context(run, mode, context, options),
             telemetry: telemetry
           }),
         :ok <- forget_plans(run, job, started, context) do
      {:ok, report, extra}
    end
  end

  defp forget_plans(run, %{mode: :dry_run, picked: nil}, started, context) do
    MigrationItem
    |> Ash.Query.filter(
      source_host == ^run.source_host and updated_at < ^started and not is_nil(plan)
    )
    |> Ash.bulk_update(:forget_plan, %{},
      scope: context,
      strategy: :atomic,
      return_errors?: true
    )
    |> forgotten()
  end

  defp forget_plans(_run, _import_or_picked, _started, _context), do: :ok

  defp forgotten(%Ash.BulkResult{status: :success}), do: :ok
  defp forgotten(%Ash.BulkResult{errors: errors}), do: {:error, Ash.Error.to_error_class(errors)}

  defp walk_kinds(state) do
    Enum.reduce_while(kinds(state), {:ok, Report.new()}, fn kind, {:ok, report} ->
      walk = %{
        kind: kind,
        cursor: nil,
        cursors: %{},
        source_ids: %{},
        settled: %{},
        left_out: %{},
        waiting: %{},
        pages: 0,
        listed: 0
      }

      state |> kind_walked(walk, report) |> walked_kind(state, report)
    end)
  end

  defp kind_walked(%{picked: nil} = state, walk, report), do: walk_kind(state, walk, report)

  defp kind_walked(state, walk, report) do
    with {:error, reason} <- walk_kind(state, walk, report),
         do: {:error, {walk.kind, reason}}
  rescue
    error -> {:error, {walk.kind, error}}
  catch
    :exit, reason -> {:error, {walk.kind, {:exit, reason}}}
  end

  defp kinds(%{picked: nil, source: source}), do: source.kinds()

  defp kinds(%{picked: picked, source: source}),
    do: Enum.filter(source.kinds(), &is_map_key(picked, &1))

  defp walked_kind({:ok, report}, _state, _before), do: {:cont, {:ok, report}}
  defp walked_kind({:error, reason}, %{picked: nil}, _before), do: {:halt, {:error, reason}}

  defp walked_kind({:error, {kind, reason}}, state, report),
    do: {:cont, {:ok, failed(state, kind, reason, report)}}

  defp failed(state, kind, reason, report) do
    state.run.source_host
    |> MishkaCmsMigration.items_by_sources!(kind, Map.fetch!(state.picked, kind),
      scope: state.scope
    )
    |> Enum.reduce(report, fn item, report ->
      Report.add(report, Writer.call(state, picked_item(item), {:failed, Report.reason(reason)}))
    end)
  end

  defp picked_item(%MigrationItem{} = item),
    do: %Item{
      kind: item.source_kind,
      source_id: item.source_id,
      title: item.title,
      parent: item.source_parent,
      attrs: %{"slug" => item.source_slug}
    }

  defp walk_kind(_state, %{pages: @max_pages, kind: kind}, _report),
    do: {:error, {:too_many_pages, kind}}

  defp walk_kind(state, walk, report) do
    with {:ok, rows, next} <- read_page(state, walk),
         {report, walk} = page(state, walk, rows, report),
         :ok <- progress(state, walk.kind, rows, report.counts) do
      walk_on(
        state,
        %{walk | pages: walk.pages + 1, listed: walk.listed + length(rows)},
        next,
        report
      )
    end
  end

  defp walk_on(state, walk, nil, report) do
    :telemetry.execute(
      [:mishka_cms_migration, :kind, :listed],
      %{count: walk.listed, pages: walk.pages},
      Map.put(state.telemetry, :kind, walk.kind)
    )

    {:ok, unheld(state, walk, report)}
  end

  defp walk_on(_state, %{cursors: cursors, kind: kind}, next, _report)
       when is_map_key(cursors, next),
       do: {:error, {:cursor_repeated, kind}}

  defp walk_on(state, walk, next, report),
    do:
      walk_kind(state, %{walk | cursor: next, cursors: Map.put(walk.cursors, next, true)}, report)

  defp read_page(%{picked: nil} = state, walk),
    do: state.source.list(state.conn, walk.kind, walk.cursor)

  defp read_page(state, walk),
    do: state.source |> function_exported?(:rows, 3) |> read_page(state, walk)

  defp read_page(true, state, walk) do
    with {:ok, rows} <-
           state.source.rows(state.conn, walk.kind, Map.fetch!(state.picked, walk.kind)),
         do: {:ok, rows, nil}
  end

  defp read_page(false, state, walk), do: state.source.list(state.conn, walk.kind, walk.cursor)

  defp page(state, walk, rows, report) do
    {built, source_ids} =
      rows
      |> Enum.map(&build(state, walk.kind, &1))
      |> Enum.filter(&picked?(state, walk.kind, &1))
      |> Enum.map_reduce(walk.source_ids, &once/2)

    items = for {:ok, item} <- built, do: item
    {waits, walk} = needs(state, walk, items)
    plans = state |> Decision.call(walk.kind, items) |> Map.merge(waits, &waited/3)

    Enum.reduce(built, {report, %{walk | source_ids: source_ids}}, &place(state, plans, &1, &2))
  end

  defp picked?(%{picked: nil}, _kind, _built), do: true
  defp picked?(state, kind, built), do: elem(built, 1).source_id in state.picked[kind]

  defp needs(%{picked: nil} = state, walk, items),
    do: {Needs.call(state, walk.kind, items).waits, walk}

  defp needs(state, walk, items) do
    %{waits: waits, parents: parents} = Needs.call(state, walk.kind, items)

    {waits,
     %{
       walk
       | settled: Map.merge(walk.settled, Map.new(parents, fn {id, _left_out} -> {id, true} end)),
         left_out: Map.merge(walk.left_out, for({id, true} <- parents, into: %{}, do: {id, true}))
     }}
  end

  defp waited(_source_id, plan, reason) when elem(plan, 0) in [:created, :updated, :restored],
    do: {:skipped, reason}

  defp waited(_source_id, plan, _reason), do: plan

  defp place(state, plans, {:ok, item}, placed),
    do: hold(state, {item, Map.fetch!(plans, item.source_id)}, placed)

  defp place(state, _plans, built, {report, walk}),
    do: {Report.add(report, settle(state, built)), walk}

  defp hold(_state, {%Item{parent: parent}, _plan} = held, {report, walk})
       when is_binary(parent) and not is_map_key(walk.settled, parent),
       do: {report, %{walk | waiting: Map.update(walk.waiting, parent, [held], &(&1 ++ [held]))}}

  defp hold(state, {%Item{parent: parent} = item, plan}, {_report, walk} = placed)
       when is_map_key(walk.left_out, parent),
       do: settle_tree(state, {item, under_left_out(plan)}, placed)

  defp hold(state, held, placed), do: settle_tree(state, held, placed)

  defp under_left_out({:skipped, "left_out_by_admin"} = plan), do: plan
  defp under_left_out({:mapped, _target, _record} = plan), do: plan
  defp under_left_out({:skipped, "mapped_missing"} = plan), do: plan
  defp under_left_out({:undecided, conflict} = plan) when conflict in @record_conflicts, do: plan
  defp under_left_out(_plan), do: {:skipped, "parent_left_out"}

  defp settle_tree(state, {item, plan}, {report, walk}) do
    report = Report.add(report, settled(state, item, plan))
    {children, waiting} = Map.pop(walk.waiting, item.source_id, [])

    walk = %{
      walk
      | settled: Map.put(walk.settled, item.source_id, true),
        left_out: left_out(walk.left_out, item, plan),
        waiting: waiting
    }

    Enum.reduce(children, {report, walk}, &hold(state, &1, &2))
  end

  defp left_out(left_out, item, {:skipped, reason})
       when reason in ["left_out_by_admin", "parent_left_out"],
       do: Map.put(left_out, item.source_id, true)

  defp left_out(left_out, _item, _plan), do: left_out

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

  defp settle(state, {:duplicate, item}), do: settled(state, item, :duplicate)

  defp settle(state, {:failed, item, reason}),
    do: settled(state, item, {:failed, Report.reason(reason)})

  defp settled(state, item, plan) do
    started = System.monotonic_time()
    entry = Writer.call(state, item, plan)

    :telemetry.execute(
      [:mishka_cms_migration, :item, :settled],
      %{duration: System.monotonic_time() - started},
      Map.merge(state.telemetry, Map.take(entry, [:kind, :source_id, :outcome, :reason]))
    )

    entry
  end

  defp progress(%{picked: picked}, _kind, _rows, _counts) when is_map(picked), do: :ok
  defp progress(_state, _kind, [], _counts), do: :ok

  defp progress(state, kind, _rows, counts) do
    state.run
    |> MishkaCmsMigration.record_progress(%{kind: kind, counts: counts}, scope: state.scope)
    |> saved()
    |> progressed()
  end

  defp progressed({:ok, _run}), do: :ok
  defp progressed(error), do: error

  defp telemetry(run, mode),
    do: %{
      run_id: run.id,
      site_id: run.site_id,
      source: run.source,
      source_host: run.source_host,
      mode: mode
    }

  defp target_context(run, mode, scope, options),
    do: %{
      mode: mode,
      actor: scope.actor,
      scope: scope,
      site_id: run.site_id,
      run_id: run.id,
      source: run.source,
      source_host: run.source_host,
      options: options,
      parent_id: nil,
      record: nil,
      prepared: nil,
      languages: run.extra["languages"],
      decisions: %{}
    }

  defp source_context(state),
    do: %{
      site_id: state.run.site_id,
      run_id: state.run.id,
      source_host: state.run.source_host,
      options: state.options,
      conn: state.conn
    }
end
