# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Workers.Helpers.Writer do
  @moduledoc """
  What happens to one item once it is decided (`MishkaCmsMigration.Workers.Helpers.Decision`), and
  its entry in the report (`call/3`, answering `MishkaCmsMigration.Report.entry/5`).

  In an import an item to create or update has its content converted (`migration:content:convert`),
  is offered to the plugins (`migration:item:before_import`), is handed to its target's `prepare/3`
  (`MishkaCmsMigration.Target`), which may fetch what the write needs from the source or skip it,
  is written through its target's create or update action (`MishkaCmsMigration.Target`'s
  `writes_to/2` names the resource and the actions) as the admin who pressed Import (a create
  that is a generic action, such as the core Media's `:upload`, is run as one, and an update that is
  an upserting create, such as the core Setting's `:set`, is run as that create), and is recorded
  (`MishkaCmsMigration.MigrationItem`'s `:record`) with the CMS record it was written to, in one
  transaction (`Ash.transact/3`): either the CMS record and its item are both there, or neither is,
  so a retry never meets a CMS record no item remembers. An item skipped or failed is recorded with
  its reason (`:record_outcome`), which keeps what the last write recorded; when even that cannot be
  recorded, the item's entry says it failed, with why. A dry run writes nothing in the CMS: it
  reports the plan and records it on each item (`:record_plan`, its outcome and reason as the
  item's `plan` and `plan_reason`), which leaves alone what an import recorded. An item it would
  create or update is first handed to its target's `waiting/2`, the dry run's stand-in for
  `prepare/3`: one the import's `prepare/3` would leave waiting for a decision, or skip, is planned
  so.

  An item written otherwise than the source has it has its entry and its record say so: its
  target's note (`MishkaCmsMigration.Target`'s `note/2`), then the pieces of its content no plugin
  converted, kept as escaped text, joined by `"; "`, as in
  `"draft_from_pending; unconverted: acme/callout, gallery"`. A dry run asks no plugin, so it names
  every piece the source left to convert.

  An item connected to a record the CMS already held (`MishkaCmsMigration.Target`'s `existing/2`),
  or mapped to one by an admin, is not written: in an import it is recorded against that record,
  with no `target_updated_at`, as skipped, `"connected"`; a dry run reports it so. An item the
  target's `prepare/3` finds to be a record the CMS holds (`{:connected, record, reason}`) is
  recorded the same way, as skipped with `reason`. What the target's `recorded/2` answers is
  recorded on the item of a record written. An item whose
  conflict waits for an admin's decision is not written either: it is recorded as `:undecided`,
  with the conflict as its reason, and the next run asks again.

  The target is handed the item's decisions (`MishkaCmsMigration.Target`'s context, `decisions`),
  so what an admin decided on a conflict holds for its note and its write, and what its
  `existing/2` found for the item's write in its read of the page (`prepared`), so its note and its
  write need not read it again.

  An item with a parent (`MishkaCmsMigration.Source.Item`'s `parent`), which the walk settles
  first, is written under the CMS record its parent's item recorded: the target is handed that
  record's id as its context's `parent_id`. When the parent has none — it failed, was never written,
  or the source never listed it — the item is skipped as `"parent_missing"`, so it is not written
  out of its place, and the run that writes the parent writes it too.

  A plugin, a target or the CMS action that raises or exits while an item is converted, offered or
  written fails that item alone, with the exception's message as its reason. One the CMS's policies
  refuse the admin fails as `"forbidden: <kind>"`, "You may not change <kinds> on this site".
  """

  alias Ash.Resource.Info
  alias MishkaCmsMigration.{Events, MigrationItem, Report}
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Targets.Helpers.LanguageUrls

  @doc """
  Settles `item` by `plan` and answers its entry in the report:

    * `{:created, target, nil, decisions}` or `{:updated, target, record, decisions}` — written
      in an import, reported and recorded as the item's plan in a dry run, with its target's note
      and the pieces of its content left unconverted as its reason, or as what its target's
      `waiting/2` answers instead; `{:created, target, nil, decisions, prepared}` is settled the
      same way, with `prepared`, what the target's `existing/2` found for the write, as its
      context's `prepared`;
    * `{:connected, target, record}` or `{:mapped, target, record}` — recorded against `record`
      in an import, never written, and reported as skipped, `"connected"`;
    * `{:skipped, reason}`, `{:failed, reason}` or `{:undecided, conflict}` — recorded with its
      reason, as what an import did or as a dry run's plan; an item whose row could not be read
      has only its kind and, when the row named one, its source id, and is recorded only with one;
    * `:duplicate` — the source listed its id before: reported, never recorded.
  """
  @spec call(map(), Item.t(), term()) :: Report.entry()
  def call(_state, %Item{} = item, :duplicate),
    do: Report.entry(item.kind, item.source_id, item.title, :skipped, "duplicate_in_source")

  def call(state, %Item{} = item, {outcome, reason})
      when outcome in [:skipped, :failed, :undecided],
      do: entry(state, item, outcome, reason)

  def call(state, %Item{} = item, {:mapped, target, record}),
    do: call(state, item, {:connected, target, record})

  def call(%{mode: :dry_run} = state, %Item{} = item, {:connected, _target, _record}),
    do: entry(state, item, :skipped, "connected")

  def call(%{mode: :import} = state, %Item{} = item, {:connected, _target, record}) do
    state
    |> recorded(item, %{record | updated_at: nil}, {:skipped, "connected"}, %{})
    |> stored()
    |> entered(item, :skipped, "connected")
  end

  def call(state, %Item{} = item, {outcome, target, record, decisions}),
    do: call(state, item, {outcome, target, record, decisions, nil})

  def call(
        %{mode: :dry_run} = state,
        %Item{} = item,
        {outcome, target, record, decisions, prepared}
      ) do
    context = item_context(state, item, record, decisions, prepared)
    item |> target.waiting(context) |> planned(state, item, {outcome, target, context})
  end

  def call(
        %{mode: :import} = state,
        %Item{} = item,
        {outcome, target, record, decisions, prepared}
      ) do
    context = item_context(state, item, record, decisions, prepared)
    state |> written(item, {outcome, target, record}, context) |> settled(state, item, outcome)
  end

  defp planned(nil, state, item, {outcome, target, context}),
    do: entry(state, item, outcome, note(target, item, context, to_convert(item)))

  defp planned({waiting, reason}, state, item, _write) when waiting in [:skipped, :undecided],
    do: entry(state, item, waiting, reason)

  defp settled({:ok, _record, note}, _state, item, outcome),
    do: Report.entry(item.kind, item.source_id, item.title, outcome, note)

  defp settled({:connected, record, reason}, state, item, _outcome),
    do:
      state
      |> recorded(item, %{record | updated_at: nil}, {:skipped, reason}, %{})
      |> stored()
      |> entered(item, :skipped, reason)

  defp settled({:skipped, reason}, state, item, _outcome),
    do: entry(state, item, :skipped, reason)

  defp settled({:undecided, conflict}, state, item, _outcome),
    do: entry(state, item, :undecided, conflict)

  defp settled({:error, %Ash.Error.Forbidden{}}, state, item, _outcome),
    do: entry(state, item, :failed, "forbidden: " <> item.kind)

  defp settled({:error, error}, state, item, _outcome),
    do: entry(state, item, :failed, Report.reason(error))

  defp entry(state, item, outcome, reason),
    do: state |> noted(item, outcome, reason) |> entered(item, outcome, reason)

  defp entered(:ok, item, outcome, reason),
    do: Report.entry(item.kind, item.source_id, item.title, outcome, reason)

  defp entered({:error, error}, item, _outcome, _reason),
    do: Report.entry(item.kind, item.source_id, item.title, :failed, Report.reason(error))

  defp written(state, source_item, {outcome, target, _record} = plan, context) do
    with {:ok, context} <- parented(state, source_item, context),
         {:ok, item, kept} <- convert(state, source_item),
         {:ok, item} <- Events.before_import(item, outcome, state.run, state.actor),
         note = note(target, item, context, kept),
         {:ok, written} <-
           target.prepare(item, context, &transacted(state, {source_item, item}, plan, &1, note)) do
      {:ok, written, note}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp transacted(state, items, {_outcome, target, _record} = plan, context, note),
    do:
      Ash.transact(target.resources() ++ [MigrationItem], fn ->
        store(state, items, plan, context, note)
      end)

  defp store(state, {source_item, item}, {outcome, target, record}, context, note) do
    with {:ok, written} <- write(target, item, record, context),
         {:ok, _item} <-
           recorded(state, source_item, written, {outcome, note}, target.recorded(item, context)) do
      {:ok, written}
    end
  end

  defp stored({:ok, _item}), do: :ok
  defp stored({:error, error}), do: {:error, error}

  defp parented(_state, %Item{parent: nil}, context), do: {:ok, context}

  defp parented(state, %Item{kind: kind, parent: parent}, context) do
    state.run.source_host
    |> MishkaCmsMigration.items_by_sources(kind, [parent], scope: state.scope)
    |> parent_record(context)
  end

  defp parent_record({:ok, [%MigrationItem{target_id: id}]}, context) when is_binary(id),
    do: {:ok, %{context | parent_id: id}}

  defp parent_record({:ok, _items}, _context), do: {:skipped, "parent_missing"}
  defp parent_record({:error, error}, _context), do: {:error, error}

  defp write(target, item, record, context) do
    {resource, actions} = target.writes_to(item, context)
    write(resource, actions, target.attrs(item, context), record, context)
  end

  defp write(resource, actions, attrs, nil, context),
    do: resource |> Info.action(actions.create) |> create(resource, attrs, context)

  defp write(resource, actions, attrs, record, context),
    do: resource |> Info.action(actions.update) |> update(record, attrs, context)

  defp update(%{type: :create} = upsert, %resource{}, attrs, context),
    do: create(upsert, resource, attrs, context)

  defp update(%{name: name}, record, attrs, context),
    do: record |> Ash.Changeset.for_update(name, attrs, as(context)) |> Ash.update()

  defp create(%{type: :action, name: name}, resource, attrs, context),
    do: resource |> Ash.ActionInput.for_action(name, attrs, as(context)) |> Ash.run_action()

  defp create(%{name: name}, resource, attrs, context),
    do: resource |> Ash.Changeset.for_create(name, attrs, as(context)) |> Ash.create()

  defp as(context), do: [actor: context.actor, tenant: context.site_id]

  defp recorded(
         state,
         item,
         %resource{id: id, updated_at: updated_at},
         {outcome, note},
         added
       ) do
    MishkaCmsMigration.record_item(
      Map.merge(
        %{
          source_host: state.run.source_host,
          source_kind: item.kind,
          source_id: item.source_id,
          run_id: state.run.id,
          title: item.title,
          source_slug: source_slug(item),
          source_parent: item.parent,
          source_modified_at: item.modified_at,
          content_hash: LanguageUrls.hash(item, state.run.site_id),
          target_resource: inspect(resource),
          target_id: id,
          target_updated_at: updated_at,
          outcome: outcome,
          reason: note,
          extra: item.extra
        },
        added
      ),
      scope: state.scope
    )
  end

  defp noted(%{mode: :import} = state, %Item{source_id: source_id} = item, outcome, reason)
       when is_binary(source_id) do
    with {:ok, _item} <-
           MishkaCmsMigration.record_item_outcome(
             %{
               source_host: state.run.source_host,
               source_kind: item.kind,
               source_id: source_id,
               run_id: state.run.id,
               title: item.title,
               source_slug: source_slug(item),
               source_parent: item.parent,
               outcome: outcome,
               reason: reason
             },
             scope: state.scope
           ),
         do: :ok
  end

  defp noted(%{mode: :dry_run} = state, %Item{source_id: source_id} = item, plan, reason)
       when is_binary(source_id) do
    with {:ok, _item} <-
           MishkaCmsMigration.record_item_plan(
             %{
               source_host: state.run.source_host,
               source_kind: item.kind,
               source_id: source_id,
               title: item.title,
               source_slug: source_slug(item),
               source_parent: item.parent,
               plan: plan,
               plan_reason: reason
             },
             scope: state.scope
           ),
         do: :ok
  end

  defp noted(_state, _item, _outcome, _reason), do: :ok

  defp source_slug(%Item{attrs: %{"slug" => slug}}) when is_binary(slug) and slug != "", do: slug
  defp source_slug(_item), do: nil

  defp convert(state, %Item{content: [_ | _] = content} = item),
    do: state |> convert_pieces(item, content, {[], []}) |> converted(item)

  defp convert(_state, item), do: {:ok, item, []}

  defp converted({:ok, pieces, kept}, item), do: {:ok, %{item | content: pieces}, kept}
  defp converted(:cannot_run, _item), do: {:skipped, "plugins_cannot_run"}
  defp converted(:failed, _item), do: {:skipped, "plugins_failed"}

  defp convert_pieces(_state, _item, [], {done, kept}),
    do: {:ok, Enum.reverse(done), Enum.reverse(kept)}

  defp convert_pieces(state, item, [%{html: html} = piece | rest], {done, kept})
       when is_binary(html),
       do: convert_pieces(state, item, rest, {[piece | done], kept})

  defp convert_pieces(state, item, [piece | rest], pieces) do
    with {:ok, pieces} <-
           piece |> Events.convert(item, state.run, state.actor) |> with_html(piece, pieces) do
      convert_pieces(state, item, rest, pieces)
    end
  end

  defp with_html({:ok, html}, piece, {done, kept}),
    do: {:ok, {[%{piece | html: html} | done], kept}}

  defp with_html(:unconverted, piece, {done, kept}),
    do: {:ok, {[%{piece | html: escaped(piece.raw)} | done], [piece.name | kept]}}

  defp with_html(failed, _piece, _pieces), do: failed

  defp to_convert(%Item{content: content}),
    do: for(%{html: nil, name: name} <- content || [], do: name)

  defp note(target, item, context, unconverted),
    do:
      [target.note(item, context), unconverted(unconverted)]
      |> Enum.reject(&is_nil/1)
      |> noted()

  defp noted([]), do: nil
  defp noted(notes), do: notes |> Enum.join("; ") |> Report.reason()

  defp unconverted(names), do: names |> Enum.reject(&is_nil/1) |> Enum.uniq() |> names()

  defp names([]), do: nil
  defp names(names), do: "unconverted: " <> Enum.join(names, ", ")

  defp escaped(nil), do: ""
  defp escaped(raw), do: raw |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp item_context(state, item, record, decisions, prepared),
    do: %{
      state.context
      | record: record,
        prepared: prepared,
        decisions: %{item.source_id => decisions}
    }
end
