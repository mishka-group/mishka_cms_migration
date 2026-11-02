# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Events do
  @moduledoc """
  The three `mishka_installer` events an import fires, through `MishkaInstaller.Event.Hook.call/3`.
  Each carries the run it belongs to, and `meta: %{actor: actor, site_id: site_id}` for a plugin
  that takes `call/2`. A dry run fires none of them: it writes nothing and asks no plugin.

  ## `migration:content:convert`

  Fired for each piece of an item's content the source could not convert itself
  (`MishkaCmsMigration.Item`), before the item is written:

      %{
        site_id: "…", run_id: "…", source: "wordpress", source_host: "example.com",
        kind: "post", source_id: "12",
        name: "gallery", attrs: %{"ids" => "4,5"}, raw: "[gallery ids=\\"4,5\\"]",
        html: nil
      }

  A plugin that knows the piece answers with `html` set to the markup it becomes. A piece nobody
  converts is kept as text: `raw`, escaped. While one of the event's plugins is not loaded, so the
  event cannot run, the item is skipped with `"plugins_cannot_run"` rather than written without the
  conversion that plugin would have made.

  ## `migration:item:before_import`

  Fired for each item about to be written, after its content is converted:

      %{
        site_id: "…", run_id: "…", source: "wordpress", source_host: "example.com",
        outcome: :created, item: %MishkaCmsMigration.Item{}, decision: :import, reason: nil
      }

  `outcome` is what the import will record once the item is written: `:created` for a new row,
  `:updated` for one an earlier run wrote. A plugin may answer with a changed `item` (its `kind` and
  `source_id` stay as they were), with `decision: :skip` and a `reason` to leave the item out, or
  with `decision: :take` when it wrote the item itself. A skipped or taken item is recorded as
  skipped, with the plugin's reason. An answer of any other shape imports the item as it was.
  While one of the event's plugins is not loaded, so the event cannot run, every item is skipped
  with `"plugins_cannot_run"` rather than written behind a plugin that would have kept it out.

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
  or `:cannot_run` while one of the event's plugins is not loaded.
  """
  @spec convert(map(), Item.t(), map(), map() | nil) ::
          {:ok, String.t()} | :unconverted | :cannot_run
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

    case Hook.call(@convert, payload, meta: meta(run, actor), cannot_run: :cannot_run) do
      :cannot_run -> :cannot_run
      %{html: html} when is_binary(html) -> {:ok, html}
      _unconverted -> :unconverted
    end
  end

  @doc """
  What the plugins decide for `item` about to be written as `outcome`: `{:import, item}`, with the
  item as a plugin left it, or `{:skipped, reason}`.
  """
  @spec before_import(Item.t(), :created | :updated, map(), map() | nil) :: decision()
  def before_import(%Item{} = item, outcome, run, actor) do
    payload =
      Map.merge(base(run), %{outcome: outcome, item: item, decision: :import, reason: nil})

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

  defp decided(%{decision: :import, item: %Item{} = changed}, item),
    do: {:import, %{changed | kind: item.kind, source_id: item.source_id}}

  defp decided(%{decision: :skip} = answer, _item),
    do: {:skipped, reason(answer, "skipped by a plugin")}

  defp decided(%{decision: :take} = answer, _item),
    do: {:skipped, reason(answer, "taken by a plugin")}

  defp decided(:cannot_run, _item), do: {:skipped, "plugins_cannot_run"}
  defp decided(_answer, item), do: {:import, item}

  defp reason(%{reason: reason}, _default) when is_binary(reason) and reason != "", do: reason
  defp reason(_answer, default), do: default
end
