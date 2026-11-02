# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Workers.Helpers.Decision do
  @moduledoc """
  What a dry run or an import does with each item of a page (`call/3`), against what earlier runs
  recorded for the site (`MishkaCmsMigration.MigrationItem`), found by the run's source host, the
  item's kind and its source id:

    * none, or one never written — `{:created, target, nil}`;
    * its `MishkaCmsMigration.Source.Item.hash/1` is the one recorded — `{:skipped, "unchanged"}`;
    * the row it was written to is gone — `{:skipped, "target_missing"}`;
    * the row's `updated_at` is not the one recorded when it was written: an admin changed it in
      the CMS — `{:skipped, "edited_in_cms"}`;
    * otherwise — `{:updated, target, record}`, the CMS record to write over.

  An item whose kind has no target (`MishkaCmsMigration.Target`) is `{:skipped, "no_target"}`.

  Items are found by source host as well as by kind and id, so several sources moved into one site
  never meet: the same id from two hosts is two items, each with its own record.

  A page is read twice, whatever its size: once for the items earlier runs recorded, once for the
  rows they were written to.
  """

  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Target

  @typedoc "What to do with an item: write a new record, write over `record`, or leave it, and why."
  @type plan ::
          {:created, module(), nil} | {:updated, module(), struct()} | {:skipped, String.t()}

  @doc "The plan for each of `items`, a page of `kind`, by source id."
  @spec call(map(), String.t(), [Item.t()]) :: %{String.t() => plan()}
  def call(state, kind, items) do
    case Target.fetch(kind) do
      {:ok, target} -> plans(state.run, target, kind, items)
      {:error, :not_installed} -> Map.new(items, &{&1.source_id, {:skipped, "no_target"}})
    end
  end

  defp plans(run, target, kind, items) do
    known = known(run, kind, items)
    records = Target.current(target, Enum.flat_map(Map.values(known), &target_id/1), run.site_id)

    Map.new(items, fn item ->
      {item.source_id, plan(target, item, Map.get(known, item.source_id), records)}
    end)
  end

  defp plan(target, _item, nil, _records), do: {:created, target, nil}
  defp plan(target, _item, %{target_id: nil}, _records), do: {:created, target, nil}

  defp plan(target, item, known, records),
    do: decide(target, known, Item.hash(item), Map.get(records, known.target_id))

  defp decide(_target, %{content_hash: hash}, hash, _record), do: {:skipped, "unchanged"}
  defp decide(_target, _known, _hash, nil), do: {:skipped, "target_missing"}

  defp decide(target, known, _hash, record) do
    case edited?(record, known) do
      true -> {:skipped, "edited_in_cms"}
      false -> {:updated, target, record}
    end
  end

  defp edited?(%{updated_at: %DateTime{} = now}, %{target_updated_at: %DateTime{} = then}),
    do: DateTime.compare(now, then) != :eq

  defp edited?(_record, _known), do: true

  defp target_id(%{target_id: nil}), do: []
  defp target_id(%{target_id: id}), do: [id]

  defp known(_run, _kind, []), do: %{}

  defp known(run, kind, items) do
    run.source_host
    |> MishkaCmsMigration.items_by_sources!(kind, Enum.map(items, & &1.source_id),
      tenant: run.site_id,
      authorize?: false
    )
    |> Map.new(&{&1.source_id, &1})
  end
end
