# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Workers.Helpers.Needs do
  @moduledoc """
  What the items of a page of a job of picked items need that the job was not asked for
  (`MishkaCmsMigration.Workers.Helpers.Pipeline`): each item's parent and the items of other kinds
  its record points at (`MishkaCmsMigration.Target`'s `needs/1`). A full run walks a parent before
  its children and a kind before the kinds that point at it; a job of picked items brings nothing
  else, so what it needs comes from what earlier imports recorded
  (`MishkaCmsMigration.MigrationItem`), read in one query for the page, by the run's source host,
  the kinds and the source ids. What the job was asked for too is never waited on: the walk brings
  it first.

  `call/3` answers:

    * `waits` — by source id, why an item waits, in the words a full import uses where it has them:
      `"parent_missing"` for a parent, `"post_missing"` for a post (as a comment's import says),
      and `"waits_for: <kinds>"` for the other kinds, joined by `"; "`. What it needs waits it when it
      has no CMS record, is not left out (by an admin, or under a parent left out, as the last dry
      run or import said, `"parent_left_out"`), and no import skipped it: it was never imported,
      failed, or waits for a decision. The walk holds back only an item it would create or update;
      one it leaves as it is, or an admin's choice, stands;
    * `parents` — the parents the earlier imports recorded, by source id, `true` for one left out
      either way: the walk settles each child at once, and skips one under a left-out parent as
      `"parent_left_out"`, however deep, as it does in a full run.

  A full run (`picked` is `nil`) asks too, in the same one query for the page, only for what waits
  for an admin's decision on its archived record, or on one deleted for good
  (`MishkaCmsMigration.Workers.Helpers.Decision.record_conflicts/0`), as this run's dry run planned
  it or its import left it, the walk having settled that kind first: an item it would write
  pointing at that record is refused by the CMS, such as a post's archived tag, or would lose it,
  such as a post's deleted tag, so it waits as `"waits_for: <kinds>"` until the admin restores the
  record, imports it again or leaves it out. Nothing else holds it, and it has no `parents`. An
  item that waits on that decision holds a job of picked items too, whatever record it has.
  """

  require Ash.Query

  alias MishkaCmsMigration.{MigrationItem, Target}
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Workers.Helpers.Decision

  @missing %{"post" => "post_missing"}
  @record_conflicts Decision.record_conflicts()

  @doc "What the picked `items`, a page of `kind`, need, for the walk of `state`."
  @spec call(map(), String.t(), [Item.t()]) :: %{
          waits: %{String.t() => String.t()},
          parents: %{String.t() => boolean()}
        }
  def call(_state, _kind, []), do: %{waits: %{}, parents: %{}}

  def call(state, kind, items) do
    target = kind |> Target.fetch() |> needs_of()
    needed = Map.new(items, &{&1.source_id, needed(state, kind, target, &1)})
    found = needed |> Map.values() |> List.flatten() |> Enum.uniq() |> found(state)

    %{
      waits:
        for(
          {id, refs} <- needed,
          reason = waits(kind, refs, found, state),
          into: %{},
          do: {id, reason}
        ),
      parents: parents(state, kind, items, found)
    }
  end

  defp parents(%{picked: nil}, _kind, _items, _found), do: %{}

  defp parents(_state, kind, items, found),
    do:
      for(
        %Item{parent: parent} <- items,
        %MigrationItem{} = found_parent <- [found[{kind, parent}]],
        into: %{},
        do: {parent, left_out?(found_parent)}
      )

  defp needs_of({:ok, target}), do: &target.needs/1
  defp needs_of({:error, :not_installed}), do: fn _item -> %{} end

  defp needed(%{picked: nil}, _kind, needs, item),
    do:
      for(
        {needed_kind, ids} <- needs.(item),
        id <- ids,
        uniq: true,
        do: {needed_kind, to_string(id)}
      )

  defp needed(state, kind, needs, item) do
    refs =
      for {needed_kind, ids} <- needs.(item), id <- ids, do: {needed_kind, to_string(id)}

    [{kind, item.parent} | refs]
    |> Enum.reject(fn {needed_kind, id} ->
      is_nil(id) or id in Map.get(state.picked, needed_kind, [])
    end)
    |> Enum.uniq()
  end

  defp found([], _state), do: %{}

  defp found(refs, state) do
    {kinds, ids} = Enum.unzip(refs)

    MigrationItem
    |> Ash.Query.filter(
      source_host == ^state.run.source_host and source_kind in ^Enum.uniq(kinds) and
        source_id in ^Enum.uniq(ids)
    )
    |> Ash.read!(scope: state.scope)
    |> Map.new(&{{&1.source_kind, &1.source_id}, &1})
  end

  defp waits(kind, refs, found, state) do
    {parent, others} =
      refs
      |> Enum.filter(&waiting_on?(found[&1], state))
      |> Enum.split_with(&(elem(&1, 0) == kind))

    {missing, others} = Enum.split_with(others, &is_map_key(@missing, elem(&1, 0)))

    [parent_missing(parent) | Enum.map(missing, &Map.fetch!(@missing, elem(&1, 0)))]
    |> Enum.concat([waits_for(others)])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> reason()
  end

  defp waiting_on?(item, %{mode: mode, picked: picked}),
    do: record_conflict?(item, mode) or (is_map(picked) and missing?(item))

  defp record_conflict?(
         %MigrationItem{left_out: false, outcome: :undecided, reason: conflict},
         :import
       )
       when conflict in @record_conflicts,
       do: true

  defp record_conflict?(
         %MigrationItem{left_out: false, plan: :undecided, plan_reason: conflict},
         :dry_run
       )
       when conflict in @record_conflicts,
       do: true

  defp record_conflict?(_item, _mode), do: false

  defp missing?(%MigrationItem{target_id: id}) when is_binary(id), do: false
  defp missing?(%MigrationItem{outcome: :skipped}), do: false
  defp missing?(%MigrationItem{} = item), do: not left_out?(item)
  defp missing?(nil), do: true

  defp left_out?(%MigrationItem{left_out: true}), do: true
  defp left_out?(%MigrationItem{reason: "parent_left_out"}), do: true
  defp left_out?(%MigrationItem{plan_reason: "parent_left_out"}), do: true
  defp left_out?(_item), do: false

  defp parent_missing([]), do: nil
  defp parent_missing(_parent), do: "parent_missing"

  defp waits_for([]), do: nil

  defp waits_for(refs),
    do: "waits_for: " <> (refs |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.join(", "))

  defp reason([]), do: nil
  defp reason(parts), do: Enum.join(parts, "; ")
end
