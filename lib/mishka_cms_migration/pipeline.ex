# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Pipeline do
  @moduledoc """
  What the `migration` jobs do with a run (`MishkaCmsMigration.Workers.DryRunWorker`,
  `MishkaCmsMigration.Workers.ImportWorker`): connect to its source, walk every kind page by page,
  decide each item, and, in an import, write it.

  ## Deciding an item

  Each item is looked up among the items earlier runs recorded for the site
  (`MishkaCmsMigration.MigrationItem`), by the run's source host, its kind and its source id:

    * none, or one never written — **create**;
    * its `MishkaCmsMigration.Item.hash/1` is the one recorded — **skip**, `"unchanged"`;
    * the row it was written to is gone — **skip**, `"target_missing"`;
    * the row's `updated_at` is not the one recorded when it was written: an admin changed it in
      the CMS — **skip**, `"edited_in_cms"`;
    * otherwise — **update** that row.

  An item whose kind has no target (`MishkaCmsMigration.Target`) is skipped, `"no_target"`; one the
  source could not normalize fails. See `MishkaCmsMigration.Report` for the report this builds.

  ## Dry run and import

  A dry run decides and reports; it writes nothing and fires no event. An import converts each
  item's content and offers the item to the plugins (`MishkaCmsMigration.Events`), writes it
  through its target as the admin who pressed Import, and records the item: what it wrote, or why it
  skipped or failed. A failed item does not stop the run. Once every kind is walked, the report is
  saved on the run and handed to `migration:import:finished`.

  A source that cannot connect or list fails the job; Oban tries it again, and the last attempt
  fails the run with the reason (`MishkaCmsMigration.MigrationRun`'s `:fail`).

  ## Progress

  After each page the job broadcasts on `topic/1` of the run, over `MishkaCmsCore.PubSub`:

      {:migration_progress,
       %{run_id: "…", site_id: "…", mode: :import, kind: "post",
         counts: %{create: 10, update: 0, skip: 2, fail: 0}}}
  """

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsMigration.{Events, Item, Options, Report, Secret, Source, Target}

  @pubsub MishkaCmsCore.PubSub
  @running %{dry_run: :dry_running, import: :importing}
  @recorded %{create: :created, update: :updated}
  @reported %{skipped: :skip, failed: :fail}

  @typedoc "Whether a job only reports, or writes."
  @type mode :: :dry_run | :import

  @doc """
  The `unique` option both workers share: one job of a site on the `migration` queue, whichever
  run and worker it is, until that job is done.
  """
  @spec unique() :: keyword()
  def unique,
    do: [fields: [:queue, :args], keys: [:site_id], states: :incomplete, period: :infinity]

  @doc "The PubSub topic a run's progress is broadcast on."
  @spec topic(String.t()) :: String.t()
  def topic(run_id), do: "migration:run:#{run_id}"

  @doc "Subscribes the caller to a run's progress (`topic/1`)."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(run_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(run_id))

  @doc """
  Runs `job` of a run in `mode` and answers as an `Oban.Worker` does. A job whose run is gone or is
  not waiting for it is cancelled.
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
    with {:ok, actor} <- actor(job.args),
         {:ok, report} <- walk(run, mode, actor) do
      finish(run, mode, Report.done(report), actor)
    else
      {:error, reason} -> retry_or_fail(run, reason, job.attempt >= job.max_attempts)
    end
  end

  defp actor(%{"actor_id" => id}) when is_binary(id) do
    case Ash.get(MishkaCmsCore.Accounts.User, id, authorize?: false) do
      {:ok, user} -> {:ok, AccessPermissions.with_permissions(user)}
      {:error, _error} -> {:error, :actor_not_found}
    end
  end

  defp actor(_args), do: {:error, :actor_not_found}

  defp finish(run, :dry_run, report, _actor) do
    MishkaCmsMigration.finish_dry_run!(run, report, authorize?: false)
    :ok
  end

  defp finish(run, :import, report, actor) do
    run
    |> MishkaCmsMigration.finish_import!(report, authorize?: false)
    |> then(&Events.finished(report, &1, actor))
  end

  defp retry_or_fail(run, reason, true) do
    MishkaCmsMigration.fail_run!(run, describe(reason), authorize?: false)
    {:cancel, reason}
  end

  defp retry_or_fail(_run, reason, false), do: {:error, reason}

  defp walk(run, mode, actor) do
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
        progress(state, kind, report)
        walk_on(state, kind, next, report)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp walk_on(_state, _kind, nil, report), do: {:ok, report}
  defp walk_on(state, kind, next, report), do: walk_kind(state, kind, next, report)

  defp page(state, kind, rows, report) do
    built = Enum.map(rows, &build(state, kind, &1))
    items = for {:ok, item} <- built, do: item
    known = known(state.run, kind, items)
    target = target(kind)

    page = %{
      kind: kind,
      target: target,
      known: known,
      current: current(target, known, state.run.site_id)
    }

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

  defp known(_run, _kind, []), do: %{}

  defp known(run, kind, items) do
    run.source_host
    |> MishkaCmsMigration.items_by_sources!(kind, Enum.map(items, & &1.source_id),
      tenant: run.site_id,
      authorize?: false
    )
    |> Map.new(&{&1.source_id, &1})
  end

  defp target(kind) do
    case Target.fetch(kind) do
      {:ok, target} -> target
      {:error, _reason} -> nil
    end
  end

  defp current(nil, _known, _site_id), do: %{}

  defp current(target, known, site_id) do
    ids = for {_source_id, %{target_id: id}} <- known, id != nil, do: id
    Target.current(target, ids, site_id)
  end

  defp handle(state, page, {:error, source_id, reason}) do
    reason = describe(reason)
    note(state, page.kind, source_id, :failed, reason)
    entry(page.kind, source_id, nil, :fail, reason)
  end

  defp handle(%{mode: :dry_run}, page, {:ok, item}) do
    case plan(page, item) do
      {:skip, reason} -> entry(page.kind, item.source_id, item.title, :skip, reason)
      {action, _record} -> entry(page.kind, item.source_id, item.title, action, nil)
    end
  end

  defp handle(%{mode: :import} = state, page, {:ok, item}) do
    case plan(page, item) do
      {:skip, reason} -> leave(state, page.kind, item, :skipped, reason)
      {action, record} -> write(state, page, item, action, record)
    end
  end

  defp plan(%{target: nil}, _item), do: {:skip, "no_target"}

  defp plan(page, item) do
    case Map.get(page.known, item.source_id) do
      %{target_id: id} = known when id != nil -> decide(item, known, Map.get(page.current, id))
      _never_written -> {:create, nil}
    end
  end

  defp decide(item, known, record) do
    cond do
      known.content_hash == Item.hash(item) -> {:skip, "unchanged"}
      is_nil(record) -> {:skip, "target_missing"}
      edited?(record, known) -> {:skip, "edited_in_cms"}
      true -> {:update, record}
    end
  end

  defp edited?(record, known) do
    case {Map.get(record, :updated_at), known.target_updated_at} do
      {%DateTime{} = now, %DateTime{} = then} -> DateTime.compare(now, then) != :eq
      _unknown -> true
    end
  end

  defp write(state, page, source_item, action, record) do
    item = convert(state, source_item)

    with {:import, item} <- Events.before_import(item, action, state.run, state.actor),
         {:ok, written} <- Target.write(page.target, item, record, target_context(state)) do
      recorded(state, page, source_item, written, action)
    else
      {:skip, reason} -> leave(state, page.kind, source_item, :skipped, reason)
      {:error, error} -> leave(state, page.kind, source_item, :failed, describe(error))
    end
  end

  defp recorded(state, page, item, written, action) do
    MishkaCmsMigration.record_item!(
      %{
        source_host: state.run.source_host,
        source_kind: page.kind,
        source_id: item.source_id,
        run_id: state.run.id,
        source_modified_at: item.modified_at,
        content_hash: Item.hash(item),
        target_resource: inspect(page.target.resource()),
        target_id: written.id,
        target_updated_at: Map.get(written, :updated_at),
        outcome: Map.fetch!(@recorded, action),
        reason: nil
      },
      tenant: state.run.site_id,
      authorize?: false
    )

    entry(page.kind, item.source_id, item.title, action, nil)
  end

  defp leave(state, kind, item, outcome, reason) do
    note(state, kind, item.source_id, outcome, reason)
    entry(kind, item.source_id, item.title, Map.fetch!(@reported, outcome), reason)
  end

  defp note(%{mode: :import} = state, kind, source_id, outcome, reason)
       when is_binary(source_id) do
    MishkaCmsMigration.record_item_outcome!(
      %{
        source_host: state.run.source_host,
        source_kind: kind,
        source_id: source_id,
        run_id: state.run.id,
        outcome: outcome,
        reason: reason
      },
      tenant: state.run.site_id,
      authorize?: false
    )
  end

  defp note(_state, _kind, _source_id, _outcome, _reason), do: nil

  defp convert(state, %Item{content: [_ | _] = content} = item),
    do: %{item | content: Enum.map(content, &converted(state, item, &1))}

  defp convert(_state, item), do: item

  defp converted(_state, _item, %{html: html} = piece) when is_binary(html), do: piece

  defp converted(state, item, piece),
    do: %{piece | html: Events.convert(piece, item, state.run, state.actor) || escaped(piece.raw)}

  defp escaped(nil), do: ""
  defp escaped(raw), do: raw |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp entry(kind, source_id, title, outcome, reason),
    do: %{kind: kind, source_id: source_id, title: title, outcome: outcome, reason: reason}

  defp progress(state, kind, report) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(state.run.id),
      {:migration_progress,
       %{
         run_id: state.run.id,
         site_id: state.run.site_id,
         mode: state.mode,
         kind: kind,
         counts: report.counts
       }}
    )
  end

  defp source_context(state),
    do: %{
      site_id: state.run.site_id,
      run_id: state.run.id,
      source_host: state.run.source_host,
      options: state.options
    }

  defp target_context(state), do: Map.put(source_context(state), :actor, state.actor)

  defp describe(%{__exception__: true} = error), do: error |> Exception.message() |> short()
  defp describe(reason) when is_binary(reason), do: short(reason)
  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp describe([%{message: _} | _] = errors),
    do: errors |> Enum.map_join("; ", &"#{&1[:field]}: #{&1.message}") |> short()

  defp describe(reason), do: reason |> inspect() |> short()

  defp short(text), do: String.slice(text, 0, 1000)
end
