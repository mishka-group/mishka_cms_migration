# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Events do
  @moduledoc """
  The three `mishka_installer` events an import fires, through `MishkaInstaller.Event.Hook.call/3`.
  Each carries the run it belongs to, and `meta: %{actor: actor, site_id: site_id}` for a plugin
  that takes `call/2`. A dry run fires none of them: it writes nothing and asks no plugin.

  ## When a plugin fails

  The two events that decide what is written fail closed. mishka_installer answers a chain in which
  a plugin raised with the payload as it was sent, so each payload goes out with `asked: false`,
  and this extension's own first plugin on the event, at priority 1
  (`MishkaCmsMigration.Plugins.BeforeImportGuard`, `MishkaCmsMigration.Plugins.ConvertGuard`),
  sets it to `true`. An answer still saying `asked: false` — a plugin raised, or answered something
  that is not the payload, or the guard is stopped — skips the item as `"plugins_failed"`. While
  one of an event's plugins is not loaded, so the event cannot run, the item is skipped as
  `"plugins_cannot_run"`. Either way nothing is written behind a plugin that would have changed or
  kept out the item. A plugin keeps the keys of the payload it is handed, `asked` among them.

  ## `migration:content:convert`

  Fired for each piece of an item's content the source could not convert itself
  (`MishkaCmsMigration.Item`), before the item is written:

      %{
        site_id: "…", run_id: "…", source: "wordpress", source_host: "example.com",
        kind: "post", source_id: "12",
        name: "gallery", attrs: %{"ids" => "4,5"}, raw: "[gallery ids=\\"4,5\\"]",
        html: nil, asked: true
      }

  A plugin that knows the piece answers with `html` set to the markup it becomes. A piece nobody
  converts is kept as text: `raw`, escaped.

  ## `migration:item:before_import`

  Fired for each item about to be written, after its content is converted:

      %{
        site_id: "…", run_id: "…", source: "wordpress", source_host: "example.com",
        outcome: :created, item: %MishkaCmsMigration.Item{}, decision: :import, reason: nil,
        asked: true
      }

  `outcome` is what the import will record once the item is written: `:created` for a new row,
  `:updated` for one an earlier run wrote. A plugin may answer with a changed `item` (its `kind` and
  `source_id` stay as they were), with `decision: :skip` and a `reason` to leave the item out, or
  with `decision: :take` when it wrote the item itself. A skipped or taken item is recorded as
  skipped, with the plugin's reason.

  ## `migration:import:finished`

  Fired once an import is done and its run is saved, with the run's report
  (`MishkaCmsMigration.Report`):

      %{
        site_id: "…", run_id: "…", source: "wordpress", source_host: "example.com",
        report: %{counts: %{created: 10, updated: 2, skipped: 1, failed: 0}, kinds: [...], entries: [...]}
      }

  What a plugin answers is not used.
  """

  alias MishkaCmsMigration.Item
  alias MishkaInstaller.Event.Hook

  @convert "migration:content:convert"
  @before_import "migration:item:before_import"
  @finished "migration:import:finished"

  @typedoc "What a plugin decides for an item about to be written."
  @type decision :: {:import, Item.t()} | {:skipped, String.t()}

  @doc "The event a piece of content is offered on."
  @spec convert_event() :: String.t()
  def convert_event, do: @convert

  @doc "The event an item is offered on before it is written."
  @spec before_import_event() :: String.t()
  def before_import_event, do: @before_import

  @doc "The event an import's report is handed to."
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
        html: nil,
        asked: false
      })

    case Hook.call(@convert, payload, meta: meta(run, actor), cannot_run: :cannot_run) do
      :cannot_run -> :cannot_run
      %{asked: true, html: html} when is_binary(html) -> {:ok, html}
      %{asked: true} -> :unconverted
      _failed -> :failed
    end
  end

  @doc """
  What the plugins decide for `item` about to be written as `outcome`: `{:import, item}`, with the
  item as a plugin left it, or `{:skipped, reason}`.
  """
  @spec before_import(Item.t(), :created | :updated, map(), map() | nil) :: decision()
  def before_import(%Item{} = item, outcome, run, actor) do
    payload =
      Map.merge(base(run), %{
        outcome: outcome,
        item: item,
        decision: :import,
        reason: nil,
        asked: false
      })

    @before_import
    |> Hook.call(payload, meta: meta(run, actor), cannot_run: :cannot_run)
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

  defp decided(:cannot_run, _item), do: {:skipped, "plugins_cannot_run"}
  defp decided(%{asked: true} = answer, item), do: answered(answer, item)
  defp decided(_failed, _item), do: {:skipped, "plugins_failed"}

  defp answered(%{decision: :import, item: %Item{} = changed}, item),
    do: {:import, %{changed | kind: item.kind, source_id: item.source_id}}

  defp answered(%{decision: :skip} = answer, _item),
    do: {:skipped, reason(answer, "skipped by a plugin")}

  defp answered(%{decision: :take} = answer, _item),
    do: {:skipped, reason(answer, "taken by a plugin")}

  defp answered(_answer, _item), do: {:skipped, "plugins_failed"}

  defp reason(%{reason: reason}, _default) when is_binary(reason) and reason != "", do: reason
  defp reason(_answer, default), do: default
end
