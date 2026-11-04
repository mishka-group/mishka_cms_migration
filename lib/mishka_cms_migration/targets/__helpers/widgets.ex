# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.Helpers.Widgets do
  @moduledoc """
  The widgets of a page builder an item was laid out with that the CMS has no equivalent for, such
  as an Elementor form, slider or map, for the targets that write the content
  (`MishkaCmsMigration.Targets.CmsPage`, `MishkaCmsMigration.Targets.BlogPost`). The source names
  them in the item's `"unsupported_widgets"`, and puts what the builder drew for each in its place
  in the content, its fallback HTML (`MishkaCmsMigration.Sources.WordPress.Elementor`).

  Such an item is never written on its own: it waits for an admin's decision
  (`MishkaCmsMigration.MigrationItem`'s Decide…) on `"unsupported_widgets: <names>"`, the names
  joined by `", "`, in `existing/2` for an item no run has written, in the dry run too
  (`waiting/2`), and in `prepare/3` for any write (`call/2`). Import with the fallback HTML for
  those parts (`"import"`) writes it with that HTML, and the report says so
  (`"fallback_html: <names>"`, `note/2`); Leave the page out leaves the item out, as Leave out does.
  The conflict names the widgets, so a page that gains another such widget asks again.
  """

  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Target

  @conflict "unsupported_widgets: "

  @doc """
  The conflict `item` waits on: `"unsupported_widgets: <names>"` for an item laid out with widgets
  the CMS has no equivalent for, else `nil`.
  """
  @spec conflict(Item.t()) :: String.t() | nil
  def conflict(%Item{attrs: %{"unsupported_widgets" => [_ | _] = names}}),
    do: @conflict <> Enum.join(names, ", ")

  def conflict(_item), do: nil

  @doc """
  `:ok` for `item` to be written: it has no such widgets, or an admin decided to import it with
  their fallback HTML; else `{:undecided, conflict}`.
  """
  @spec call(Item.t(), Target.context()) :: :ok | {:undecided, String.t()}
  def call(item, context), do: item |> conflict() |> decided(item, context)

  @doc """
  What `existing/2` says of `item`: `{:undecided, conflict}` until an admin decides to import it
  with the fallback HTML, then `nil`, to be written, as for an item with no such widgets.
  """
  @spec waiting(Item.t(), Target.context()) :: Target.found() | nil
  def waiting(item, context), do: item |> call(context) |> found()

  @doc """
  What the report says of `item`'s widgets once it is written: `"fallback_html: <names>"`, else
  `nil`.
  """
  @spec note(Item.t(), Target.context()) :: String.t() | nil
  def note(item, context), do: item |> conflict() |> noted(item, context)

  defp decided(nil, _item, _context), do: :ok

  defp decided(conflict, item, context),
    do: context |> Target.decision(item, conflict) |> answered(conflict)

  defp answered("import", _conflict), do: :ok
  defp answered(_undecided, conflict), do: {:undecided, conflict}

  defp found(:ok), do: nil
  defp found(waiting), do: waiting

  defp noted(nil, _item, _context), do: nil

  defp noted(@conflict <> names = conflict, item, context),
    do: context |> Target.decision(item, conflict) |> fallback(names)

  defp fallback("import", names), do: "fallback_html: " <> names
  defp fallback(_undecided, _names), do: nil
end
