# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Events do
  @moduledoc """
  The three `mishka_installer` events an import fires, through `MishkaInstaller.Event.Hook.call/3`.
  Each carries the run it belongs to, and `meta: %{actor: actor, site_id: site_id}` for a plugin
  that takes `call/2`. A dry run fires none of them: it writes nothing in the CMS and asks no plugin.

  ## When a plugin fails

  The two events that decide what is written fail closed. They are called with the `raised:` option
  of `MishkaInstaller.Event.Hook.call/3`, so when one of their plugins raises, or replies with
  something other than `{:reply, _}` or `{:reply, :halt, _}`, the plugins after it do not run and
  the call answers `:failed` instead of the payload. That answer, or any other that is not the
  payload, skips the item as `"plugins_failed"`. While one of an event's plugins is not loaded, so
  the event cannot run, the item is skipped as `"plugins_cannot_run"`. Either way nothing is written
  behind a plugin that would have changed or kept out the item. An event with no started plugin,
  such as one whose plugins an operator stopped, hands the payload back as it was sent: a piece
  stays unconverted and the item is written as the import made it. A plugin answers the payload it
  is handed, with all its keys.

  ## `migration:content:convert`

  Fired for each piece of an item's content the source could not convert itself
  (`MishkaCmsMigration.Source.Item`), before the item is written:

      %{
        site_id: "…", run_id: "…", source: "wordpress", source_host: "example.com",
        kind: "post", source_id: "12",
        name: "gallery", attrs: %{"ids" => "4,5"}, raw: "[gallery ids=\\"4,5\\"]",
        html: nil
      }

  A plugin that knows the piece answers with `html` set to the markup it becomes. A piece nobody
  converts is kept as text: `raw`, escaped.

  ## `migration:item:before_import`

  Fired for each item about to be written, after its content is converted:

      %{
        site_id: "…", run_id: "…", source: "wordpress", source_host: "example.com",
        outcome: :created, item: %MishkaCmsMigration.Source.Item{}, reason: nil
      }

  `outcome` is what the import will record once the item is written: `:created` for a new CMS
  record, `:updated` for one an earlier run wrote. A plugin may answer with a changed `item` (its
  `kind` and `source_id` stay as they were), or with `outcome: :skipped` and a `reason` to leave the
  item out: a plugin that writes the item itself skips it with a reason saying so. A skipped item is
  recorded as skipped, with the plugin's reason, or `"skipped by a plugin"` when it gave none. Any
  other outcome a plugin answers is not used: the import's own stands.

  ## `migration:import:finished`

  Fired once an import is done and its run is saved, with the run's report
  (`MishkaCmsMigration.Report`):

      %{
        site_id: "…", run_id: "…", source: "wordpress", source_host: "example.com",
        report: %{counts: %{created: 10, updated: 2, skipped: 1, failed: 0}, kinds: [...], entries: [...]}
      }

  What a plugin answers is not used.
  """

  alias MishkaCmsMigration.Source.Item
  alias MishkaInstaller.Event.Hook

  @convert "migration:content:convert"
  @before_import "migration:item:before_import"
  @finished "migration:import:finished"

  @typedoc "What a plugin decides for an item about to be written."
  @type decision :: {:ok, Item.t()} | {:skipped, String.t()}

  @doc """
  The event a piece of content is offered on: what a converter plugin names in
  `use MishkaInstaller.Event.Hook, event: ...`, and what a test registers one for.
  """
  @spec convert_event() :: String.t()
  def convert_event, do: @convert

  @doc """
  The event an item is offered on before it is written: what a plugin that changes or skips items
  names in `use MishkaInstaller.Event.Hook, event: ...`, and what a test registers one for.
  """
  @spec before_import_event() :: String.t()
  def before_import_event, do: @before_import

  @doc """
  The event an import's report is handed to: what a plugin that acts on a finished import names in
  `use MishkaInstaller.Event.Hook, event: ...`, and what a test registers one for.
  """
  @spec finished_event() :: String.t()
  def finished_event, do: @finished

  @doc """
  The markup a plugin converts `piece` of `item` to: `{:ok, html}`, `:unconverted` when none does,
  `:cannot_run` while one of the event's plugins is not loaded, or `:failed` when the plugins
  failed (see "When a plugin fails").
  """
  @spec convert(map(), Item.t(), map(), map() | nil) ::
          {:ok, String.t()} | :unconverted | :cannot_run | :failed
  def convert(piece, item, run, actor) do
    payload =
      Map.merge(base(run), %{
        kind: item.kind,
        source_id: item.source_id,
        name: piece.name,
        attrs: piece.attrs,
        raw: piece.raw,
        html: nil
      })

    @convert
    |> Hook.call(payload, meta: meta(run, actor), cannot_run: :cannot_run, raised: :failed)
    |> converted()
  end

  @doc """
  What the plugins decide for `item` about to be written as `outcome`: `{:ok, item}`, with the item
  as a plugin left it, or `{:skipped, reason}`.
  """
  @spec before_import(Item.t(), :created | :updated, map(), map() | nil) :: decision()
  def before_import(%Item{} = item, outcome, run, actor) do
    payload = Map.merge(base(run), %{outcome: outcome, item: item, reason: nil})

    @before_import
    |> Hook.call(payload, meta: meta(run, actor), cannot_run: :cannot_run, raised: :failed)
    |> decided(item)
  end

  @doc "Hands `report` of the finished import of `run` to the plugins."
  @spec finished(map(), map(), map() | nil) :: :ok
  def finished(report, run, actor) do
    Hook.call(@finished, Map.put(base(run), :report, report),
      meta: meta(run, actor),
      return: true
    )

    :ok
  end

  defp base(run),
    do: %{
      site_id: run.site_id,
      run_id: run.id,
      source: run.source,
      source_host: run.source_host
    }

  defp meta(run, actor), do: %{actor: actor, site_id: run.site_id}

  defp converted(:cannot_run), do: :cannot_run
  defp converted(%{html: html}) when is_binary(html), do: {:ok, html}
  defp converted(%{html: nil}), do: :unconverted
  defp converted(_failed), do: :failed

  defp decided(:cannot_run, _item), do: {:skipped, "plugins_cannot_run"}

  defp decided(%{outcome: :skipped} = answer, _item),
    do: {:skipped, reason(answer, "skipped by a plugin")}

  defp decided(%{item: %Item{} = changed}, item),
    do: {:ok, %{changed | kind: item.kind, source_id: item.source_id}}

  defp decided(_failed, _item), do: {:skipped, "plugins_failed"}

  defp reason(%{reason: reason}, _default) when is_binary(reason) and reason != "", do: reason
  defp reason(_answer, default), do: default
end
