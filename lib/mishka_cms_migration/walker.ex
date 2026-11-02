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

  A row the source cannot normalize fails alone, and the report says why. An error from
  `connect/2` or `list/3` ends the walk with it.
  """

  alias MishkaCmsMigration.{Decision, Item, Options, Progress, Report, Secret, Source, Writer}

  @doc """
  Walks `run`'s source in `mode` as `actor` and answers the report, or why the source could not be
  walked.
  """
  @spec walk(map(), :dry_run | :import, map()) :: {:ok, Report.t()} | {:error, term()}
  def walk(run, mode, actor) do
    with {:ok, options} <- Options.builder(run.options),
         {:ok, source} <- Source.fetch(run.source),
         {:ok, conn} <- source.connect(run.connection, Secret.open(run.connection_secret)) do
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
      case walk_kind(state, kind, nil, report) do
        {:ok, report} -> {:cont, {:ok, report}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp walk_kind(state, kind, cursor, report) do
    case state.source.list(state.conn, kind, cursor) do
      {:ok, rows, next} ->
        report = page(state, kind, rows, report)
        Progress.broadcast(state.run, state.mode, kind, report.counts)
        walk_on(state, kind, next, report)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp walk_on(_state, _kind, nil, report), do: {:ok, report}
  defp walk_on(state, kind, next, report), do: walk_kind(state, kind, next, report)

  defp page(state, kind, rows, report) do
    built = Enum.map(rows, &build(state, kind, &1))
    page = Decision.page(state.run, kind, for({:ok, item} <- built, do: item))

    Enum.reduce(built, report, &Report.add(&2, handle(state, page, &1)))
  end

  defp build(state, kind, row) do
    case state.source.normalize(row, kind, source_context(state)) do
      {:ok, attrs} -> attrs |> Map.put(:kind, kind) |> Item.build() |> built(attrs)
      {:error, reason} -> {:error, nil, reason}
    end
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

  defp handle(%{mode: :dry_run}, page, {:ok, item}) do
    case Decision.plan(page, item) do
      {:skip, reason} -> Report.entry(page.kind, item.source_id, item.title, :skip, reason)
      {action, _record} -> Report.entry(page.kind, item.source_id, item.title, action, nil)
    end
  end

  defp handle(%{mode: :import} = state, page, {:ok, item}) do
    case Decision.plan(page, item) do
      {:skip, reason} -> Writer.leave(state, page.kind, item, :skipped, reason)
      {action, record} -> Writer.write(state, page, item, action, record)
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
