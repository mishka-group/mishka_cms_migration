# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Summary do
  @moduledoc """
  What came of an import of several items, a branch imported parents first or the rows picked
  together, in the one flash the Items page shows once its job settled them
  (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Index`), each item named with its outcome in
  its row's words (`MishkaCmsMigration.MigrationRun.reason_label/2`), what failed first:

      Import of 3 items: About failed: The page “About” at /:lang/about already answers at /about;
      Team and أميرة حداد skipped: their parent was not imported.

  The items skipped because their parent was not imported are named together, so a parent that
  failed is said once, not once for each item under it. Then what waits for a decision, what was
  skipped for another reason, what was created or updated, and how many the job never reached,
  such as an item the source no longer lists. A group names five items at most, then how many more.
  The flash is an error when anything failed, a warning when anything was skipped, waits for a
  decision or was not reached, and a success when every item was created or updated
  (`MishkaCmsMigrationWeb.Flash`).
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsMigration.{MigrationItem, MigrationRun}
  alias MishkaCmsMigrationWeb.Flash

  @under_parent ["parent_undecided", "parent_missing", "parent_not_listed"]
  @named 5

  @doc """
  The flash's kind and words for an import of the items `ids`, in their order, given the items
  its job settled, by id, as their broadcasts carried them.
  """
  @spec call([String.t()], %{String.t() => MigrationItem.t()}) ::
          {MishkaCmsMigrationWeb.Flash.kind(), String.t()}
  def call(ids, settled) do
    {met, unmet} = Enum.split_with(ids, &is_map_key(settled, &1))
    items = Enum.map(met, &Map.fetch!(settled, &1))
    {under_parent, skipped} = items |> outcome(:skipped) |> Enum.split_with(&under_parent?/1)

    parts =
      [
        items |> outcome(:failed) |> Enum.map(&failed_words/1),
        items |> outcome(:undecided) |> by_reason() |> Enum.map(&undecided_words/1),
        under_parent_words(under_parent),
        skipped |> by_reason() |> Enum.map(&skipped_words/1),
        items |> outcome(:created) |> written_words(:created),
        items |> outcome(:updated) |> written_words(:updated),
        unmet_words(length(unmet))
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    {kind(items, unmet),
     ngettext(
       "Import of %{count} item: %{parts}.",
       "Import of %{count} items: %{parts}.",
       length(ids),
       parts: Enum.join(parts, "; ")
     )}
  end

  defp outcome(items, outcome), do: Enum.filter(items, &(&1.outcome == outcome))

  defp by_reason(items), do: items |> Enum.group_by(& &1.reason) |> Enum.sort_by(&elem(&1, 0))

  defp under_parent?(%{reason: reason}) when is_binary(reason),
    do: reason |> String.split(": ", parts: 2) |> hd() |> Kernel.in(@under_parent)

  defp under_parent?(_item), do: false

  defp failed_words(%{reason: nil} = item), do: gettext("%{title} failed", title: titled(item))

  defp failed_words(item),
    do:
      gettext("%{title} failed: %{reason}", title: titled(item), reason: said(item.reason, item))

  defp undecided_words({reason, [first | _] = items}),
    do:
      ngettext(
        "%{titles} needs your decision: %{reason}",
        "%{titles} need your decision: %{reason}",
        length(items),
        titles: titles(items),
        reason: said(reason, first)
      )

  defp under_parent_words([]), do: nil

  defp under_parent_words(items),
    do:
      ngettext(
        "%{titles} skipped: its parent was not imported",
        "%{titles} skipped: their parent was not imported",
        length(items),
        titles: titles(items)
      )

  defp skipped_words({nil, items}), do: gettext("%{titles} skipped", titles: titles(items))

  defp skipped_words({reason, [first | _] = items}),
    do:
      gettext("%{titles} skipped: %{reason}", titles: titles(items), reason: said(reason, first))

  defp written_words([], _outcome), do: nil
  defp written_words(items, :created), do: gettext("%{titles} created", titles: titles(items))
  defp written_words(items, :updated), do: gettext("%{titles} updated", titles: titles(items))

  defp unmet_words(0), do: nil

  defp unmet_words(count),
    do:
      ngettext(
        "%{count} left as it was: the import did not reach it",
        "%{count} left as they were: the import did not reach them",
        count
      )

  defp said(nil, _item), do: ""

  defp said(reason, item),
    do: reason |> MigrationRun.reason_label(item.source_kind) |> String.trim_trailing(".")

  defp titles(items) when length(items) > @named do
    rest = length(items) - @named

    items
    |> Enum.take(@named)
    |> Enum.map(&titled/1)
    |> Enum.concat([ngettext("%{count} more", "%{count} more", rest)])
    |> Languages.join()
  end

  defp titles(items), do: items |> Enum.map(&titled/1) |> Languages.join()

  defp titled(%{title: title}) when is_binary(title) and title != "", do: title
  defp titled(item), do: "#" <> item.source_id

  defp kind(items, unmet) do
    kinds = Enum.map(items, &Flash.result_kind(&1.outcome))

    cond do
      :error in kinds -> :error
      unmet != [] or :warning in kinds -> :warning
      true -> :success
    end
  end
end
