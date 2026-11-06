# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Resources.Changes.Decided do
  @moduledoc """
  Keeps an admin's decision on the conflict an item waits on
  (`MishkaCmsMigration.MigrationItem.conflict/1`): the choice is put in the item's `decisions`
  under that conflict and brings the item back, so every later dry run and import follows it;
  `"leave_out"` leaves the item out instead.

  The conflict is the one the action's `conflict` argument names, one of the item's open conflicts
  (`MishkaCmsMigration.MigrationItem.conflicts/1`), such as `"parent_missing"` for Import anyway on
  an item that waits for its parent, or the item's first (`MishkaCmsMigration.MigrationItem.conflict/1`)
  when it names none; one that is not open on the item is as none.

  Given as the action's `decision` argument, the choice of one item's Decide…, a choice the
  conflict does not offer (`MishkaCmsMigration.MigrationItem.choices/1`), any choice on an item
  that waits on none, and any choice on an item whose decision already took effect
  (`MishkaCmsMigration.MigrationItem.settled?/1`), is refused on `decision`, in words an admin
  reads; no choice changes nothing. A decision that took effect stays: an item an import wrote as
  new is never moved onto the slug of the site's own record, which the Blog would refuse, and one
  it connected to the site's record is never written over it.

      update :choose do
        argument :decision, :string
        change MishkaCmsMigration.Resources.Changes.Decided
      end

  Given as `:choice`, the same answer for the rows an admin picked, it decides the items whose
  conflict offers it and leaves the others as they are, so a bulk choice over mixed rows never
  undoes the rows it answers.

      update :decide_keep do
        change {MishkaCmsMigration.Resources.Changes.Decided, choice: "keep"}
      end

  With `bulk: true` the `decision` and `conflict` arguments are answered the same way, for the
  items of a group the Decisions panel decides at once.

      update :decide do
        argument :conflict, :string
        argument :decision, :string
        change {MishkaCmsMigration.Resources.Changes.Decided, bulk: true}
      end
  """

  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  alias Ash.Error.Changes.InvalidArgument
  alias MishkaCmsMigration.MigrationItem

  @nothing dgettext_noop("errors", "Nothing on this item waits for your decision.")

  @took_effect dgettext_noop(
                 "errors",
                 "Your decision already took effect: the import wrote or connected this item by it, so it stays."
               )
  @not_offered dgettext_noop("errors", "Pick one of the choices this item offers.")

  @impl true
  def change(changeset, opts, _context) do
    choice = opts[:choice] || Ash.Changeset.get_argument(changeset, :decision)
    conflict = changeset |> Ash.Changeset.get_argument(:conflict) |> open(changeset.data)

    changeset.data
    |> MigrationItem.settled?()
    |> answer(conflict, choice, changeset.data)
    |> settled(changeset, opts[:choice] || opts[:bulk])
  end

  defp open(nil, item), do: MigrationItem.conflict(item)
  defp open(conflict, item), do: Enum.find(MigrationItem.conflicts(item), &(&1 == conflict))

  defp answer(_settled, _conflict, nil, _item), do: :none
  defp answer(true, _conflict, _choice, _item), do: {:error, @took_effect}
  defp answer(false, nil, _choice, _item), do: {:error, @nothing}

  defp answer(false, conflict, choice, item),
    do: answered(conflict, choice, item, choice in MigrationItem.choices(conflict))

  defp answered(_conflict, "leave_out", _item, true), do: {:ok, left_out: true}

  defp answered(conflict, choice, item, true),
    do: {:ok, decisions: Map.put(item.decisions, conflict, choice), left_out: false}

  defp answered(_conflict, _choice, _item, false), do: {:error, @not_offered}

  defp settled({:ok, attributes}, changeset, _bulk),
    do: Ash.Changeset.force_change_attributes(changeset, attributes)

  defp settled({:error, message}, changeset, nil),
    do:
      Ash.Changeset.add_error(
        changeset,
        InvalidArgument.exception(field: :decision, message: message)
      )

  defp settled(_left_as_it_is, changeset, _bulk), do: changeset
end
