# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.Helpers.Scripts do
  @moduledoc """
  The scripts and inline event handlers a post's or a page's content holds, for the targets that
  write the content (`MishkaCmsMigration.Targets.CmsPage`, `MishkaCmsMigration.Targets.BlogPost`):
  each `<script>` element and each `on…` attribute (`onclick`, `onerror`, ...), whatever the source
  and the editor that made the content.

  Such an item is never written on its own: it waits for an admin's decision
  (`MishkaCmsMigration.MigrationItem`'s Decide…) on `"scripts"`, its reason naming them after `": "`
  in the order the content has them, a handler with its element, as in
  `"scripts: onclick on a, script"`, in the dry run (the target's `waiting/2`, `waiting/2` here) and
  in `prepare/3` for any write (`call/2`). Remove them (`"import"`) writes the content without them
  (`removed/3`), and Keep them, I trust this content (`"trust"`), writes it as it is; the report
  says which (`note/2`: `"scripts_removed: <found>"`, `"scripts_kept: <found>"`). Keep them is not
  a choice the Items table's Keep the site as it is makes for picked rows: trusting a script is
  decided item by item.
  """

  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Target

  @conflict "scripts"

  @doc """
  The conflict `item` waits on: `"scripts: <found>"` for content that holds a script or an inline
  event handler, else `nil`.
  """
  @spec conflict(Item.t()) :: String.t() | nil
  def conflict(item), do: item |> Item.html() |> found() |> conflicted()

  @doc """
  `:ok` for `item` to be written: its content holds no script, or an admin decided to remove them
  or to keep them; else `{:undecided, conflict}`.
  """
  @spec call(Item.t(), Target.context()) :: :ok | {:undecided, String.t()}
  def call(item, context), do: item |> conflict() |> decided(item, context)

  @doc """
  What the target's `waiting/2` says of `item`: `{:undecided, conflict}` until an admin decides,
  then `nil`, to be written, as for content with no script.
  """
  @spec waiting(Item.t(), Target.context()) :: Target.found() | nil
  def waiting(item, context), do: item |> call(context) |> found_waiting()

  @doc """
  `html`, the content of `item`, without its scripts and inline event handlers once an admin
  decided to remove them; as it is otherwise.
  """
  @spec removed(String.t(), Item.t(), Target.context()) :: String.t()
  def removed(html, item, context),
    do: context |> Target.decision(item, @conflict) |> stripped(html)

  @doc """
  What the report says of `item`'s scripts once it is written: `"scripts_removed: <found>"` or
  `"scripts_kept: <found>"`, as an admin decided, else `nil`.
  """
  @spec note(Item.t(), Target.context()) :: String.t() | nil
  def note(item, context), do: item |> conflict() |> noted(item, context)

  defp found(html),
    do:
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.to_tree()
      |> LazyHTML.Tree.postwalk([], &spotted/2)
      |> elem(1)
      |> Enum.reverse()
      |> Enum.uniq()

  defp spotted({"script", _attrs, _children} = node, found), do: {node, ["script" | found]}

  defp spotted({tag, attrs, _children} = node, found),
    do: {node, Enum.reduce(attrs, found, &handler(&1, tag, &2))}

  defp spotted(node, found), do: {node, found}

  defp handler({name, _value}, tag, found), do: name |> handler?() |> handled(name, tag, found)

  defp handled(true, name, tag, found), do: ["#{name} on #{tag}" | found]
  defp handled(false, _name, _tag, found), do: found

  defp handler?(name), do: name |> String.downcase() |> String.starts_with?("on")

  defp conflicted([]), do: nil
  defp conflicted(found), do: @conflict <> ": " <> Enum.join(found, ", ")

  defp decided(nil, _item, _context), do: :ok

  defp decided(conflict, item, context),
    do: context |> Target.decision(item, @conflict) |> answered(conflict)

  defp answered(choice, _conflict) when choice in ["import", "trust"], do: :ok
  defp answered(_undecided, conflict), do: {:undecided, conflict}

  defp found_waiting(:ok), do: nil
  defp found_waiting(waiting), do: waiting

  defp stripped("import", html),
    do:
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.to_tree()
      |> LazyHTML.Tree.postwalk(&without/1)
      |> LazyHTML.Tree.to_html()

  defp stripped(_kept, html), do: html

  defp without({"script", _attrs, _children}), do: []

  defp without({tag, attrs, children}),
    do: {tag, Enum.reject(attrs, fn {name, _value} -> handler?(name) end), children}

  defp without(node), do: node

  defp noted(nil, _item, _context), do: nil

  defp noted(@conflict <> ": " <> found, item, context),
    do: context |> Target.decision(item, @conflict) |> told(found)

  defp told("import", found), do: "scripts_removed: " <> found
  defp told("trust", found), do: "scripts_kept: " <> found
  defp told(_undecided, _found), do: nil
end
