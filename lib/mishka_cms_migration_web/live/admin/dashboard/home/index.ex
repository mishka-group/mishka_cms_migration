# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.Index do
  @moduledoc """
  The migration's admin page: a card for each installed source (`MishkaCmsMigration.Source.all/0`),
  and under them the runs of the admin's site, every site's for a master, as a Gervaz table (see
  `MishkaCmsMigration.MigrationRun` for its columns and row actions). The table follows the runs'
  PubSub notifications, which this page hands on to it.

  A card's New import opens the run's Gervaz form for that source in a modal: the page sends the
  form `defaults: %{source: id}`, so its Connection draws the keys that source asks for
  (`MishkaCmsMigration.Source.form_fields/1`), its secret as a masked password input, or, for a
  source that reads a file (`MishkaCmsMigration.Source.file?/1`) such as the WordPress export file,
  its Export file upload instead. Another source's New import starts the form over for it; the same
  source's opens it as the admin left it, answers and step kept, until a run starts or the admin
  presses Start over. The window is Gervaz's wizard of four steps
  (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.ImportSteps`): where from, what to bring, languages,
  and a review in plain words. Its Start the dry run, which reads "Checking the source…" while it
  runs, creates the run once the source answers, or reads the file, and starts the run's dry run at
  once, which writes nothing to the site; a run the site cannot start it for, because another run
  of the site is running, stays Connected and a warning says why. The modal then closes and the run
  shows in the table. A refusal on an earlier step returns the window there and the form's error
  flash names the step (`{:put_flash, kind, message}`).

  Every flash says what it means (`MishkaCmsMigrationWeb.Flash`): Dry run started and Import started
  are info, Run cancelled is a success, a step the run refuses is info, and a run that is not there
  is an error.

  ## A run's row

  Dry run, Run again, Import and Cancel reach this page as `{:row_action, "dry_run" | "import" |
  "cancel", %{"id" => id}}`. The page reads the run as the table does, a master's through
  `:master_get` on any site, a site admin's on their own site alone, and runs
  `MishkaCmsMigration.start_dry_run/2`, `MishkaCmsMigration.start_import/2` or
  `MishkaCmsMigration.cancel_run/2` as the signed-in admin, on the run's site. It says so in a
  flash; a run it cannot read, such as another site's id sent by hand, or a step the run refuses,
  such as a second dry run while one of the site's runs is running, is said in Gervaz's words for
  a failed row action (`MishkaGervaz.Errors.format_flash_message/2`), and nothing changes.

  Items, on a row, is a link to the run's Items page
  (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Index`).

  An expanded row (`{:expand_row, id}`) shows the run, read the same way, as
  `MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.RunDetails` draws it: where it is and when it
  got there, the warning for users an import created (`PasswordNotice`), what its last report found kind by kind and its latest items, each with links to its
  CMS record, how far a running job is, why a failed run stopped, and what its source said of
  itself and the admin chose. The page keeps which row it last expanded and draws it again on each
  of that run's notifications, so a dry run moving on, or finishing, shows in it without a reload.

  ## Logs

  Logs, beside the table's count, is the core's activity feed
  (`MishkaCmsCoreWeb.Live.Admin.Components.ActivityFeed`, as the runtime pages show theirs) over
  the runs' log alone (`MishkaCmsMigration.Activity`): each step of a run, newest first, in the
  sentence the bell says, who took it and on which site. It reads the latest entries the first
  time it opens and adds each new one as its broadcast arrives.

  Who may open it is the sidebar's declaration (`MishkaCmsMigrationWeb.SidebarMenu`), which
  `MishkaCmsCore.Sidebar.PageGuard` reads on every mount.
  """

  use MishkaCmsCore.ExtensionLiveView

  alias MishkaCmsCoreWeb.Live.Admin.Components.ActivityFeed
  alias MishkaCmsMigration.{MigrationRun, Source}
  alias MishkaCmsMigrationWeb.Flash
  alias MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.RunDetails
  alias MishkaCmsMigrationWeb.Live.Admin.Dashboard.PasswordNotice
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
     )
     |> ActivityFeed.setup(
       resources: [MigrationRun],
       sources: [MishkaCmsMigration.Activity],
       feed_id: "migration-activity"
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply, assign(socket, :url_state, UrlSync.decode(params, uri, MigrationRun))}
  end

  @impl true
  def handle_event("new_run", %{"source" => id}, socket) do
    id |> Source.fetch() |> new_run(socket)
  end

  @impl true
  def handle_info({:form_saved, :create, run}, socket),
    do: {:noreply, socket |> close_modal() |> connected(run)}

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

  def handle_info({:row_action, "import", %{"id" => id}}, socket) do
    {:noreply,
     step(
       socket,
       id,
       &MishkaCmsMigration.start_import/2,
       gettext("Import"),
       gettext("Import started.")
     )}
  end

  def handle_info({:row_action, "cancel", %{"id" => id}}, socket) do
    {:noreply,
     step(
       socket,
       id,
       &MishkaCmsMigration.cancel_run/2,
       gettext("Cancel"),
       gettext("Run cancelled."),
       :success
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
    do: {:noreply, Flash.put(socket, kind, message)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp new_run({:ok, source}, socket) do
    send_update(MishkaGervaz.Form.Web.Live,
      id: MishkaGervaz.Resource.Info.Form.component_id(MigrationRun),
      defaults: %{source: source.id()}
    )

    {:noreply, exec_modal_js(socket, MishkaCmsCore.CoreComponents.show_modal(@form_modal))}
  end

  defp new_run({:error, :not_installed}, socket),
    do: {:noreply, Flash.put(socket, :error, gettext("This source is no longer installed."))}

  defp step(socket, id, action, label, done, kind \\ :info) do
    user = socket.assigns.current_user

    with {:ok, %MigrationRun{} = run} <- MigrationRun.fetch(id, user),
         {:ok, _run} <- action.(run, actor: user, tenant: run.site_id) do
      Flash.put(socket, kind, done)
    else
      {:ok, nil} -> refused(socket, label, :not_found, :error)
      {:error, reason} -> refused(socket, label, reason, :info)
    end
  end

  # A new run starts its dry run at once: the New import window's last step says so. A run the
  # site could not start it for, such as while another of its runs is running, stays Connected, and
  # the flash says why, so the admin starts it from its row.
  defp connected(socket, run) do
    site = connected_to(run)
    user = socket.assigns.current_user

    case MishkaCmsMigration.start_dry_run(run, actor: user, tenant: run.site_id) do
      {:ok, _run} ->
        Flash.put(
          socket,
          :info,
          gettext("Connected to %{site}. The dry run started: it writes nothing to your site.",
            site: site
          )
        )

      {:error, reason} ->
        Flash.put(
          socket,
          :warning,
          gettext("Connected to %{site}, but the dry run did not start. %{reason}",
            site: site,
            reason: refusal(gettext("Dry run"), reason)
          )
        )
    end
  end

  defp refused(socket, label, reason, kind),
    do: Flash.put(socket, kind, refusal(label, reason))

  defp refusal(label, reason) do
    error = Errors.Action.Failed.exception(resource: MigrationRun, label: label, reason: reason)
    Errors.format_flash_message(error)
  end

  defp expand(socket, id) do
    user = socket.assigns.current_user
    id |> MigrationRun.fetch(user) |> expanded(user)
    assign(socket, :expanded_id, id)
  end

  defp refresh(%{assigns: %{expanded_id: id}} = socket, %{data: %{id: id}}),
    do: expand(socket, id)

  defp refresh(socket, _notification), do: socket

  defp expanded({:ok, %MigrationRun{} = run}, user),
    do:
      send_update(MishkaGervaz.Table.Web.Live,
        id: @table_id,
        expanded_html: details_html(run, user)
      )

  defp expanded({:ok, nil}, _user),
    do: send_update(MishkaGervaz.Table.Web.Live, id: @table_id, expanded_error: :not_found)

  defp expanded({:error, reason}, _user),
    do: send_update(MishkaGervaz.Table.Web.Live, id: @table_id, expanded_error: reason)

  defp details_html(run, user) do
    assigns = %{
      run: run,
      paths: RunDetails.item_paths(run, user),
      created: PasswordNotice.created(run, user)
    }

    ~H"""
    <RunDetails.panel run={@run} paths={@paths} created={@created} />
    """
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp close_modal(socket),
    do: exec_modal_js(socket, MishkaCmsCore.CoreComponents.hide_modal(@form_modal))

  defp exec_modal_js(socket, js),
    do: push_event(socket, "gervaz:exec-js", %{target: @form_modal, js: Jason.encode!(js.ops)})

  defp connected_to(%MigrationRun{extra: %{"name" => name}}) when is_binary(name) and name != "",
    do: name

  defp connected_to(%MigrationRun{source_host: host}), do: host
end
