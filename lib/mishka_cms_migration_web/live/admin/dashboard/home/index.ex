# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.Index do
  @moduledoc """
  The migration's admin page: a card for each installed source (`MishkaCmsMigration.Source.all/0`),
  and under them the runs of the admin's site, every site's for a master, as a Gervaz table (see
  `MishkaCmsMigration.MigrationRun` for its columns and row actions). The table follows the runs'
  PubSub notifications, which this page hands on to it.

  A card's New import opens the run's Gervaz form for that source in a modal. Its Check connection
  creates the run once the source answers; the modal then closes and the run shows in the table.

  ## A run's row

  Dry run, Run again and Cancel reach this page as `{:row_action, "dry_run" | "cancel", %{"id" =>
  id}}`. The page reads the run as the table does, a master's through `:master_get` on any site, a
  site admin's on their own site alone, and runs `MishkaCmsMigration.start_dry_run/2` or
  `MishkaCmsMigration.cancel_run/2` as the signed-in admin, on the run's site. It says so in a
  flash; a run it cannot read, such as another site's id sent by hand, or a step the run refuses,
  such as a second dry run while one of the site's runs is running, is said in Gervaz's words for
  a failed row action (`MishkaGervaz.Errors.format_flash_message/2`), and nothing changes.

  An expanded row (`{:expand_row, id}`) shows the run's last report, kind by kind, read the same
  way. The page keeps which row it last expanded and draws it again on each of that run's
  notifications, so a dry run that finishes fills it in without a reload.

  Who may open it is the sidebar's declaration (`MishkaCmsMigrationWeb.SidebarMenu`), which
  `MishkaCmsCore.Sidebar.PageGuard` reads on every mount.
  """

  use MishkaCmsCore.ExtensionLiveView

  alias MishkaCmsMigration.{MigrationRun, Report, Source}
  alias MishkaGervaz.Errors
  alias MishkaGervaz.Table.Web.UrlSync

  @table_id "migration-runs-table"
  @form_modal "migration-run-form-modal"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_new(:current_user, fn -> nil end)
     |> assign(
       page_title: gettext("Migration"),
       url_state: nil,
       sources: Source.all(),
       expanded_id: nil
     )}
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

  def handle_info({:row_action, "dry_run", %{"id" => id}}, socket) do
    {:noreply,
     step(
       socket,
       id,
       &MishkaCmsMigration.start_dry_run/2,
       gettext("Dry run"),
       gettext("Dry run started.")
     )}
  end

  def handle_info({:row_action, "cancel", %{"id" => id}}, socket) do
    {:noreply,
     step(
       socket,
       id,
       &MishkaCmsMigration.cancel_run/2,
       gettext("Cancel"),
       gettext("Run cancelled.")
     )}
  end

  def handle_info({:expand_row, id}, socket), do: {:noreply, expand(socket, id)}

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "migration_run" <> _rest,
          payload: %Ash.Notifier.Notification{} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live, id: @table_id, pubsub_notification: notification)
    {:noreply, refresh(socket, notification)}
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

  defp step(socket, id, action, label, done) do
    user = socket.assigns.current_user

    with {:ok, %MigrationRun{} = run} <- read_run(id, user),
         {:ok, _run} <- action.(run, actor: user, tenant: run.site_id) do
      put_flash(socket, :info, done)
    else
      {:ok, nil} -> refused(socket, label, :not_found)
      {:error, reason} -> refused(socket, label, reason)
    end
  end

  defp refused(socket, label, reason) do
    error = Errors.Action.Failed.exception(resource: MigrationRun, label: label, reason: reason)
    put_flash(socket, :error, Errors.format_flash_message(error))
  end

  defp read_run(id, %{site_id: nil} = user),
    do: Ash.get(MigrationRun, id, action: :master_get, actor: user, not_found_error?: false)

  defp read_run(id, %{site_id: site_id} = user),
    do: MishkaCmsMigration.get_run(id, actor: user, tenant: site_id, not_found_error?: false)

  defp expand(socket, id) do
    id |> read_run(socket.assigns.current_user) |> expanded()
    assign(socket, :expanded_id, id)
  end

  defp refresh(%{assigns: %{expanded_id: id}} = socket, %{data: %{id: id}}),
    do: expand(socket, id)

  defp refresh(socket, _notification), do: socket

  defp expanded({:ok, %MigrationRun{report: report}}),
    do:
      send_update(MishkaGervaz.Table.Web.Live, id: @table_id, expanded_html: report_html(report))

  defp expanded({:ok, nil}),
    do: send_update(MishkaGervaz.Table.Web.Live, id: @table_id, expanded_error: :not_found)

  defp expanded({:error, reason}),
    do: send_update(MishkaGervaz.Table.Web.Live, id: @table_id, expanded_error: reason)

  defp report_html(report) do
    assigns = found(report)

    ~H"""
    <div data-role="run-report" class="grid gap-[8px]">
      <div
        :if={@note}
        data-role="run-report-note"
        class="text-[13px] font-medium text-[#8a877f]"
      >
        {@note}
      </div>
      <div
        :for={kind <- @kinds}
        data-role="run-report-kind"
        data-kind={kind.kind}
        class="grid grid-cols-[minmax(110px,0.7fr)_minmax(90px,0.5fr)_minmax(240px,2fr)] items-baseline gap-x-4 gap-y-1 rounded-[10px] border border-[#ecebe6] bg-white px-[14px] py-[10px] max-[640px]:grid-cols-1!"
      >
        <span class="text-[13px] font-semibold text-[#17161a]">{kind.label}</span>
        <span
          data-role="run-report-found"
          class="font-['Space_Grotesk'] text-[12.5px] font-semibold text-[#3a382f]"
        >
          {kind.found}
        </span>
        <div class="min-w-0">
          <div data-role="run-report-outcomes" class="text-[12.5px] font-medium text-[#3a382f]">
            {kind.outcomes}
          </div>
          <div
            :for={reason <- kind.reasons}
            data-role="run-report-reason"
            class="mt-[2px] text-[11.5px] font-medium text-[#8a877f]"
          >
            {gettext("Skipped: %{reason}", reason: reason)}
          </div>
        </div>
      </div>
    </div>
    """
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp found(%{kinds: [_ | _] = kinds, entries: entries}),
    do: %{note: nil, kinds: Enum.map(kinds, &kind_found(&1, entries))}

  defp found(%{kinds: []}), do: %{note: gettext("The source listed nothing to move."), kinds: []}
  defp found(_no_report), do: %{note: gettext("No dry run yet."), kinds: []}

  defp kind_found(%{kind: kind} = counts, entries) do
    %{
      kind: kind,
      label: MigrationRun.kind_label(kind),
      found:
        gettext("%{count} found",
          count:
            counts
            |> Map.take(Report.outcomes())
            |> Map.values()
            |> Enum.sum()
            |> MishkaCmsCore.Localized.number()
        ),
      outcomes: MigrationRun.result_summary(%{counts: counts}),
      reasons: skipped_reasons(entries, kind)
    }
  end

  defp skipped_reasons(entries, kind) do
    for %{kind: ^kind, outcome: :skipped, reason: reason} when is_binary(reason) <- entries,
        uniq: true,
        do: MigrationRun.reason_label(reason)
  end

  defp close_modal(socket),
    do: exec_modal_js(socket, MishkaCmsCore.CoreComponents.hide_modal(@form_modal))

  defp exec_modal_js(socket, js),
    do: push_event(socket, "gervaz:exec-js", %{target: @form_modal, js: Jason.encode!(js.ops)})

  defp connected_to(%MigrationRun{extra: %{"name" => name}}) when is_binary(name) and name != "",
    do: name

  defp connected_to(%MigrationRun{source_host: host}), do: host
end
