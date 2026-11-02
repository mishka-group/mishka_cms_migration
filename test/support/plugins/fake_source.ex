# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Test.Plugins.FakeSource do
  @moduledoc """
  A source for the suite (`"fake"`), so a run goes end to end without WordPress. It reads its items
  from the run's own `connection` map, so each test says what the source holds and changes it for a
  second run by starting that run with other rows:

      %{"items" => %{"redirect" => [%{"id" => 1, "from" => "/old", "to" => "/new"}], "note" => [...]},
        "facts" => %{"version" => "6.5"}}

  It signs in only with the secret `"letmein"`, or with none when the connection says
  `"public" => true`, and never once the connection says `"revoked" => true` (what a test writes
  into a saved run's connection to have its source refuse a secret it took when the run was
  created), lists two rows a page, lists `"redirect"`, `"note"` and `"page"`, in that
  order, and says the connection's `"facts"` as its `extra/1`. A row is normalized as:

    * `"id"` — the source id; `"title"`, `"modified"` — the item's title and modified time;
    * `"from"`, `"to"`, `"path"`, `"gate"`, `"explode"` — the item's `attrs`;
    * `"content"` — the item's content pieces, as they are;
    * every other field — the item's `extra`, the fields the CMS has no home for;
    * `"unreadable" => true` — refused by `normalize/3`; a row that is not a map makes it raise.

  A connection with `"broken" => "list"` answers every `list/3` with an error, and one with
  `"broken" => "raise"` raises in it; `"broken" => "loop"` answers the same cursor every time and
  `"broken" => "endless"` a new one every time, with no rows.
  """

  use MishkaCmsMigration.Source, id: "fake", label: "Fake"

  @page_size 2
  @attrs ["from", "to", "path", "gate", "explode"]
  @known ["id", "title", "modified", "content", "unreadable" | @attrs]

  @impl MishkaCmsMigration.Source
  def kinds, do: ["redirect", "note", "page"]

  @impl MishkaCmsMigration.Source
  def connect(%{"revoked" => true}, _secret), do: {:error, :unauthorized}
  def connect(%{"public" => true} = connection, nil), do: {:ok, connection}
  def connect(connection, "letmein"), do: {:ok, connection}
  def connect(_connection, _secret), do: {:error, :unauthorized}

  @impl MishkaCmsMigration.Source
  def extra(conn), do: Map.get(conn, "facts", %{})

  @impl MishkaCmsMigration.Source
  def list(%{"broken" => "list"}, _kind, _cursor), do: {:error, :source_unreachable}
  def list(%{"broken" => "raise"}, _kind, _cursor), do: raise("the source broke")
  def list(%{"broken" => "loop"}, _kind, _cursor), do: {:ok, [], :same_page}
  def list(%{"broken" => "endless"}, _kind, cursor), do: {:ok, [], (cursor || 0) + 1}

  def list(conn, kind, cursor) do
    rows = get_in(conn, ["items", kind]) || []
    offset = cursor || 0

    {:ok, Enum.slice(rows, offset, @page_size), next(offset + @page_size, length(rows))}
  end

  @impl MishkaCmsMigration.Source
  def normalize(%{"unreadable" => true}, _kind, _context), do: {:error, :unreadable}

  def normalize(row, _kind, _context) do
    {:ok,
     %{
       source_id: row["id"],
       title: row["title"],
       modified_at: row["modified"],
       attrs: Map.take(row, @attrs),
       extra: Map.drop(row, @known),
       content: row["content"] || []
     }}
  end

  defp next(next, total) when next < total, do: next
  defp next(_next, _total), do: nil
end
