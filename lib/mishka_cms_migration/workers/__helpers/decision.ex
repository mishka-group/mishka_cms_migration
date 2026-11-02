# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Workers.Helpers.Decision do
  @moduledoc """
  What a dry run or an import does with each item of a page, against what earlier runs recorded for
  the site (`MishkaCmsMigration.MigrationItem`), found by the run's source host, the item's kind and
  its source id:

    * none, or one never written — **create**;
    * its `MishkaCmsMigration.Source.Item.hash/1` is the one recorded — **skip**, `"unchanged"`;
    * the row it was written to is gone — **skip**, `"target_missing"`;
    * the row's `updated_at` is not the one recorded when it was written: an admin changed it in
      the CMS — **skip**, `"edited_in_cms"`;
    * otherwise — **update** that row.

  An item whose kind has no target (`MishkaCmsMigration.Target`) is skipped, `"no_target"`.

  A page is read twice, whatever its size: once for the items earlier runs recorded, once for the
  rows they were written to.
  """

  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Target

  @typedoc "What one page of a kind is decided against."
  @type page :: %{
          kind: String.t(),
          target: module() | nil,
          known: %{String.t() => struct()},
          current: %{String.t() => struct()}
        }

  @typedoc "What to do with an item: write a new row, update `record`, or leave it, and why."
  @type plan :: {:created, nil} | {:updated, struct()} | {:skipped, String.t()}

  @doc "What `items` of `kind`, one page of `run`'s source, are decided against."
  @spec page(map(), String.t(), [Item.t()]) :: page()
  def page(run, kind, items) do
    target = target(kind)
    known = known(run, kind, items)
    %{kind: kind, target: target, known: known, current: current(target, known, run.site_id)}
  end

  @doc "What to do with `item` of `page`."
  @spec plan(page(), Item.t()) :: plan()
  def plan(%{target: nil}, _item), do: {:skipped, "no_target"}

  def plan(page, item) do
    case Map.get(page.known, item.source_id) do
      %{target_id: id} = known when id != nil -> decide(item, known, Map.get(page.current, id))
      _never_written -> {:created, nil}
    end
  end

  defp decide(item, known, record) do
    cond do
      known.content_hash == Item.hash(item) -> {:skipped, "unchanged"}
      is_nil(record) -> {:skipped, "target_missing"}
      edited?(record, known) -> {:skipped, "edited_in_cms"}
      true -> {:updated, record}
    end
  end

  defp edited?(record, known) do
    case {Map.get(record, :updated_at), known.target_updated_at} do
      {%DateTime{} = now, %DateTime{} = then} -> DateTime.compare(now, then) != :eq
      _unknown -> true
    end
  end

  defp target(kind) do
    case Target.fetch(kind) do
      {:ok, target} -> target
      {:error, _reason} -> nil
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

  defp current(nil, _known, _site_id), do: %{}

  defp current(target, known, site_id) do
    ids = for {_source_id, %{target_id: id}} <- known, id != nil, do: id
    Target.current(target, ids, site_id)
  end
end
