# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Sources.WordPress.Export do
  @moduledoc """
  A WordPress export file (WXR, what Tools ▸ Export makes) read as it streams by
  (`MishkaCmsMigration.Sources.WordPressFile`): `fold/3` hands each child of its `<channel>`, one at
  a time, to a function, and never holds more of the file than the child it is reading.

  A child is an `t:element/0`: its own text, its attributes and its children by name, each a list
  in the order the file gives them. `text/1`, `text/2`, `all/2` and `attribute/2` read it. A
  `<channel>`'s children are the site's own fields (`title`, `link`, `wp:wxr_version`, …), its
  authors (`wp:author`), categories (`wp:category`), tags (`wp:tag`) and other terms (`wp:term`),
  and its items (`item`): every post, page, file, reusable block and menu item, each with its
  `category` references, its `wp:postmeta` and its `wp:comment`s.

  The file is read with `:xmerl_sax_parser` from the disk in blocks. An export never declares a
  document type, so a file that does is refused before anything in it is read: no external entity,
  DTD or other address it names is ever fetched or opened, and no entity is expanded, so neither a
  file that names a file of the server or an address (XXE) nor one that nests entities to grow
  without end (the billion laughs) gets anywhere. The parser is told the same
  (`disallow_entities`, `external_entities: :none`). A file that is not XML, whose root is not an
  `<rss>` with a `<channel>`, or that breaks off is refused too; each is `{:error,
  :unreadable_file}`, and a file that is not there `{:error, :no_file}`.

  `php/1` reads the PHP-serialized values WordPress keeps in some meta, such as a file's sizes in
  `_wp_attachment_metadata`, without running anything: arrays, strings, numbers, booleans and
  `null`; an object, or anything else, reads as `nil`.
  """

  @options [:disallow_entities, external_entities: :none]

  @typedoc "One element of the export: its text, its attributes and its children by name."
  @type element :: %{
          text: String.t(),
          attributes: %{optional(String.t()) => String.t()},
          children: %{optional(String.t()) => [element()]}
        }

  @typedoc """
  What `fold/3`'s function answers for a child: `{:cont, acc}` to read on, `{:halt, acc}` to stop
  reading the file there.
  """
  @type step(acc) :: {:cont, acc} | {:halt, acc}

  @doc """
  Hands each child of the export's `<channel>` at `path` to `fun` with its qualified name, such as
  `"item"` or `"wp:author"`, in the order of the file, from `acc`, and answers the last `acc`.
  """
  @spec fold(Path.t(), acc, (String.t(), element(), acc -> step(acc))) ::
          {:ok, acc} | {:error, :no_file | :unreadable_file}
        when acc: term()
  def fold(path, acc, fun) when is_binary(path) do
    state = %{depth: 0, stack: [], acc: acc, fun: fun}

    path
    |> String.to_charlist()
    |> :xmerl_sax_parser.file([event_fun: &event/3, event_state: state] ++ @options)
    |> folded()
  end

  @doc "The element's own text, `\"\"` for none."
  @spec text(element()) :: String.t()
  def text(%{text: text}), do: text

  @doc "The text of the element's first child named `name`, or `nil` without one."
  @spec text(element(), String.t()) :: String.t() | nil
  def text(element, name), do: element |> all(name) |> first_text()

  @doc "The element's children named `name`, in order."
  @spec all(element(), String.t()) :: [element()]
  def all(%{children: children}, name), do: Map.get(children, name, [])

  @doc "The element's attribute `name`, or `nil`."
  @spec attribute(element(), String.t()) :: String.t() | nil
  def attribute(%{attributes: attributes}, name), do: Map.get(attributes, name)

  @doc """
  A PHP-serialized value as Elixir terms: an array whose keys are `0` to `n - 1` in order is a
  list, any other a map with string keys. `nil` for an object, or for a value that is not one whole
  serialized value.
  """
  @spec php(String.t() | nil) :: term()
  def php(value) when is_binary(value), do: value |> unserialized() |> whole()
  def php(_none), do: nil

  defp folded({:ok, %{acc: acc}, _rest}), do: {:ok, acc}
  defp folded({:halt, _location, acc, _end_tags, _state}), do: {:ok, acc}
  defp folded({:error, {_path, _no_file}}), do: {:error, :no_file}
  defp folded(_refused), do: {:error, :unreadable_file}

  defp first_text([element | _]), do: element.text
  defp first_text([]), do: nil

  defp event({:startDTD, _name, _public, _system}, _location, _state), do: refuse_dtd()
  defp event(:endDTD, _location, _state), do: refuse_dtd()

  defp event({:startElement, _uri, _local, qualified, attributes}, _location, state),
    do: started(qualified |> name() |> List.to_string(), attributes, state)

  defp event({:characters, characters}, _location, %{stack: [frame | rest]} = state),
    do: %{state | stack: [%{frame | text: [frame.text, List.to_string(characters)]} | rest]}

  defp event({:endElement, _uri, _local, _qualified}, _location, state), do: ended(state)
  defp event(_event, _location, state), do: state

  defp refuse_dtd, do: throw({:refused, ~c"an export declares no document type"})

  defp name({[], local}), do: local
  defp name({prefix, local}), do: prefix ++ [?: | local]

  defp started("rss", _attributes, %{depth: 0} = state), do: %{state | depth: 1}
  defp started("channel", _attributes, %{depth: 1} = state), do: %{state | depth: 2}

  defp started(name, attributes, %{depth: depth} = state) when depth >= 2,
    do: %{state | depth: depth + 1, stack: [frame(name, attributes) | state.stack]}

  defp started(_name, _attributes, _state), do: throw({:refused, ~c"not an rss channel"})

  defp frame(name, attributes),
    do: %{
      name: name,
      text: [],
      children: %{},
      attributes:
        Map.new(attributes, fn {_uri, prefix, local, value} ->
          {List.to_string(name({prefix, local})), List.to_string(value)}
        end)
    }

  defp ended(%{stack: [frame], depth: 3} = state),
    do: frame |> element() |> handed(frame.name, %{state | stack: [], depth: 2})

  defp ended(%{stack: [frame, parent | rest], depth: depth} = state),
    do: %{state | depth: depth - 1, stack: [child(parent, frame) | rest]}

  defp ended(%{depth: depth} = state), do: %{state | depth: depth - 1}

  defp child(parent, frame), do: frame |> element() |> added(frame.name, parent)

  defp added(element, name, parent),
    do: %{parent | children: Map.update(parent.children, name, [element], &[element | &1])}

  defp element(frame),
    do: %{
      text: IO.iodata_to_binary(frame.text),
      attributes: frame.attributes,
      children: Map.new(frame.children, fn {name, elements} -> {name, Enum.reverse(elements)} end)
    }

  defp handed(element, name, state), do: name |> state.fun.(element, state.acc) |> stepped(state)

  defp stepped({:cont, acc}, state), do: %{state | acc: acc}
  defp stepped({:halt, acc}, _state), do: throw({:halt, acc})

  defp whole({:ok, value, ""}), do: value
  defp whole(_not_whole), do: nil

  defp unserialized("N;" <> rest), do: {:ok, nil, rest}
  defp unserialized("b:0;" <> rest), do: {:ok, false, rest}
  defp unserialized("b:1;" <> rest), do: {:ok, true, rest}
  defp unserialized("i:" <> rest), do: rest |> Integer.parse() |> number()
  defp unserialized("d:" <> rest), do: rest |> Float.parse() |> number()

  defp unserialized("s:" <> rest) do
    with {size, ":\"" <> rest} when size >= 0 <- Integer.parse(rest),
         <<string::binary-size(^size), "\";", rest::binary>> <- rest do
      {:ok, string, rest}
    else
      _broken -> :error
    end
  end

  defp unserialized("a:" <> rest) do
    with {count, ":{" <> rest} when count >= 0 <- Integer.parse(rest),
         {:ok, pairs, "}" <> rest} <- pairs(rest, count, []) do
      {:ok, array(pairs), rest}
    else
      _broken -> :error
    end
  end

  defp unserialized(_other), do: :error

  defp number({value, ";" <> rest}), do: {:ok, value, rest}
  defp number(_broken), do: :error

  defp pairs(rest, 0, pairs), do: {:ok, Enum.reverse(pairs), rest}

  defp pairs(rest, count, pairs) do
    with {:ok, key, rest} when is_integer(key) or is_binary(key) <- unserialized(rest),
         {:ok, value, rest} <- unserialized(rest) do
      pairs(rest, count - 1, [{key, value} | pairs])
    else
      _broken -> :error
    end
  end

  defp array(pairs),
    do: array(pairs, Enum.map(pairs, &elem(&1, 0)) == Enum.to_list(0..(length(pairs) - 1)//1))

  defp array(pairs, true), do: Enum.map(pairs, &elem(&1, 1))
  defp array(pairs, false), do: Map.new(pairs, fn {key, value} -> {to_string(key), value} end)
end
