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
  is written through its target's create or update action as the admin who pressed Import (a create
  that is a generic action, such as the core Media's `:upload`, is run as one), and is recorded
  (`MishkaCmsMigration.MigrationItem`'s `:record`) with the CMS record it was written to, in one
  transaction (`Ash.transact/3`): either the CMS record and its item are both there, or neither is,
  so a retry never meets a CMS record no item remembers. An item skipped or failed is recorded with
  its reason (`:record_outcome`), which keeps what the last write recorded; when even that cannot be
  recorded, the item's entry says it failed, with why. A dry run records nothing and writes nothing:
  it reports the plan.

  An item written otherwise than the source has it has its entry and its record say so: its
  target's note (`MishkaCmsMigration.Target`'s `note/2`), then the pieces of its content no plugin
  converted, kept as escaped text, joined by `"; "`, as in
  `"draft_from_pending; unconverted: acme/callout, gallery"`. A dry run asks no plugin, so it names
  every piece the source left to convert.

  An item connected to a record the CMS already held (`MishkaCmsMigration.Target`'s `existing/2`)
  is not written: in an import it is recorded against that record, with no `target_updated_at`, as
  skipped, `"connected"`; a dry run reports it so.

  An item with a parent (`MishkaCmsMigration.Source.Item`'s `parent`), which the walk settles
  first, is written under the CMS record its parent's item recorded: the target is handed that
  record's id as its context's `parent_id`. When the parent has none — it failed, was never written,
  or the source never listed it — the item is skipped as `"parent_missing"`, so it is not written
  out of its place, and the run that writes the parent writes it too.

  A plugin, a target or the CMS action that raises or exits while an item is converted, offered or
  written fails that item alone, with the exception's message as its reason.
  """

  alias Ash.Resource.Info
  alias MishkaCmsMigration.{Events, MigrationItem, Report}
  alias MishkaCmsMigration.Source.Item

  @doc """
  Settles `item` by `plan` and answers its entry in the report:

    * `{:created, target, nil}` or `{:updated, target, record}` — written in an import, reported
      in a dry run, with its target's note and the pieces of its content left unconverted as its
      reason;
    * `{:connected, target, record}` — recorded against `record` in an import, never written, and
      reported as skipped, `"connected"`;
    * `{:skipped, reason}` or `{:failed, reason}` — recorded with its reason in an import; an item
      whose row could not be read has only its kind and, when the row named one, its source id;
    * `:duplicate` — the source listed its id before: reported, never recorded.
  """
  @spec call(map(), Item.t(), term()) :: Report.entry()
  def call(_state, %Item{} = item, :duplicate),
    do: Report.entry(item.kind, item.source_id, item.title, :skipped, "duplicate_in_source")

  def call(state, %Item{} = item, {outcome, reason}) when outcome in [:skipped, :failed],
    do: entry(state, item, outcome, reason)

  def call(%{mode: :dry_run}, %Item{} = item, {:connected, _target, _record}),
    do: Report.entry(item.kind, item.source_id, item.title, :skipped, "connected")

  def call(%{mode: :import} = state, %Item{} = item, {:connected, target, record}) do
    state
    |> recorded(item, target, %{id: record.id, updated_at: nil}, {:skipped, "connected"})
    |> stored()
    |> entered(item, :skipped, "connected")
  end

  def call(%{mode: :dry_run} = state, %Item{} = item, {outcome, target, record}),
    do:
      Report.entry(
        item.kind,
        item.source_id,
        item.title,
        outcome,
        note(target, item, %{state.context | record: record}, to_convert(item))
      )

  def call(%{mode: :import} = state, %Item{} = item, {outcome, target, record}) do
    state
    |> written(item, target, outcome, record)
    |> settled(state, item, outcome)
  end

  defp settled({:ok, _record, note}, _state, item, outcome),
    do: Report.entry(item.kind, item.source_id, item.title, outcome, note)

  defp settled({:skipped, reason}, state, item, _outcome),
    do: entry(state, item, :skipped, reason)

  defp settled({:error, error}, state, item, _outcome),
    do: entry(state, item, :failed, Report.reason(error))

  defp entry(state, item, outcome, reason),
    do: state |> noted(item, outcome, reason) |> entered(item, outcome, reason)

  defp entered(:ok, item, outcome, reason),
    do: Report.entry(item.kind, item.source_id, item.title, outcome, reason)

  defp entered({:error, error}, item, _outcome, _reason),
    do: Report.entry(item.kind, item.source_id, item.title, :failed, Report.reason(error))

  defp written(state, source_item, target, outcome, record) do
    with {:ok, context} <- parented(state, source_item, record),
         {:ok, item, kept} <- convert(state, source_item),
         {:ok, item} <- Events.before_import(item, outcome, state.run, state.actor),
         note = note(target, item, context, kept),
         {:ok, written} <-
           target.prepare(
             item,
             context,
             &transacted(state, {source_item, item}, {outcome, target, record}, &1, note)
           ) do
      {:ok, written, note}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp transacted(state, items, {_outcome, target, _record} = plan, context, note),
    do:
      Ash.transact([target.resource(), MigrationItem], fn ->
        store(state, items, plan, context, note)
      end)

  defp store(state, {source_item, item}, {outcome, target, record}, context, note) do
    with {:ok, written} <- write(target, item, record, context),
         {:ok, _item} <- recorded(state, source_item, target, written, {outcome, note}) do
      {:ok, written}
    end
  end

  defp stored({:ok, _item}), do: :ok
  defp stored({:error, error}), do: {:error, error}

  defp parented(state, %Item{parent: nil}, record),
    do: {:ok, target_context(state, nil, record)}

  defp parented(state, %Item{kind: kind, parent: parent}, record) do
    state.run.source_host
    |> MishkaCmsMigration.items_by_sources(kind, [parent], scope: state.scope)
    |> parent_record(state, record)
  end

  defp parent_record({:ok, [%MigrationItem{target_id: id}]}, state, record) when is_binary(id),
    do: {:ok, target_context(state, id, record)}

  defp parent_record({:ok, _items}, _state, _record), do: {:skipped, "parent_missing"}
  defp parent_record({:error, error}, _state, _record), do: {:error, error}

  defp write(target, item, nil, context) do
    target.resource()
    |> Info.action(target.actions().create)
    |> create(target.resource(), target.attrs(item, context), context)
  end

  defp write(target, item, record, context) do
    record
    |> Ash.Changeset.for_update(target.actions().update, target.attrs(item, context), as(context))
    |> Ash.update()
  end

  defp create(%{type: :action, name: name}, resource, attrs, context),
    do: resource |> Ash.ActionInput.for_action(name, attrs, as(context)) |> Ash.run_action()

  defp create(%{name: name}, resource, attrs, context),
    do: resource |> Ash.Changeset.for_create(name, attrs, as(context)) |> Ash.create()

  defp as(context), do: [actor: context.actor, tenant: context.site_id]

  defp recorded(state, item, target, %{id: id, updated_at: updated_at}, {outcome, note}) do
    MishkaCmsMigration.record_item(
      %{
        source_host: state.run.source_host,
        source_kind: item.kind,
        source_id: item.source_id,
        run_id: state.run.id,
        title: item.title,
        source_modified_at: item.modified_at,
        content_hash: Item.hash(item),
        target_resource: inspect(target.resource()),
        target_id: id,
        target_updated_at: updated_at,
        outcome: outcome,
        reason: note,
        extra: item.extra
      },
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
               outcome: outcome,
               reason: reason
             },
             scope: state.scope
           ),
         do: :ok
  end

  defp noted(_state, _item, _outcome, _reason), do: :ok

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

  defp target_context(state, parent_id, record),
    do: %{state.context | parent_id: parent_id, record: record}
end
