# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Report do
  @moduledoc """
  What a dry run or an import did with each item, saved on the run
  (`MishkaCmsMigration.MigrationRun`'s `report`) and handed to `migration:import:finished`.

      %{
        counts: %{created: 2, updated: 1, skipped: 1, failed: 0, undecided: 0},
        guests: 0,
        kinds: [%{kind: "post", created: 2, updated: 1, skipped: 1, failed: 0, undecided: 0}],
        entries: [
          %{kind: "post", source_id: "12", title: "Hello", outcome: :skipped, reason: "unchanged"},
          ...
        ]
      }

  The outcome of an entry is one of `outcomes/0`. In an import it is what was done. In a dry run it
  is the plan, from what the source and earlier runs say, which the dry run also records on each
  item (`MishkaCmsMigration.MigrationItem`'s `plan`); a dry run asks no plugin and does not run
  the CMS action, so an item a `migration:item:before_import` plugin would skip, or one the CMS
  would refuse (an address another source already took, a value its validations reject), reads as
  created or updated in the dry run and as skipped or failed in the import.

  `reason` says why an item was skipped or failed, and, for an item created or updated, what was
  written otherwise than the source has it (`MishkaCmsMigration.Workers.Helpers.Writer`), `nil` when
  nothing was: its target's note (`MishkaCmsMigration.Target`'s `note/1`, such as
  `"draft_from_pending"`), then the pieces of its content no plugin converted, kept as escaped text
  (`"unconverted: "` and their names), joined by `"; "`. For a skipped or failed item:

    * `"left_out_by_admin"` — an admin left the item out on the Items page; a CMS record an
      import wrote for it is kept as it is.
    * `"parent_left_out"` — the item sits under one an admin left out, however deep; a CMS record an
      import wrote for it is kept as it is.
    * `"mapped_missing"` — an admin mapped the item to a CMS record that has since been deleted.
    * `"unchanged"` — the source has not changed the item since it was last written.
    * `"edited_in_cms"` — its CMS record was changed in the CMS after it was written, and is kept.
    * `"target_missing"` — its CMS record was deleted in the CMS after it was written, and stays
      deleted.
    * `"no_target"` — no target is registered for the item's kind (`MishkaCmsMigration.Target`).
    * `"waits_for_blog"` — the Blog is not installed, and an admin decided the item waits for it.
    * `"waits_for_admin"` — the admin who ran the import may not allow the item's video player on
      the site, and an admin decided it waits for one who may.
    * `"waits_for_language_urls"` — the links would not match the site's language addresses, and an
      admin decided the item waits until they do.
    * `"duplicate_in_source"` — the source listed this id of this kind before; the first is used.
    * `"parent_missing"` — the item sits under a parent that has no CMS record (it failed, or was
      never written), so it is left out until a run writes the parent.
    * a plugin's own reason, from `migration:item:before_import`; `"plugins_cannot_run"` while one
      of the plugins of that event, or of `migration:content:convert` for an item with a piece to
      convert, is not loaded; `"plugins_failed"` when one of them raised or answered something that
      is not the payload (`MishkaCmsMigration.Events`).
    * for a failure, what the source or the CMS action answered.

  An item is `:undecided` when the import cannot place it safely on its own: its target found a
  conflict on the site (`MishkaCmsMigration.Target`'s `existing/2`) that only an admin can settle,
  and no admin has answered it yet (`MishkaCmsMigration.MigrationItem`'s `decisions`). Nothing is
  written for it, and every later dry run and import asks again until an admin decides. Its reason
  is the conflict:

    * `"site_has_own"` — the site already has a value of its own for the setting
      (`MishkaCmsMigration.Targets.CmsSetting`);
    * `"menu_goes_to"` — a menu that is not the site's main one waits for the admin to say where
      it goes, `"menu_goes_to: <menu>"` when a block menu has the same links as the classic menu
      `<menu>` (`MishkaCmsMigration.Targets.CmsLayout`);
    * `"header_has_links"` — the site layout's header already has links of its own, where a menu
      goes (`MishkaCmsMigration.Targets.CmsLayout`);
    * `"footer_has_links"` — the same for the footer's free slot, where a menu goes that the admin
      sent to the footer;
    * `"component_name_taken"` — the site, or a menu of the same run, already has a component with
      the name a menu sent to a component of its own would take (`"component_written_first"` while
      the other menu has not written it yet) (`MishkaCmsMigration.Targets.CmsLayout`);
    * `"slug_taken"` — the site already has a category or a tag with the item's slug, or a page at
      its path (`MishkaCmsMigration.Targets.Helpers.BySlug`, `MishkaCmsMigration.Targets.CmsPage`);
    * `"blog_missing"` — the item is of a kind the Blog writes, and the Blog is not installed
      (`MishkaCmsMigration.Application.blog_kinds/0`);
    * `"player_not_allowed"` — the item's content frames a YouTube or Vimeo player the site does
      not allow, and the admin who ran it may not allow it
      (`MishkaCmsMigration.Targets.Helpers.Frames`);
    * `"draft_pages: <labels>"` — the main menu links pages the site does not serve, as the drafts
      pages come in as, named by the links' labels (`MishkaCmsMigration.Targets.CmsLayout`): the
      conflict is the part before `": "`;
    * `"language_urls: <cause>"` — the links the item writes would not follow the source's or the
      site's language addresses, `<cause>` being `polylang`, `wpml` or `prefix_all`
      (`MishkaCmsMigration.Targets.Helpers.LanguageUrls`).

  `duplicates` counts the media files that are the same bytes as an earlier one
  (`MishkaCmsMigration.Targets.CmsMedia`): `found` the ones the run met, `merged` those an admin
  decided to use the original for (`"same_file_used"`, `"same_file_used_no_redirect"`) and `kept`
  those decided to keep as their own (`"same_file_kept"`), the rest waiting for the decision
  (`"same_file: <title of the original>"`, an `:undecided` item). A dry run downloads nothing and
  counts none.

  `guests` counts the comments written, or planned, as a guest's (`"guest_comment: <name>"`,
  possibly followed by `"guest_email_dropped"`, the guest's email the Blog would refuse, left out
  of the comment) (`MishkaCmsMigration.Targets.BlogComment`).

  `counts` and `kinds` count every item. `kinds` has a count for each kind that had at least one
  item, in the order the kinds were walked; a kind the source listed nothing of has none.
  `entries` are the last 1,000 items met (`max_entries/0`), in the order they were settled (an item
  that waits for its parent comes right after it), so a report stays small however large the site:
  the items left out number the sum of `counts` less the length of `entries`, and every item is
  still recorded (`MishkaCmsMigration.MigrationItem`).
  """

  @outcomes [:created, :updated, :skipped, :failed, :undecided]
  @max_entries 1_000

  @typedoc "What happened, or would happen, to an item."
  @type outcome :: :created | :updated | :skipped | :failed | :undecided

  @typedoc "One item's entry."
  @type entry :: %{
          kind: String.t(),
          source_id: String.t() | nil,
          title: String.t() | nil,
          outcome: outcome(),
          reason: String.t() | nil
        }

  @type t :: %{
          required(:counts) => %{outcome() => non_neg_integer()},
          required(:kinds) => [map()],
          required(:entries) => [entry()],
          required(:guests) => non_neg_integer(),
          required(:duplicates) => %{
            found: non_neg_integer(),
            merged: non_neg_integer(),
            kept: non_neg_integer()
          },
          optional(:kept) => non_neg_integer()
        }

  @doc "The outcomes an entry may have."
  @spec outcomes() :: [outcome()]
  def outcomes, do: @outcomes

  @doc "How many entries a report keeps: the last ones added."
  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_entries

  @doc "A report with nothing in it."
  @spec new() :: t()
  def new,
    do: %{
      counts: zero(),
      kinds: [],
      entries: [],
      duplicates: %{found: 0, merged: 0, kept: 0},
      guests: 0,
      kept: 0
    }

  @doc "`report` with `entry` added. Call `done/1` once every entry is in."
  @spec add(t(), entry()) :: t()
  def add(report, %{kind: kind, outcome: outcome} = entry) when outcome in @outcomes do
    {entries, kept} = keep([entry | report.entries], report.kept + 1)

    %{
      counts: Map.update!(report.counts, outcome, &(&1 + 1)),
      kinds: count_kind(report.kinds, kind, outcome),
      entries: entries,
      duplicates: duplicate(report.duplicates, entry),
      guests: report.guests + guest(entry),
      kept: kept
    }
  end

  @doc "`report` as it is saved: its last `max_entries/0` entries, in the order they were added."
  @spec done(t()) :: t()
  def done(report) do
    %{
      counts: report.counts,
      kinds: report.kinds,
      duplicates: report.duplicates,
      guests: report.guests,
      entries: report.entries |> Enum.take(@max_entries) |> Enum.reverse()
    }
  end

  @doc "One item's entry: its kind, source id and title, its outcome and why."
  @spec entry(String.t(), String.t() | nil, String.t() | nil, outcome(), String.t() | nil) ::
          entry()
  def entry(kind, source_id, title, outcome, reason),
    do: %{kind: kind, source_id: source_id, title: title, outcome: outcome, reason: reason}

  @doc """
  The words an entry or a failed run keeps for why, at most 1000 characters: for an Ash error, each
  of its errors as `field: message`, translated with its values filled in
  (`MishkaGervaz.Errors.translate_error/2`, as the core's screens say them), and `"forbidden"` for
  a refusal by a policy; any other exception's message; a string as it is; an atom's name;
  guarded_struct's errors as `field: message` pairs; anything else inspected.
  """
  @spec reason(term()) :: String.t()
  def reason(%Ash.Error.Forbidden{}), do: "forbidden"

  def reason(%{__exception__: true, errors: [_ | _] = errors}),
    do: errors |> Enum.map_join("; ", &said/1) |> short()

  def reason(%{__exception__: true} = error), do: error |> Exception.message() |> short()
  def reason(reason) when is_binary(reason), do: short(reason)
  def reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  def reason([%{message: _} | _] = errors),
    do: errors |> Enum.map_join("; ", &"#{&1[:field]}: #{&1.message}") |> short()

  def reason(reason), do: reason |> inspect() |> short()

  defp said(%{field: field, message: message} = error)
       when is_atom(field) and not is_nil(field) and is_binary(message),
       do: "#{field}: #{MishkaGervaz.Errors.translate_error(message, Map.get(error, :vars))}"

  defp said(%{message: message} = error) when is_binary(message),
    do: MishkaGervaz.Errors.translate_error(message, Map.get(error, :vars))

  defp said(error), do: Exception.message(error)

  defp short(text), do: String.slice(text, 0, 1000)

  defp duplicate(duplicates, %{kind: "media", outcome: :undecided, reason: "same_file: " <> _}),
    do: %{duplicates | found: duplicates.found + 1}

  defp duplicate(duplicates, %{kind: "media", outcome: :skipped, reason: reason})
       when reason in ["same_file_used", "same_file_used_no_redirect"],
       do: %{duplicates | found: duplicates.found + 1, merged: duplicates.merged + 1}

  defp duplicate(duplicates, %{kind: "media", outcome: :created, reason: "same_file_kept"}),
    do: %{duplicates | found: duplicates.found + 1, kept: duplicates.kept + 1}

  defp duplicate(duplicates, _entry), do: duplicates

  defp guest(%{kind: "comment", outcome: outcome, reason: "guest_comment: " <> _})
       when outcome in [:created, :updated],
       do: 1

  defp guest(_entry), do: 0

  defp count_kind(kinds, kind, outcome),
    do: kinds |> Enum.find_index(&(&1.kind == kind)) |> counted(kinds, kind, outcome)

  defp counted(nil, kinds, kind, outcome),
    do: kinds ++ [zero() |> Map.put(:kind, kind) |> Map.update!(outcome, &(&1 + 1))]

  defp counted(index, kinds, _kind, outcome),
    do: List.update_at(kinds, index, &Map.update!(&1, outcome, fn count -> count + 1 end))

  defp keep(entries, kept) when kept > 2 * @max_entries,
    do: {Enum.take(entries, @max_entries), @max_entries}

  defp keep(entries, kept), do: {entries, kept}

  defp zero, do: Map.new(@outcomes, &{&1, 0})
end
