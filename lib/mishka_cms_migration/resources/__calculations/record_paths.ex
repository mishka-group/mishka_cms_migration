# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Resources.Calculations.RecordPaths do
  @moduledoc """
  Where the CMS record of each item is, for the item's `:record_paths` calculation: the answer of
  `MishkaCmsMigration.MigrationRun.record_paths/2` for its kind and the record it was written to,
  or `nil` for an item with no record, a kind with no pages, and a record that is gone or that the
  reader may not read.

  The records are read as the reader, under the site of each item, through the resource of the
  kind's target (`MishkaCmsMigration.Target`): one read for each kind and site of the items asked
  for, so a page of a table costs a few reads whatever its size.
  """

  use Ash.Resource.Calculation

  require Ash.Query

  alias MishkaCmsMigration.{MigrationRun, Target}

  @impl true
  def load(_query, _opts, _context), do: [:source_kind, :target_id, :site_id]

  @impl true
  def calculate(items, _opts, context) do
    found =
      items
      |> Enum.filter(& &1.target_id)
      |> Enum.group_by(&{&1.source_kind, &1.site_id}, & &1.target_id)
      |> Enum.reduce(%{}, fn {{kind, site_id}, ids}, found ->
        kind |> records(site_id, ids, context.actor) |> Enum.into(found)
      end)

    Enum.map(items, &paths(&1, found[{&1.source_kind, &1.target_id}]))
  end

  defp paths(_item, nil), do: nil
  defp paths(item, record), do: MigrationRun.record_paths(item.source_kind, record)

  defp records(kind, site_id, ids, actor) do
    with {:ok, target} <- Target.fetch(kind),
         {:ok, records} <-
           target.resource()
           |> Ash.Query.filter(id in ^ids)
           |> Ash.read(actor: actor, tenant: site_id) do
      Map.new(records, &{{kind, &1.id}, &1})
    else
      _unreadable -> %{}
    end
  end
end
