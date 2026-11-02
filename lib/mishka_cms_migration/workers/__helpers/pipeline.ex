# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Workers.Helpers.Pipeline do
  @moduledoc """
  What a `migration` job does with its run (`MishkaCmsMigration.Workers.DryRunWorker`,
  `MishkaCmsMigration.Workers.ImportWorker`): find the run waiting for it and who asked, walk the
  run's source, and save what came of it on the run.

  ## The walk

  The job connects once with the run's connection and its opened secret
  (`MishkaCmsMigration.MigrationRun.open_secret/1`), walks the kinds in the order the source's
  `kinds/0` gives them, and pages through each with `list/3` until the source answers no cursor.
  Each row is normalized into an item (`MishkaCmsMigration.Source.Item`), decided
  (`MishkaCmsMigration.Workers.Helpers.Decision`) and, in an import, written
  (`MishkaCmsMigration.Workers.Helpers.Writer`). After each page with rows the job saves how far it is on the
  run (`MishkaCmsMigration.MigrationRun`'s `:record_progress`, `progress`: the kind and the counts
  so far), and the run's own Ash notifier broadcasts it on `"migration_run:<site_id>:updated"`. A
  run that no longer takes its progress — an admin cancelled it — stops the walk after that page.

  A source id met again in the same kind, on the same page or a later one, is skipped as
  `"duplicate_in_source"` and not recorded: the first row with that id is the one written and
  remembered. A row the source cannot normalize fails alone, and the report says why, also when
  `normalize/3` raises or exits: a plugin's mistake costs the row, not the run.

  ## Dry run and import

  A dry run decides and reports; it writes nothing and fires no event. An import writes each item
  as the admin who pressed Import, and once every kind is walked its report is saved on the run and
  handed to `migration:import:finished` (`MishkaCmsMigration.Events`).

  ## When the walk fails

  An error from `connect/2` or `list/3`, a raise outside a single row, a secret that can no longer
  be opened, or a source whose cursors never end — `{:cursor_repeated, kind}` when `list/3` answers
  a cursor it already answered for that kind, `{:too_many_pages, kind}` after 10,000 pages of one
  kind — fails the job. Oban tries it again, and the last attempt fails the run with the reason
  (`MishkaCmsMigration.MigrationRun`'s `:fail`), which also clears its secret. A job whose run is
  gone, or is not waiting for it (it was cancelled meanwhile), is cancelled, and so is one whose
  run refuses its report.

  A last attempt that never returns — Oban stops it at its `timeout/1`, or it crashes past every
  rescue — fails its run too: `attach/0` listens to Oban's own `[:oban, :job, :exception]`
  telemetry, and a migration job Oban discards fails its run with the reason and clears its secret.
  Only a job lost with its node, which Oban's lifeline puts back without that event, leaves its run
  where it was, for an admin to cancel.
  """

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsMigration.{Events, MigrationRun, Report, Source}
  alias MishkaCmsMigration.MigrationRun.Options
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Workers.Helpers.{Decision, Writer}

  @running %{dry_run: :dry_running, import: :importing}
  @max_pages 10_000
  @handler "mishka-cms-migration-discarded-jobs"
  @workers ["MishkaCmsMigration.Workers.DryRunWorker", "MishkaCmsMigration.Workers.ImportWorker"]

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
  large site goes on where it stopped. A job stopped on its last attempt fails its run (`attach/0`).
  """
  @spec timeout(Oban.Job.t()) :: pos_integer()
  def timeout(%Oban.Job{}), do: :timer.hours(1)

  @doc """
  Attaches the handler that fails the run of a migration job Oban discards: one whose last attempt
  timed out or crashed. `MishkaCmsMigration.Application` attaches it at boot; attaching again
  replaces it.
  """
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.detach(@handler)
    :telemetry.attach(@handler, [:oban, :job, :exception], &__MODULE__.discarded/4, nil)
  end

  @doc false
  def discarded(
        _event,
        _measurements,
        %{job: %{worker: worker, args: args}, state: :discard} = meta,
        _config
      )
      when worker in @workers do
    case running(args, mode(worker)) do
      {:ok, run} ->
        MishkaCmsMigration.fail_run(run, Report.reason(meta[:reason]), authorize?: false)

      {:error, _gone} ->
        :ok
    end

    :ok
  end

  def discarded(_event, _measurements, _meta, _config), do: :ok

  defp mode("MishkaCmsMigration.Workers.DryRunWorker"), do: :dry_run
  defp mode("MishkaCmsMigration.Workers.ImportWorker"), do: :import

  @doc "Runs `job` of a run in `mode` and answers as an `Oban.Worker` does."
  @spec call(Oban.Job.t(), mode()) :: :ok | {:error, term()} | {:cancel, term()}
  def call(%Oban.Job{args: args} = job, mode) do
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
      {:ok, report, extra, actor} -> finish(run, mode, Report.done(report), extra, actor)
      {:error, reason} -> retry_or_fail(run, reason, job.attempt >= job.max_attempts)
    end
  end

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

  defp actor(%{"actor_id" => id}) when is_binary(id) do
    case Ash.get(MishkaCmsCore.Accounts.User, id, authorize?: false) do
      {:ok, user} -> {:ok, AccessPermissions.with_permissions(user)}
      {:error, _error} -> {:error, :actor_not_found}
    end
  end

  defp actor(_args), do: {:error, :actor_not_found}

  defp finish(run, :dry_run, report, extra, _actor) do
    case MishkaCmsMigration.finish_dry_run(run, report, extra, authorize?: false) do
      {:ok, _run} -> :ok
      {:error, error} -> {:cancel, error}
    end
  end

  defp finish(run, :import, report, extra, actor) do
    case MishkaCmsMigration.finish_import(run, report, extra, authorize?: false) do
      {:ok, run} -> Events.finished(report, run, actor)
      {:error, error} -> {:cancel, error}
    end
  end

  defp retry_or_fail(run, reason, true) do
    MishkaCmsMigration.fail_run(run, Report.reason(reason), authorize?: false)
    {:cancel, reason}
  end

  defp retry_or_fail(_run, reason, false), do: {:error, reason}

  defp walk(run, mode, actor) do
    with {:ok, options} <- Options.builder(run.options),
         {:ok, source} <- Source.fetch(run.source),
         {:ok, secret} <- MigrationRun.open_secret(run),
         {:ok, conn} <- source.connect(run.connection, secret),
         {:ok, report} <-
           walk_kinds(%{
             run: run,
             mode: mode,
             actor: actor,
             source: source,
             conn: conn,
             options: options
           }) do
      {:ok, report, extra(source, conn)}
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

        with :ok <- progress(state, walk.kind, rows, report.counts) do
          walk_on(state, %{walk | ids: ids, pages: walk.pages + 1}, next, report)
        end

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

    plans = Decision.call(state, walk.kind, for({:ok, item} <- built, do: item))

    {Enum.reduce(built, report, &Report.add(&2, handle(state, walk.kind, plans, &1))), ids}
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

  defp source_id(%{source_id: id}) when is_binary(id) or is_integer(id), do: to_string(id)
  defp source_id(%{"source_id" => id}) when is_binary(id) or is_integer(id), do: to_string(id)
  defp source_id(_attrs), do: nil

  defp handle(state, _kind, plans, {:ok, item}),
    do: Writer.call(state, item, Map.fetch!(plans, item.source_id))

  defp handle(state, _kind, _plans, {:duplicate, item}), do: Writer.call(state, item, :duplicate)

  defp handle(state, kind, _plans, {:error, source_id, reason}),
    do: Writer.call(state, {kind, source_id}, {:failed, Report.reason(reason)})

  defp extra(source, conn) do
    case function_exported?(source, :extra, 1) do
      true -> source.extra(conn)
      false -> %{}
    end
  end

  defp progress(_state, _kind, [], _counts), do: :ok

  defp progress(state, kind, _rows, counts) do
    case MishkaCmsMigration.record_progress(state.run, %{kind: kind, counts: counts},
           authorize?: false
         ) do
      {:ok, _run} -> :ok
      {:error, _refused} -> {:error, :not_running}
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
