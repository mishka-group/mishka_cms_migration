# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Test.Plugins.FakeSource do
  @moduledoc """
  A source for the suite (`"fake"`), so a run goes end to end without WordPress. It reads its items
  from the run's own `connection` map, so each test says what the source holds and changes it for a
  second run by starting that run with other rows:

      %{"items" => %{"redirect" => [%{"id" => 1, "from" => "/old", "to" => "/new"}], "note" => [...]}}

  It signs in only with the secret `"letmein"`, lists two rows a page, and lists `"redirect"` and
  `"note"`, in that order. A row is normalized as:

    * `"id"` — the source id; `"title"`, `"modified"` — the item's title and modified time;
    * `"from"`, `"to"`, `"gate"`, `"explode"` — kept in the item's `attrs`;
    * `"content"` — the item's content pieces, as they are;
    * `"unreadable" => true` — refused by `normalize/3`.

  A connection with `"broken" => "list"` answers every `list/3` with an error, and one with
  `"broken" => "raise"` raises in it. A row that is not a map makes `normalize/3` raise.
  """

  use MishkaCmsMigration.Source, id: "fake", label: "Fake"

  @page_size 2

  @impl MishkaCmsMigration.Source
  def kinds, do: ["redirect", "note"]

  @impl MishkaCmsMigration.Source
  def connect(connection, "letmein"), do: {:ok, connection}
  def connect(_connection, _secret), do: {:error, :unauthorized}

  @impl MishkaCmsMigration.Source
  def list(%{"broken" => "list"}, _kind, _cursor), do: {:error, :source_unreachable}
  def list(%{"broken" => "raise"}, _kind, _cursor), do: raise("the source broke")

  def list(conn, kind, cursor) do
    rows = get_in(conn, ["items", kind]) || []
    offset = cursor || 0
    next = offset + @page_size

    {:ok, Enum.slice(rows, offset, @page_size), if(next < length(rows), do: next)}
  end

  @impl MishkaCmsMigration.Source
  def fetch(conn, kind, source_id) do
    case Enum.find(get_in(conn, ["items", kind]) || [], &(to_string(&1["id"]) == source_id)) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  @impl MishkaCmsMigration.Source
  def normalize(%{"unreadable" => true}, _kind, _context), do: {:error, :unreadable}

  def normalize(row, _kind, _context) do
    {:ok,
     %{
       source_id: row["id"],
       title: row["title"],
       modified_at: row["modified"],
       attrs: Map.take(row, ["from", "to", "gate", "explode"]),
       content: row["content"] || []
     }}
  end
end
