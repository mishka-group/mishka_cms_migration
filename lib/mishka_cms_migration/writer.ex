# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Writer do
  @moduledoc """
  How an import writes one item and remembers it. The item's content is converted
  (`migration:content:convert`), the item is offered to the plugins (`migration:item:before_import`),
  and it is written through its target (`MishkaCmsMigration.Target.write/4`) as the admin who
  pressed Import. Then it is recorded (`MishkaCmsMigration.MigrationItem`): `:record` with the row
  it was written to, or `:record_outcome` with why it was skipped or failed, which keeps what the
  last write recorded. A dry run records nothing.

  Each function answers the item's line of the report (`MishkaCmsMigration.Report.entry/5`).
  """

  alias MishkaCmsMigration.{Events, Item, Report, Target}

  @recorded %{create: :created, update: :updated}
  @reported %{skipped: :skip, failed: :fail}

  @doc """
  Writes `item` of `page` by `action` (over `record` for an update) and records what happened.
  """
  @spec write(map(), map(), Item.t(), :create | :update, struct() | nil) :: Report.entry()
  def write(state, page, item, action, record) do
    case written(state, page, item, action, record) do
      {:ok, row} -> recorded(state, page, item, row, action)
      {:skip, reason} -> leave(state, page.kind, item, :skipped, reason)
      {:error, error} -> leave(state, page.kind, item, :failed, Report.reason(error))
    end
  end

  @doc "Records `item` of `kind` as `:skipped` or `:failed`, with `reason`, in an import."
  @spec leave(map(), String.t(), Item.t(), :skipped | :failed, String.t()) :: Report.entry()
  def leave(state, kind, item, outcome, reason) do
    note(state, kind, item.source_id, outcome, reason)
    Report.entry(kind, item.source_id, item.title, Map.fetch!(@reported, outcome), reason)
  end

  @doc """
  Records a row of `kind` the source could not hand over as an item as failed, when it named its
  source id, in an import.
  """
  @spec fail(map(), String.t(), String.t() | nil, String.t()) :: Report.entry()
  def fail(state, kind, source_id, reason) do
    note(state, kind, source_id, :failed, reason)
    Report.entry(kind, source_id, nil, :fail, reason)
  end

  defp written(state, page, item, action, record) do
    item = convert(state, item)

    with {:import, item} <- Events.before_import(item, action, state.run, state.actor) do
      Target.write(page.target, item, record, target_context(state))
    end
  end

  defp recorded(state, page, item, row, action) do
    MishkaCmsMigration.record_item!(
      %{
        source_host: state.run.source_host,
        source_kind: page.kind,
        source_id: item.source_id,
        run_id: state.run.id,
        source_modified_at: item.modified_at,
        content_hash: Item.hash(item),
        target_resource: inspect(page.target.resource()),
        target_id: row.id,
        target_updated_at: Map.get(row, :updated_at),
        outcome: Map.fetch!(@recorded, action),
        reason: nil
      },
      tenant: state.run.site_id,
      authorize?: false
    )

    Report.entry(page.kind, item.source_id, item.title, action, nil)
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

  defp target_context(state),
    do: %{
      actor: state.actor,
      site_id: state.run.site_id,
      run_id: state.run.id,
      source_host: state.run.source_host,
      options: state.options
    }
end
