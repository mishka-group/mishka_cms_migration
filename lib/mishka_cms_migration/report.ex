# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Report do
  @moduledoc """
  What a dry run or an import did with each item, saved on the run
  (`MishkaCmsMigration.MigrationRun`'s `report`) and handed to `migration:import:finished`.

      %{
        counts: %{create: 2, update: 1, skip: 1, fail: 0},
        kinds: [%{kind: "post", create: 2, update: 1, skip: 1, fail: 0}],
        entries: [
          %{kind: "post", source_id: "12", title: "Hello", outcome: :skip, reason: "unchanged"},
          ...
        ]
      }

  The outcome of an entry is one of `outcomes/0`. In a dry run it is what an import would do; in an
  import it is what was done. `reason` says why an item was skipped or failed:

    * `"unchanged"` — the source has not changed the item since it was last written.
    * `"edited_in_cms"` — the row was changed in the CMS after it was written, and is kept.
    * `"target_missing"` — the row was deleted in the CMS after it was written, and stays deleted.
    * `"no_target"` — no target is registered for the item's kind (`MishkaCmsMigration.Target`).
    * `"duplicate_in_source"` — the source listed this id of this kind before; the first is used.
    * a plugin's own reason, from `migration:item:before_import`, or `"plugins_cannot_run"` while
      one of that event's plugins is not loaded.
    * for a failure, what the source or the CMS action answered.

  `kinds` lists each kind in the order it was walked. `entries` are in the order the items were met.
  """

  @outcomes [:create, :update, :skip, :fail]

  @typedoc "What happened, or would happen, to an item."
  @type outcome :: :create | :update | :skip | :fail

  @typedoc "One item's line."
  @type entry :: %{
          kind: String.t(),
          source_id: String.t() | nil,
          title: String.t() | nil,
          outcome: outcome(),
          reason: String.t() | nil
        }

  @type t :: %{
          counts: %{outcome() => non_neg_integer()},
          kinds: [map()],
          entries: [entry()]
        }

  @doc "The outcomes an entry may have."
  @spec outcomes() :: [outcome()]
  def outcomes, do: @outcomes

  @doc "A report with nothing in it."
  @spec new() :: t()
  def new, do: %{counts: zero(), kinds: [], entries: []}

  @doc "`report` with `entry` added. Call `done/1` once every entry is in."
  @spec add(t(), entry()) :: t()
  def add(report, %{kind: kind, outcome: outcome} = entry) when outcome in @outcomes do
    %{
      counts: Map.update!(report.counts, outcome, &(&1 + 1)),
      kinds: count_kind(report.kinds, kind, outcome),
      entries: [entry | report.entries]
    }
  end

  @doc "`report` with its entries in the order they were added."
  @spec done(t()) :: t()
  def done(report), do: %{report | entries: Enum.reverse(report.entries)}

  @doc "One item's line: its kind, source id and title, its outcome and why."
  @spec entry(String.t(), String.t() | nil, String.t() | nil, outcome(), String.t() | nil) ::
          entry()
  def entry(kind, source_id, title, outcome, reason),
    do: %{kind: kind, source_id: source_id, title: title, outcome: outcome, reason: reason}

  @doc """
  The words an entry or a failed run keeps for why: an exception's message, a string as it is, an
  atom's name, guarded_struct's errors as `field: message` pairs, anything else inspected. At most
  1000 characters.
  """
  @spec reason(term()) :: String.t()
  def reason(%{__exception__: true} = error), do: error |> Exception.message() |> short()
  def reason(reason) when is_binary(reason), do: short(reason)
  def reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  def reason([%{message: _} | _] = errors),
    do: errors |> Enum.map_join("; ", &"#{&1[:field]}: #{&1.message}") |> short()

  def reason(reason), do: reason |> inspect() |> short()

  defp short(text), do: String.slice(text, 0, 1000)

  defp count_kind(kinds, kind, outcome) do
    case Enum.find_index(kinds, &(&1.kind == kind)) do
      nil -> kinds ++ [zero() |> Map.put(:kind, kind) |> Map.update!(outcome, &(&1 + 1))]
      index -> List.update_at(kinds, index, &Map.update!(&1, outcome, fn count -> count + 1 end))
    end
  end

  defp zero, do: Map.new(@outcomes, &{&1, 0})
end
