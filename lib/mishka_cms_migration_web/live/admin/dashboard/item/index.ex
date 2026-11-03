# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Index do
  @moduledoc """
  A run's Items page, `/admin/dashboard/migration/runs/:run/items`: the items the migration keeps
  of the run's source host on the run's site (`MishkaCmsMigration.MigrationItem`), as the Gervaz
  table that resource defines. It is every item of that host, whichever run met it last, and its
  "Only this run's" filter narrows them to the ones this run met last.

  The run is read as the Migration page reads it (`MishkaCmsMigration.MigrationRun.fetch/2`): a
  master's on any site, a site admin's on their own. A run the signed-in admin may not read, such
  as another site's id typed in the address, sends them back to the Migration page with a flash,
  and a site admin's table never reads another site's items. The table is scoped to the run's site
  and host by the page, as path params no filter can clear.

  An expanded row (`{:expand_row, id}`) shows what is kept of the item as JSON: its stored
  attributes and its `extra`, the source's fields the CMS has no home for, with the value of
  anything named like a secret hidden. The item's content and its other fields are not kept, and
  the row says so.

  Who may open it is the sidebar's declaration (`MishkaCmsMigrationWeb.SidebarMenu`), the Migration
  page's permission, which `MishkaCmsCore.Sidebar.PageGuard` reads on every mount.
  """

  use MishkaCmsCore.ExtensionLiveView

  alias MishkaCmsMigration.{MigrationItem, MigrationRun, Source}
  alias MishkaGervaz.Table.Web.UrlSync

  @table_id "migration-items-table"
  @kept [
    :source_host,
    :source_kind,
    :source_id,
    :title,
    :source_modified_at,
    :content_hash,
    :target_resource,
    :target_id,
    :target_updated_at,
    :outcome,
    :reason,
    :run_id,
    :inserted_at,
    :updated_at
  ]
  @secret_words ~w(password passwd secret token api_key apikey authorization)
  @hidden "[hidden]"

  @impl true
  def mount(%{"run" => id}, _session, socket) do
    socket = assign_new(socket, :current_user, fn -> nil end)

    case MigrationRun.fetch(id, socket.assigns.current_user) do
      {:ok, %MigrationRun{} = run} ->
        {:ok,
         assign(socket,
           page_title: gettext("Items"),
           run: run,
           source: Source.label(run.source),
           url_state: nil
         )}

      _unreadable ->
        {:ok,
         socket
         |> put_flash(:error, gettext("That run is not there."))
         |> push_navigate(to: path(socket, "/admin/dashboard/migration"))}
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    scope = %{
      run: socket.assigns.run.id,
      source_host: socket.assigns.run.source_host,
      site_id: socket.assigns.run.site_id
    }

    url_state = UrlSync.decode(params, uri, MigrationItem)

    {:noreply,
     assign(socket, :url_state, Map.update!(url_state, :path_params, &Map.merge(&1, scope)))}
  end

  @impl true
  def handle_info({:expand_row, id}, socket) do
    id |> read_item(socket.assigns.current_user) |> expanded()
    {:noreply, socket}
  end

  def handle_info({:put_flash, kind, message}, socket),
    do: {:noreply, put_flash(socket, kind, message)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp read_item(id, %{site_id: nil} = user),
    do: Ash.get(MigrationItem, id, action: :master_get, actor: user, not_found_error?: false)

  defp read_item(id, %{site_id: site_id} = user),
    do: Ash.get(MigrationItem, id, actor: user, tenant: site_id, not_found_error?: false)

  defp expanded({:ok, %MigrationItem{} = item}),
    do: send_update(MishkaGervaz.Table.Web.Live, id: @table_id, expanded_html: details_html(item))

  defp expanded({:ok, nil}),
    do: send_update(MishkaGervaz.Table.Web.Live, id: @table_id, expanded_error: :not_found)

  defp expanded({:error, reason}),
    do: send_update(MishkaGervaz.Table.Web.Live, id: @table_id, expanded_error: reason)

  defp details_html(item) do
    assigns = %{item: item, json: json(item)}

    ~H"""
    <section data-role="item-details" data-item-id={@item.id} class="grid gap-3">
      <p data-role="item-details-note" class="m-0 text-[12px] font-medium text-[#7c7a75]">
        {gettext(
          "This is what the migration keeps of the item. Its content and its other fields, such as a post's slug, status and author, are read from the source again by each run."
        )}
      </p>
      <pre
        data-role="item-json"
        class="m-0 max-h-[360px] overflow-auto rounded-[12px] border border-[#ecebe6] bg-[#faf9f6] p-4 font-mono text-[12px] leading-[1.55] text-[#3a382f]"
      >{@json}</pre>
    </section>
    """
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp json(item),
    do:
      item
      |> Map.take(@kept)
      |> Map.put(:extra, hidden(item.extra))
      |> Jason.encode!(pretty: true)

  defp hidden(%{} = map), do: Map.new(map, &screened/1)
  defp hidden(list) when is_list(list), do: Enum.map(list, &hidden/1)
  defp hidden(value), do: value

  defp screened({key, value}) when value in [nil, ""], do: {key, value}

  defp screened({key, value}) do
    name = key |> to_string() |> String.downcase()

    case Enum.any?(@secret_words, &String.contains?(name, &1)) do
      true -> {key, @hidden}
      false -> {key, hidden(value)}
    end
  end
end
