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
      changed and whatever the CMS holds; a CMS record an import wrote for it is kept as it is;
    * the admin mapped it to a CMS record (`mapped_id`) — `{:mapped, target, record}`, the record,
      which the import connects it to and never writes, whatever the source changed, what an
      earlier run wrote for it and what the target's `existing/2` would find; when that record is
      gone, `{:skipped, "mapped_missing"}`.

  Then, what earlier runs recorded:

    * none, or one never written — `{:created, target, nil, decisions}`, unless the target finds
      it in the CMS already (`MishkaCmsMigration.Target`'s `existing/2`):
      `{:connected, target, record}`, the CMS record it is, `{:updated, target, record, decisions}`,
      the CMS record it is written over, `{:created, target, nil, decisions, prepared}`, created
      with what the target found for its write, `{:skipped, reason}`, why it is left out, or
      `{:undecided, conflict}`, a conflict on the site no admin has decided yet;
    * its `MishkaCmsMigration.Source.Item.hash/1` is the one recorded — `{:skipped, "unchanged"}`;
    * the CMS record it was written to is gone — `{:skipped, "target_missing"}`;
    * it was connected to a record the CMS already held (no `target_updated_at` was recorded): the
      record is the CMS's own and is never written — `{:skipped, "connected"}`;
    * the CMS record's `updated_at` is not the one recorded when it was written: an admin changed
      it in the CMS — `{:skipped, "edited_in_cms"}`;
    * otherwise — `{:updated, target, record, decisions}`, the CMS record to write over.

  `decisions` are the admin's answers to the conflicts the item met
  (`MishkaCmsMigration.MigrationItem`'s `decisions`), which the target is handed with the item
  (`MishkaCmsMigration.Target.decision/3`); `existing/2` is handed those of the page's items it is
  asked about.

  The CMS records are read through the target resource's primary read as the admin running the
  job, under the CMS's own policies; a read the CMS refuses fails the attempt, as an error of the
  walk does (`MishkaCmsMigration.Workers.Helpers.Pipeline`).

  An item whose kind has no target (`MishkaCmsMigration.Target`) is `{:skipped, "no_target"}`,
  unless it is a kind the Blog writes (`MishkaCmsMigration.Application.blog_kinds/0`) on a node
  without the Blog: then it waits for an admin's decision, `{:undecided, "blog_missing"}`, until the
  admin left it out (`{:skipped, "left_out_by_admin"}`) or decided to wait for the Blog
  (`{:skipped, "waits_for_blog"}`), and a later run, once the Blog is there, plans it as any other.
  One the run's choices (`MishkaCmsMigration.MigrationRun`'s options) leave out wherever the Blog
  is, as its target does, is `{:skipped, "not_chosen"}` instead, with nothing to decide: a comment
  while `comments` is off (`MishkaCmsMigration.Targets.BlogComment`), and a post's old address
  while `post_address` is `"blog_without_redirects"` (`MishkaCmsMigration.Targets.PostRedirect`).

  Items are found by source host as well as by kind and id, so several sources moved into one site
  never meet: the same id from two hosts is two items, each with its own CMS record.

  A page is read twice, whatever its size: once for the items earlier runs recorded, once for the
  CMS records they were written to; and its items no run has written are handed to the target's
  `existing/2` together, once.
  """

  require Ash.Query

  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Target

  @blog_kinds MishkaCmsMigration.Application.blog_kinds()

  @typedoc "An admin's answers to the conflicts an item met, by conflict."
  @type decisions :: %{String.t() => String.t()}

  @typedoc """
  What to do with an item: write a new record, with what the target found for its write when it
  found anything, write over `record`, record it against `record` the CMS already held, leave it,
  and why, or wait for an admin's decision on a conflict.
  """
  @type plan ::
          {:created, module(), nil, decisions()}
          | {:created, module(), nil, decisions(), term()}
          | {:updated, module(), struct(), decisions()}
          | {:connected, module(), struct()}
          | {:mapped, module(), struct()}
          | {:skipped, String.t()}
          | {:undecided, String.t()}

  @doc "The plan for each of `items`, a page of `kind`, by source id."
  @spec call(map(), String.t(), [Item.t()]) :: %{String.t() => plan()}
  def call(state, kind, items), do: kind |> Target.fetch() |> plans(state, kind, items)

  defp plans({:ok, target}, state, kind, items), do: plans(state, target, kind, items)

  defp plans({:error, :not_installed}, state, kind, items) when kind in @blog_kinds do
    known = known(state, kind, items)
    chosen = chosen?(state.options, kind)
    Map.new(items, &{&1.source_id, blog_missing(Map.get(known, &1.source_id), chosen)})
  end

  defp plans({:error, :not_installed}, _state, _kind, items),
    do: Map.new(items, &{&1.source_id, {:skipped, "no_target"}})

  defp plans(state, target, kind, items) do
    known = known(state, kind, items)
    records = known |> Map.values() |> Enum.flat_map(&record_refs(&1, target)) |> current(state)

    items
    |> Map.new(&{&1.source_id, plan(target, &1, Map.get(known, &1.source_id), records)})
    |> existing(target, items, state)
  end

  defp existing(plans, target, items, state) do
    new =
      for item <- items,
          match?({:created, _target, nil, _decided}, plans[item.source_id]),
          do: item

    decisions =
      for %{source_id: id} <- new,
          {:created, _target, nil, decided} = plans[id],
          decided != %{},
          into: %{},
          do: {id, decided}

    new
    |> found(target, %{state.context | decisions: decisions})
    |> Map.take(Enum.map(new, & &1.source_id))
    |> Enum.reduce(plans, fn {id, found}, plans ->
      Map.update!(plans, id, &connected(target, found, &1))
    end)
  end

  defp found([], _target, _context), do: %{}
  defp found(items, target, context), do: target.existing(items, context)

  defp connected(target, {:connected, record}, _plan), do: {:connected, target, record}

  defp connected(target, {:updated, record}, {:created, _target, nil, decided}),
    do: {:updated, target, record, decided}

  defp connected(target, {:created, prepared}, {:created, _target, nil, decided}),
    do: {:created, target, nil, decided, prepared}

  defp connected(_target, {:skipped, reason}, _plan) when is_binary(reason),
    do: {:skipped, reason}

  defp connected(_target, {:undecided, conflict}, _plan) when is_binary(conflict),
    do: {:undecided, conflict}

  defp current([], _state), do: %{}

  defp current(refs, state) do
    refs
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {resource, ids} ->
      resource
      |> Ash.Query.filter(id in ^ids)
      |> Ash.read!(actor: state.actor, tenant: state.run.site_id)
    end)
    |> Map.new(&{&1.id, &1})
  end

  defp plan(_target, _item, %{left_out: true}, _records), do: {:skipped, "left_out_by_admin"}

  defp plan(target, _item, %{mapped_id: id}, records) when is_binary(id),
    do: records |> Map.get(id) |> mapped(target)

  defp plan(target, _item, nil, _records), do: {:created, target, nil, %{}}

  defp plan(target, _item, %{target_id: nil, decisions: decided}, _records),
    do: {:created, target, nil, decided}

  defp plan(target, item, known, records),
    do: decide(target, known, Item.hash(item), Map.get(records, known.target_id))

  defp decide(_target, %{content_hash: hash}, hash, _record), do: {:skipped, "unchanged"}
  defp decide(_target, _known, _hash, nil), do: {:skipped, "target_missing"}
  defp decide(_target, %{target_updated_at: nil}, _hash, _record), do: {:skipped, "connected"}

  defp decide(target, known, _hash, record),
    do: record |> edited?(known) |> updated(target, record, known.decisions)

  defp updated(true, _target, _record, _decided), do: {:skipped, "edited_in_cms"}
  defp updated(false, target, record, decided), do: {:updated, target, record, decided}

  defp edited?(%{updated_at: %DateTime{} = now}, %{target_updated_at: %DateTime{} = then}),
    do: DateTime.compare(now, then) != :eq

  defp edited?(_record, _known), do: true

  defp blog_missing(%{left_out: true}, _chosen), do: {:skipped, "left_out_by_admin"}
  defp blog_missing(_known, false), do: {:skipped, "not_chosen"}

  defp blog_missing(%{decisions: %{"blog_missing" => "keep"}}, true),
    do: {:skipped, "waits_for_blog"}

  defp blog_missing(_known, true), do: {:undecided, "blog_missing"}

  defp chosen?(%{comments: false}, "comment"), do: false
  defp chosen?(%{post_address: "blog_without_redirects"}, "post_redirect"), do: false
  defp chosen?(_options, _kind), do: true

  defp mapped(nil, _target), do: {:skipped, "mapped_missing"}
  defp mapped(record, target), do: {:mapped, target, record}

  defp record_refs(item, target) do
    for {id, resource} <- [
          {item.target_id, written(item, target)},
          {item.mapped_id, target.resource()}
        ],
        not is_nil(id),
        do: {resource, id}
  end

  defp written(item, target),
    do: Enum.find(target.resources(), target.resource(), &(inspect(&1) == item.target_resource))

  defp known(_state, _kind, []), do: %{}

  defp known(state, kind, items) do
    state.run.source_host
    |> MishkaCmsMigration.items_by_sources!(kind, Enum.map(items, & &1.source_id),
      scope: state.scope
    )
    |> Map.new(&{&1.source_id, &1})
  end
end
