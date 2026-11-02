# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Workers.Helpers.Writer do
  @moduledoc """
  What happens to one item once it is decided (`MishkaCmsMigration.Workers.Helpers.Decision`), and
  its line of the report (`call/3`, answering `MishkaCmsMigration.Report.entry/5`).

  In an import an item to create or update has its content converted (`migration:content:convert`),
  is offered to the plugins (`migration:item:before_import`), is written through its target
  (`MishkaCmsMigration.Target.write/4`) as the admin who pressed Import, and is recorded
  (`MishkaCmsMigration.MigrationItem`'s `:record`) with the record it was written to, in one
  transaction (`Ash.transact/3`): either the CMS record and its item are both there, or neither is,
  so a retry never meets a record no item remembers. An item skipped or failed is recorded with why
  (`:record_outcome`), which keeps what the last write recorded. A dry run records nothing and
  writes nothing: it reports the plan.

  A plugin, a target or the CMS action that raises or exits while an item is converted, offered or
  written fails that item alone, with the exception's message as its reason.
  """

  alias MishkaCmsMigration.{Events, MigrationItem, Report, Target}
  alias MishkaCmsMigration.Source.Item

  @doc """
  Settles `item` by `plan` and answers its line of the report:

    * `{:created, target, nil}` or `{:updated, target, record}` — written in an import, reported
      in a dry run;
    * `{:skipped, reason}` — recorded as skipped in an import;
    * `:duplicate` — the source listed its id before: reported, never recorded;
    * `{:failed, reason}` with `{kind, source_id}` in place of the item — a row the source could
      not hand over as an item, recorded as failed when it named its source id.
  """
  @spec call(map(), Item.t() | {String.t(), String.t() | nil}, term()) :: Report.entry()
  def call(state, %Item{} = item, {:skipped, reason}), do: leave(state, item, :skipped, reason)

  def call(_state, %Item{} = item, :duplicate),
    do: Report.entry(item.kind, item.source_id, item.title, :skipped, "duplicate_in_source")

  def call(%{mode: :dry_run}, %Item{} = item, {outcome, _target, _record}),
    do: Report.entry(item.kind, item.source_id, item.title, outcome, nil)

  def call(%{mode: :import} = state, %Item{} = item, {outcome, target, record}) do
    case written(state, item, target, outcome, record) do
      {:ok, _record} -> Report.entry(item.kind, item.source_id, item.title, outcome, nil)
      {:skipped, reason} -> leave(state, item, :skipped, reason)
      {:error, error} -> leave(state, item, :failed, Report.reason(error))
    end
  end

  def call(state, {kind, source_id}, {:failed, reason}) do
    note(state, kind, source_id, :failed, reason)
    Report.entry(kind, source_id, nil, :failed, reason)
  end

  defp leave(state, item, outcome, reason) do
    note(state, item.kind, item.source_id, outcome, reason)
    Report.entry(item.kind, item.source_id, item.title, outcome, reason)
  end

  defp written(state, source_item, target, outcome, record) do
    with {:ok, item} <- convert(state, source_item),
         {:import, item} <- Events.before_import(item, outcome, state.run, state.actor) do
      Ash.transact([target.resource(), MigrationItem], fn ->
        store(state, source_item, item, {outcome, target, record})
      end)
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp store(state, source_item, item, {outcome, target, record}) do
    with {:ok, written} <- Target.write(target, item, record, target_context(state)),
         {:ok, _item} <- recorded(state, source_item, target, written, outcome) do
      {:ok, written}
    end
  end

  defp recorded(state, item, target, record, outcome) do
    MishkaCmsMigration.record_item(
      %{
        source_host: state.run.source_host,
        source_kind: item.kind,
        source_id: item.source_id,
        run_id: state.run.id,
        source_modified_at: item.modified_at,
        content_hash: Item.hash(item),
        target_resource: inspect(target.resource()),
        target_id: record.id,
        target_updated_at: record.updated_at,
        outcome: outcome,
        reason: nil,
        extra: item.extra
      },
      tenant: state.run.site_id,
      authorize?: false
    )
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

  defp convert(state, %Item{content: content} = item) when is_list(content) do
    case convert_pieces(state, item, content, []) do
      {:ok, pieces} -> {:ok, %{item | content: pieces}}
      :cannot_run -> {:skipped, "plugins_cannot_run"}
      :failed -> {:skipped, "plugins_failed"}
    end
  end

  defp convert(_state, item), do: {:ok, item}

  defp convert_pieces(_state, _item, [], done), do: {:ok, Enum.reverse(done)}

  defp convert_pieces(state, item, [piece | rest], done) do
    case converted(state, item, piece) do
      {:ok, piece} -> convert_pieces(state, item, rest, [piece | done])
      unconverted -> unconverted
    end
  end

  defp converted(_state, _item, %{html: html} = piece) when is_binary(html), do: {:ok, piece}

  defp converted(state, item, piece) do
    case Events.convert(piece, item, state.run, state.actor) do
      {:ok, html} -> {:ok, %{piece | html: html}}
      :unconverted -> {:ok, %{piece | html: escaped(piece.raw)}}
      failed -> failed
    end
  end

  defp escaped(nil), do: ""
  defp escaped(raw), do: raw |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp target_context(state),
    do: %{
      actor: state.actor,
      site_id: state.run.site_id,
      run_id: state.run.id,
      source_host: state.run.source_host,
      options: state.options
    }
end
