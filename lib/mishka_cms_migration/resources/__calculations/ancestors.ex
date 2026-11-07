# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Resources.Calculations.Ancestors do
  @moduledoc """
  The items above each item at the source, for the item's `:ancestors` calculation: its parent's
  item (`source_parent`, of its kind and source host on its site), that one's parent, and so on,
  the top one first, as the Items page draws an item's place (Where it sits) and the Map view
  places an item under its parents. `nil` for an item with no parent.

  A parent the migration keeps no item of (the source does not list it, such as a page in the
  trash) ends the chain as an item with no `id`, its `source_id` the parent's, which the page reads
  as Not in the source. An item in a loop of parents has each of them once.

  The chains of every item asked for are read in one query for each site, whatever their depth: a
  recursive query from the items up through their parents, by the identity that makes an item one
  per site, source host, kind and source id, read as the reader under the item's site. An item
  with no parent costs nothing, so a page with none reads nothing.
  """

  use Ash.Resource.Calculation

  require Ash.Query

  alias MishkaCmsMigration.MigrationItem

  @impl true
  def load(_query, _opts, _context), do: [:site_id, :source_host, :source_kind, :source_parent]

  @impl true
  def calculate(items, _opts, context) do
    found =
      items
      |> Enum.filter(& &1.source_parent)
      |> Enum.group_by(& &1.site_id, & &1.id)
      |> Enum.flat_map(fn {site_id, ids} -> read(site_id, ids, context.actor) end)
      |> Map.new(&{key(&1, &1.source_id), &1})

    Enum.map(items, &chain(&1, found))
  end

  defp read(site_id, ids, actor) do
    MigrationItem
    |> Ash.Query.filter(
      fragment(
        """
        ? IN (WITH RECURSIVE chain(id, source_parent, site_id, source_host, source_kind) AS (
          SELECT i.id, i.source_parent, i.site_id, i.source_host, i.source_kind
          FROM mishka_cms_migration_items AS i WHERE i.id = ANY(?)
          UNION
          SELECT p.id, p.source_parent, p.site_id, p.source_host, p.source_kind
          FROM mishka_cms_migration_items AS p JOIN chain AS c
            ON p.site_id = c.site_id AND p.source_host = c.source_host
            AND p.source_kind = c.source_kind AND p.source_id = c.source_parent
        ) SELECT id FROM chain)
        """,
        id,
        type(^ids, {:array, :uuid})
      )
    )
    |> Ash.read(actor: actor, tenant: site_id)
    |> readable()
  end

  defp readable({:ok, items}), do: items
  defp readable(_unreadable), do: []

  defp chain(%{source_parent: nil}, _found), do: nil
  defp chain(item, found), do: up(item, item.source_parent, found, [], %{item.id => true})

  defp up(_item, nil, _found, chain, _seen), do: chain

  defp up(item, parent, found, chain, seen),
    do: found |> Map.fetch(key(item, parent)) |> climbed(item, parent, {found, chain, seen})

  defp climbed({:ok, %MigrationItem{id: id}}, _item, _parent, {_found, chain, seen})
       when is_map_key(seen, id),
       do: chain

  defp climbed({:ok, above}, item, _parent, {found, chain, seen}),
    do: up(item, above.source_parent, found, [above | chain], Map.put(seen, above.id, true))

  defp climbed(:error, item, parent, {_found, chain, _seen}),
    do: [not_listed(item, parent) | chain]

  defp not_listed(item, parent),
    do: %MigrationItem{
      id: nil,
      site_id: item.site_id,
      source_host: item.source_host,
      source_kind: item.source_kind,
      source_id: parent
    }

  defp key(item, source_id), do: {item.site_id, item.source_host, item.source_kind, source_id}
end
