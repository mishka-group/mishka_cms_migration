# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Walker do
  @moduledoc """
  How a dry run or an import reads a run's source: it connects once with the run's connection and
  its opened secret (`MishkaCmsMigration.Secret`), walks the kinds in the order `kinds/0` gives them,
  and pages through each with `list/3` until the source answers no cursor. Each row is normalized
  into an item (`MishkaCmsMigration.Item`), decided (`MishkaCmsMigration.Decision`) and, in an
  import, written (`MishkaCmsMigration.Writer`). After each page the progress is broadcast
  (`MishkaCmsMigration.Progress`).

  A source id met again in the same kind, on the same page or a later one, is skipped as
  `"duplicate_in_source"` and not recorded: the first row with that id is the one written and
  remembered. A row the source cannot normalize fails alone, and the report says why, also when
  `normalize/3` raises or exits: a plugin's mistake costs the row, not the run. An error from
  `connect/2` or `list/3` ends the walk with it; one that raises ends the job
  (`MishkaCmsMigration.Pipeline`).

  A source whose cursors never end cannot hold the site's one migration job for good: the walk ends
  with `{:cursor_repeated, kind}` when `list/3` answers a cursor it already answered for that kind,
  and with `{:too_many_pages, kind}` after 10,000 pages of one kind.
  """

  alias MishkaCmsMigration.{Decision, Item, Progress, Report, Secret, Source, Writer}
  alias MishkaCmsMigration.MigrationRun.Options

  @max_pages 10_000

  @doc """
  Walks `run`'s source in `mode` as `actor` and answers the report, or why the source could not be
  walked.
  """
  @spec walk(map(), :dry_run | :import, map()) :: {:ok, Report.t()} | {:error, term()}
  def walk(run, mode, actor) do
    with {:ok, options} <- Options.builder(run.options),
         {:ok, source} <- Source.fetch(run.source),
         {:ok, secret} <- Secret.open(run.connection_secret),
         {:ok, conn} <- source.connect(run.connection, secret) do
      walk_kinds(%{
        run: run,
        mode: mode,
        actor: actor,
        source: source,
        conn: conn,
        options: options
      })
    end
  end

  defp walk_kinds(state) do
    Enum.reduce_while(state.source.kinds(), {:ok, Report.new()}, fn kind, {:ok, report} ->
      walk = %{kind: kind, cursor: nil, cursors: %{}, ids: %{}, pages: 0}

      case walk_kind(state, walk, report) do
        {:ok, report} -> {:cont, {:ok, report}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp walk_kind(_state, %{pages: @max_pages, kind: kind}, _report),
    do: {:error, {:too_many_pages, kind}}

  defp walk_kind(state, walk, report) do
    case state.source.list(state.conn, walk.kind, walk.cursor) do
      {:ok, rows, next} ->
        {report, ids} = page(state, walk, rows, report)
        Progress.broadcast(state.run, state.mode, walk.kind, report.counts)
        walk_on(state, %{walk | ids: ids, pages: walk.pages + 1}, next, report)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp walk_on(_state, _walk, nil, report), do: {:ok, report}

  defp walk_on(state, walk, next, report) do
    case Map.has_key?(walk.cursors, next) do
      true ->
        {:error, {:cursor_repeated, walk.kind}}

      false ->
        walk_kind(
          state,
          %{walk | cursor: next, cursors: Map.put(walk.cursors, next, true)},
          report
        )
    end
  end

  defp page(state, walk, rows, report) do
    {built, ids} =
      rows
      |> Enum.map(&build(state, walk.kind, &1))
      |> Enum.map_reduce(walk.ids, &once/2)

    page = Decision.page(state.run, walk.kind, for({:ok, item} <- built, do: item))

    {Enum.reduce(built, report, &Report.add(&2, handle(state, page, &1))), ids}
  end

  defp once({:ok, item} = row, ids) do
    case Map.has_key?(ids, item.source_id) do
      true -> {{:duplicate, item}, ids}
      false -> {row, Map.put(ids, item.source_id, true)}
    end
  end

  defp once(row, ids), do: {row, ids}

  defp build(state, kind, row) do
    case state.source.normalize(row, kind, source_context(state)) do
      {:ok, attrs} -> attrs |> Map.put(:kind, kind) |> Item.build() |> built(attrs)
      {:error, reason} -> {:error, nil, reason}
    end
  rescue
    error -> {:error, nil, error}
  catch
    :exit, reason -> {:error, nil, {:exit, reason}}
  end

  defp built({:ok, item}, _attrs), do: {:ok, item}
  defp built({:error, errors}, attrs), do: {:error, source_id(attrs), errors}

  defp source_id(attrs) do
    case Map.get(attrs, :source_id, Map.get(attrs, "source_id")) do
      id when is_binary(id) or is_integer(id) -> to_string(id)
      _none -> nil
    end
  end

  defp handle(state, page, {:error, source_id, reason}),
    do: Writer.fail(state, page.kind, source_id, Report.reason(reason))

  defp handle(_state, page, {:duplicate, item}),
    do: Report.entry(page.kind, item.source_id, item.title, :skipped, "duplicate_in_source")

  defp handle(%{mode: :dry_run}, page, {:ok, item}) do
    case Decision.plan(page, item) do
      {:skipped, reason} -> Report.entry(page.kind, item.source_id, item.title, :skipped, reason)
      {outcome, _record} -> Report.entry(page.kind, item.source_id, item.title, outcome, nil)
    end
  end

  defp handle(%{mode: :import} = state, page, {:ok, item}) do
    case Decision.plan(page, item) do
      {:skipped, reason} -> Writer.leave(state, page.kind, item, :skipped, reason)
      {outcome, record} -> Writer.write(state, page, item, outcome, record)
    end
  end

  defp source_context(state),
    do: %{
      site_id: state.run.site_id,
      run_id: state.run.id,
      source_host: state.run.source_host,
      options: state.options
    }
end
