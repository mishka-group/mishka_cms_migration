# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Workers.Helpers.Decision do
  @moduledoc """
  What a dry run or an import does with each item of a page (`call/3`), against what earlier runs
  recorded for the site (`MishkaCmsMigration.MigrationItem`), found by the run's source host, the
  item's kind and its source id. An admin's choice on the item comes first, before anything the
  source or the CMS says:

    * the admin left it out (`left_out`) — `{:skipped, "left_out_by_admin"}`, whatever the source
      changed and whatever the CMS holds; a CMS record an import wrote for it is kept as it is.

  Then, what earlier runs recorded:

    * none, or one never written — `{:created, target, nil}`, unless the target finds it in the
      CMS already (`MishkaCmsMigration.Target`'s `existing/2`): `{:connected, target, record}`, the
      CMS record it is, or `{:skipped, reason}`, why it is left out;
    * its `MishkaCmsMigration.Source.Item.hash/1` is the one recorded — `{:skipped, "unchanged"}`;
    * the CMS record it was written to is gone — `{:skipped, "target_missing"}`;
    * it was connected to a record the CMS already held (no `target_updated_at` was recorded): the
      record is the CMS's own and is never written — `{:skipped, "connected"}`;
    * the CMS record's `updated_at` is not the one recorded when it was written: an admin changed
      it in the CMS — `{:skipped, "edited_in_cms"}`;
    * otherwise — `{:updated, target, record}`, the CMS record to write over.

  The CMS records are read through the target resource's primary read as the admin running the
  job, under the CMS's own policies; a read the CMS refuses fails the attempt, as an error of the
  walk does (`MishkaCmsMigration.Workers.Helpers.Pipeline`).

  An item whose kind has no target (`MishkaCmsMigration.Target`) is `{:skipped, "no_target"}`.

  Items are found by source host as well as by kind and id, so several sources moved into one site
  never meet: the same id from two hosts is two items, each with its own CMS record.

  A page is read twice, whatever its size: once for the items earlier runs recorded, once for the
  CMS records they were written to; and its items no run has written are handed to the target's
  `existing/2` together, once.
  """

  require Ash.Query

  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Target

  @typedoc """
  What to do with an item: write a new record, write over `record`, record it against `record` the
  CMS already held, or leave it, and why.
  """
  @type plan ::
          {:created, module(), nil}
          | {:updated, module(), struct()}
          | {:connected, module(), struct()}
          | {:skipped, String.t()}

  @doc "The plan for each of `items`, a page of `kind`, by source id."
  @spec call(map(), String.t(), [Item.t()]) :: %{String.t() => plan()}
  def call(state, kind, items), do: kind |> Target.fetch() |> plans(state, kind, items)

  defp plans({:ok, target}, state, kind, items), do: plans(state, target, kind, items)

  defp plans({:error, :not_installed}, _state, _kind, items),
    do: Map.new(items, &{&1.source_id, {:skipped, "no_target"}})

  defp plans(state, target, kind, items) do
    known = known(state, kind, items)
    records = known |> Map.values() |> Enum.flat_map(&target_id/1) |> current(target, state)

    items
    |> Map.new(&{&1.source_id, plan(target, &1, Map.get(known, &1.source_id), records)})
    |> existing(target, items, state)
  end

  defp existing(plans, target, items, state) do
    new = for item <- items, match?({:created, _target, nil}, plans[item.source_id]), do: item
    ids = Enum.map(new, & &1.source_id)

    new
    |> found(target, state)
    |> Map.take(ids)
    |> Enum.reduce(plans, fn {source_id, found}, plans ->
      Map.put(plans, source_id, connected(target, found))
    end)
  end

  defp found([], _target, _state), do: %{}
  defp found(items, target, state), do: target.existing(items, state.context)

  defp connected(target, {:connected, record}), do: {:connected, target, record}
  defp connected(_target, {:skipped, reason}) when is_binary(reason), do: {:skipped, reason}

  defp current([], _target, _state), do: %{}

  defp current(ids, target, state) do
    target.resource()
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(actor: state.actor, tenant: state.run.site_id)
    |> Map.new(&{&1.id, &1})
  end

  defp plan(_target, _item, %{left_out: true}, _records), do: {:skipped, "left_out_by_admin"}
  defp plan(target, _item, nil, _records), do: {:created, target, nil}
  defp plan(target, _item, %{target_id: nil}, _records), do: {:created, target, nil}

  defp plan(target, item, known, records),
    do: decide(target, known, Item.hash(item), Map.get(records, known.target_id))

  defp decide(_target, %{content_hash: hash}, hash, _record), do: {:skipped, "unchanged"}
  defp decide(_target, _known, _hash, nil), do: {:skipped, "target_missing"}
  defp decide(_target, %{target_updated_at: nil}, _hash, _record), do: {:skipped, "connected"}

  defp decide(target, known, _hash, record),
    do: record |> edited?(known) |> updated(target, record)

  defp updated(true, _target, _record), do: {:skipped, "edited_in_cms"}
  defp updated(false, target, record), do: {:updated, target, record}

  defp edited?(%{updated_at: %DateTime{} = now}, %{target_updated_at: %DateTime{} = then}),
    do: DateTime.compare(now, then) != :eq

  defp edited?(_record, _known), do: true

  defp target_id(%{target_id: nil}), do: []
  defp target_id(%{target_id: id}), do: [id]

  defp known(_state, _kind, []), do: %{}

  defp known(state, kind, items) do
    state.run.source_host
    |> MishkaCmsMigration.items_by_sources!(kind, Enum.map(items, & &1.source_id),
      scope: state.scope
    )
    |> Map.new(&{&1.source_id, &1})
  end
end
