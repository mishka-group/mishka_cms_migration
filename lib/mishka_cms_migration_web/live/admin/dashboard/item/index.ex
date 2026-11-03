# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Index do
  @moduledoc """
  A run's Items page, `/admin/dashboard/migration/runs/:run/items`: the items the migration keeps
  of the run's source host on the run's site (`MishkaCmsMigration.MigrationItem`), as the Gervaz
  table that resource defines. It is every item of that host, whichever run met it last, each with
  what the last dry run would do with it and what the last import did, and its "Imported by this
  run" filter narrows them to the ones this run's import met last.

  The run is read as the Migration page reads it (`MishkaCmsMigration.MigrationRun.fetch/2`): a
  master's on any site, a site admin's on their own. A run the signed-in admin may not read, such
  as another site's id typed in the address, sends them back to the Migration page with a flash,
  and a site admin's table never reads another site's items. The table is scoped to the run's site
  and host by the page, as path params no filter can clear.

  ## An admin's choices

  A row's Leave out and Bring back, and the same for the rows picked with the checkboxes, leave an
  item out of every later dry run and import, or bring it back (`MishkaCmsMigration.MigrationItem`'s
  `:leave_out` and `:bring_back`); the bulk ones ask first how many they change. Picking every row
  picks what the filters find, of the run's site and source host alone. A choice is refused while a
  dry run or an import of the site is running, in Gervaz's words for a failed action. Each choice
  is broadcast, and this page hands the item's notifications on to the table, which draws the item
  again in its place, in every tab open on it.

  ## Map to… and the Map view

  A category's or a tag's Map to…, in the List and in the Map view, shows the page's modal on the
  client and opens the item in the Gervaz form inside it (`MishkaCmsMigration.MigrationItem`'s
  form, through the table's `:edit` row action), whose choices are read from the item it loaded
  (`MishkaCmsMigration.MigrationItem.map_options/1`): the site's categories, or tags, in the
  language it leads with, and Import as its own. Save maps it (`:map_to`), and the modal closes; the
  table draws the item again from its broadcast.

  The table's template switcher moves between the List and the Map view
  (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Tree`), which draws the items as the source
  nests them, each with its plan and its row actions. Map categories, in the head, opens the page
  in the Map view on the categories (`?view=map`, read when the page mounts, and the kind filter).

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
  @map_modal "migration-item-map-modal"
  @kept [
    :source_host,
    :source_kind,
    :source_id,
    :title,
    :source_slug,
    :source_modified_at,
    :content_hash,
    :target_resource,
    :target_id,
    :target_updated_at,
    :plan,
    :plan_reason,
    :outcome,
    :reason,
    :left_out,
    :mapped_id,
    :source_parent,
    :run_id,
    :inserted_at,
    :updated_at
  ]
  @secret_words ~w(password passwd secret token api_key apikey authorization)
  @hidden "[hidden]"

  @impl true
  def mount(%{"run" => id} = params, _session, socket) do
    socket = assign_new(socket, :current_user, fn -> nil end)

    case MigrationRun.fetch(id, socket.assigns.current_user) do
      {:ok, %MigrationRun{} = run} ->
        {:ok,
         assign(socket,
           page_title: gettext("Items"),
           run: run,
           source: Source.label(run.source),
           url_state: nil,
           template: template(params)
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
    id |> MigrationItem.fetch(socket.assigns.current_user) |> expanded()
    {:noreply, socket}
  end

  def handle_info({:form_saved, :update, %MigrationItem{} = item}, socket) do
    {:noreply, socket |> close_map() |> put_flash(:info, mapped_words(item))}
  end

  def handle_info({:form_cancelled, _resource}, socket), do: {:noreply, close_map(socket)}

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "migration_item" <> _rest,
          payload: %Ash.Notifier.Notification{} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live, id: @table_id, pubsub_notification: notification)
    {:noreply, socket}
  end

  def handle_info({:put_flash, kind, message}, socket),
    do: {:noreply, put_flash(socket, kind, message)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp template(%{"view" => "map"}), do: :item_tree
  defp template(_params), do: nil

  defp mapped_words(%MigrationItem{mapped_id: nil}),
    do: gettext("It will be imported as its own.")

  defp mapped_words(_item), do: gettext("Mapped. The import links it to that record.")

  defp close_map(socket),
    do:
      push_event(socket, "gervaz:exec-js", %{
        target: @map_modal,
        js: Jason.encode!(MishkaCmsCore.CoreComponents.hide_modal(@map_modal).ops)
      })

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
