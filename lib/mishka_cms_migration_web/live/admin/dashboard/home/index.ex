# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.Index do
  @moduledoc """
  The migration's admin page: a card for each installed source (`MishkaCmsMigration.Source.all/0`),
  and under them the runs of the admin's site, every site's for a master, as a Gervaz table (see
  `MishkaCmsMigration.MigrationRun` for its columns). The table follows the runs' PubSub
  notifications, which this page hands on to it.

  A card's New import opens the run's Gervaz form for that source in a modal. Its Check connection
  creates the run once the source answers; the modal then closes and the run shows in the table.

  Who may open it is the sidebar's declaration (`MishkaCmsMigrationWeb.SidebarMenu`), which
  `MishkaCmsCore.Sidebar.PageGuard` reads on every mount.
  """

  use MishkaCmsCore.ExtensionLiveView

  alias MishkaCmsMigration.{MigrationRun, Source}
  alias MishkaGervaz.Table.Web.UrlSync

  @table_id "migration-runs-table"
  @form_modal "migration-run-form-modal"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_new(:current_user, fn -> nil end)
     |> assign(page_title: gettext("Migration"), url_state: nil, sources: Source.all())}
  end

  @impl true
  def handle_params(params, uri, socket),
    do: {:noreply, assign(socket, :url_state, UrlSync.decode(params, uri, MigrationRun))}

  @impl true
  def handle_event("new_run", %{"source" => id}, socket) do
    id |> Source.fetch() |> new_run(socket)
  end

  @impl true
  def handle_info({:form_saved, :create, run}, socket) do
    {:noreply,
     socket
     |> close_modal()
     |> put_flash(:info, gettext("Connected to %{site}.", site: connected_to(run)))}
  end

  def handle_info({:form_cancelled, _resource}, socket), do: {:noreply, close_modal(socket)}

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "migration_run" <> _rest,
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

  defp new_run({:ok, source}, socket) do
    send_update(MishkaGervaz.Form.Web.Live,
      id: MishkaGervaz.Resource.Info.Form.component_id(MigrationRun),
      defaults: %{source: source.id()},
      reset: true
    )

    {:noreply, exec_modal_js(socket, MishkaCmsCore.CoreComponents.show_modal(@form_modal))}
  end

  defp new_run({:error, :not_installed}, socket),
    do: {:noreply, put_flash(socket, :error, gettext("This source is no longer installed."))}

  defp close_modal(socket),
    do: exec_modal_js(socket, MishkaCmsCore.CoreComponents.hide_modal(@form_modal))

  defp exec_modal_js(socket, js),
    do: push_event(socket, "gervaz:exec-js", %{target: @form_modal, js: Jason.encode!(js.ops)})

  defp connected_to(%MigrationRun{extra: %{"name" => name}}) when is_binary(name) and name != "",
    do: name

  defp connected_to(%MigrationRun{source_host: host}), do: host
end
