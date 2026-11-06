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

  ## Dry run this item and Import this item

  A row's Dry run this item and Import this item (`:event` row actions), Import once the admin
  confirms, are offered only while the run still holds what its source connects with
  (`MishkaCmsMigration.MigrationRun.connectable?/1`, handed to the table as the path param
  `connectable`, as Import the picked items is), and reach this page as
  `{:row_action, "dry_run_item" | "import_item", %{"id" => id}}`, and
  Import the picked items, for the rows picked with the checkboxes, as
  `{:bulk_action, :import_items, ids}`. The page reads the run again, as the Migration page reads
  it (`MishkaCmsMigration.MigrationRun.fetch/2`), and runs `MishkaCmsMigration.dry_run_items/3` or
  `MishkaCmsMigration.import_items/3` as the signed-in admin, on the run's site: the run's own job,
  for those items alone (`MishkaCmsMigration.MigrationRun`'s "Picked items"). It says so in a
  flash; a step the run refuses, such as one while a run of the site is running, is said in
  Gervaz's words for a failed action, and nothing changes. Import the picked items takes up to 100
  rows picked one by one; picking every row picks what the filters find, which it does not take,
  and the admin is asked to pick the rows. Once the job has settled the items, their rows are drawn
  again from their broadcasts.

  Dry run this item and Import this item then say what came of the item, each time it is pressed,
  in the tab it was pressed in: the item's own broadcast from the job
  (`MishkaCmsMigration.MigrationItem.picked?/1`) carries its plan or its last import, said in a
  flash as its row says it, such as "Import of Our Crew: Skipped. Its parent Our Story (#125) needs
  your decision: decide it and import it, then this one again.", an error flash for a failure. The
  page keeps only the ids it waits on, and reads nothing for it.

  ## Map to… and the Map view

  A category's or a tag's Map to…, in the List and in the Map view, shows the page's modal on the
  client and opens the item in the Gervaz form inside it (`MishkaCmsMigration.MigrationItem`'s
  form, through the table's `:edit` row action), whose choices are read from the item it loaded
  (`MishkaCmsMigration.MigrationItem.map_options/1`): the site's categories, or tags, in the
  language it leads with, and Import as its own. Save maps it (`:choose`), and the modal closes; the
  table draws the item again from its broadcast.

  ## Decide…

  An item the import cannot place safely on its own, whose plan reads Needs your decision, has
  Decide… instead of Map to…: the same modal and form, with the conflict's choices in words
  (`MishkaCmsMigration.MigrationItem.decision_options/1`) under why the item waits, such as "This
  tag was deleted in Mishka CMS after it was imported"
  (`MishkaCmsMigration.MigrationItem.decision_reason/1`). Save keeps the decision (`:choose`),
  closes the modal and says that the next dry run and import follow it.

  A cancelled run's table shows an alert between the filters and the rows
  (`MishkaCmsMigration.MigrationRun.cancelled_words/1`), from the path params `cancelled` and
  `file_source`.

  When the links an import writes may not match the site's language addresses, the head shows the
  warning that says so (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.LanguageNotice`), above the
  table that holds the main menu's Needs your decision.

  The table's template switcher moves between the List and the Map view
  (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Tree`), which draws the items as the source
  nests them, each with its plan and its row actions; the table keeps the view in the address
  (`items_template`), so a reload shows the same one. Map categories, in the head, opens the page
  in the Map view on the categories (`items_template=item_tree` and the kind filter).

  An expanded row (`{:expand_row, id}`) shows, for an item with a parent, where it sits
  (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Branch`): the item under its parents, read with
  it in one more query (`MishkaCmsMigration.MigrationItem`'s `:ancestors`), each with where it
  stands and what can be done on it there, and, for an item that waits for its parent, that it
  waits and for what. Then, for the item of a user an import created, the warning that their
  password cannot be carried over (`PasswordNotice`), and what is kept of the item as JSON: its
  stored attributes and its `extra`, the source's fields the CMS has no home for, with the value of
  anything named like a secret hidden. The item's content and its other fields are not kept, and
  the row says so.

  ## Where it sits

  The branch's buttons reach this page as events, each run as the signed-in admin on the run's
  site, on an item of the run's site and source host alone, and each said in a flash:

    * `decide_node` answers the conflict an item waits on with a choice (`:choose` with its
      `conflict`), "Decided. The next dry run and import follow your decision.";
    * `decide_branch` answers the same conflict with one choice on the branch's items that wait for
      it (`MishkaCmsMigration.MigrationItem.decide_waiting/5`), "3 items decided.", and draws the
      rows, the branch and the Decisions panel again once;
    * `import_node` imports one item, as Import this item does, and `import_branch` the branch's
      items not imported yet, parents first, as Import the picked items does; each then says what
      came of the expanded item once its job settles it;
    * `import_anyway` decides that the expanded item is imported without its parent
      (`"parent_missing"` answered with `"import"`) and imports it.

  While a row is expanded, the broadcast of any item of its branch draws the branch again, so it
  shows each item where it stands now.

  ## Decisions

  Above the table, the Decisions panel (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Decisions`)
  groups what waits for a decision and decides a group at once; the page tells it of every item's
  broadcast, so it reads the groups again. A group's decision is one update that broadcasts no item,
  so once it is done the panel tells the page (`:items_decided`), which reloads the table's rows
  once and draws the expanded branch again.

  Who may open it is the sidebar's declaration (`MishkaCmsMigrationWeb.SidebarMenu`), the Migration
  page's permission, which `MishkaCmsCore.Sidebar.PageGuard` reads on every mount.
  """

  use MishkaCmsCore.ExtensionLiveView

  alias MishkaCmsMigration.{MigrationItem, MigrationRun, Source}
  alias MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.{Branch, Decisions}
  alias MishkaCmsMigrationWeb.Live.Admin.Dashboard.{LanguageNotice, PasswordNotice}
  alias MishkaGervaz.Errors
  alias MishkaGervaz.Table.Web.UrlSync

  @table_id "migration-items-table"
  @decisions_id "migration-item-decisions"
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
    :decisions,
    :source_parent,
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
           url_state: nil,
           awaiting: %{},
           branch: nil
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
      site_id: socket.assigns.run.site_id,
      connectable: MigrationRun.connectable?(socket.assigns.run),
      cancelled: socket.assigns.run.status == :cancelled,
      file_source: Source.file?(socket.assigns.run.source)
    }

    url_state = UrlSync.decode(params, uri, MigrationItem)

    {:noreply,
     assign(socket, :url_state, Map.update!(url_state, :path_params, &Map.merge(&1, scope)))}
  end

  @impl true
  def handle_info({:expand_row, id}, socket),
    do: {:noreply, expand(socket, id)}

  def handle_info({:form_saved, :update, %MigrationItem{} = item}, socket) do
    {:noreply, socket |> close_map() |> put_flash(:info, saved_words(item))}
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
    send_update(Decisions, id: @decisions_id, refresh: true)
    {:noreply, socket |> finished(notification) |> branch_changed(notification.data)}
  end

  def handle_info({:row_action, "dry_run_item", %{"id" => id}}, socket),
    do: {:noreply, picked(socket, [id], &MishkaCmsMigration.dry_run_items/3, :dry_run)}

  def handle_info({:row_action, "import_item", %{"id" => id}}, socket),
    do: {:noreply, picked(socket, [id], &MishkaCmsMigration.import_items/3, :import)}

  def handle_info({:bulk_action, :import_items, ids}, socket) when is_list(ids),
    do: {:noreply, picked(socket, ids, &MishkaCmsMigration.import_items/3, :import_picked)}

  def handle_info({:bulk_action, :import_items, _every_row}, socket),
    do:
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext(
           "Import the picked items takes the rows you pick, not every row the filters find."
         )
       )}

  def handle_info({:put_flash, kind, message}, socket),
    do: {:noreply, put_flash(socket, kind, message)}

  def handle_info(:items_decided, socket), do: {:noreply, redrawn(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event(
        "decide_node",
        %{"id" => id, "conflict" => conflict, "choice" => choice},
        socket
      ),
      do: {:noreply, decide_node(socket, id, conflict, choice)}

  def handle_event(
        "decide_branch",
        %{"ids" => ids, "conflict" => conflict, "choice" => choice},
        socket
      ) do
    %{run: run, current_user: user} = socket.assigns

    run
    |> MigrationItem.decide_waiting(user, conflict, choice, ids: String.split(ids, ","))
    |> branch_decided(socket)
  end

  def handle_event("import_node", %{"id" => id}, socket),
    do: {:noreply, picked(socket, [id], &MishkaCmsMigration.import_items/3, :import)}

  def handle_event("import_branch", %{"ids" => ids, "item" => item_id}, socket),
    do:
      {:noreply,
       picked(
         socket,
         String.split(ids, ","),
         &MishkaCmsMigration.import_items/3,
         :import_picked,
         item_id
       )}

  def handle_event("import_anyway", %{"id" => id}, socket),
    do:
      {:noreply, socket |> decide(id, "parent_missing", "import") |> imported_anyway(socket, id)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp decide_node(socket, id, conflict, choice),
    do: socket |> decide(id, conflict, choice) |> node_decided(socket, {conflict, choice})

  defp node_decided({:ok, item}, socket, {"parent_missing", "keep"}),
    do: put_flash(socket, :info, waits_again_words(item))

  defp node_decided({:ok, item}, socket, _answer), do: put_flash(socket, :info, saved_words(item))
  defp node_decided({:error, reason}, socket, _answer), do: refused(socket, :decide, reason)

  defp waits_again_words(%MigrationItem{target_id: id}) when is_binary(id),
    do:
      gettext(
        "It waits for its parent again. What the import wrote stays where it is until the source changes it; the next import then writes it under its parent, once its parent is imported."
      )

  defp waits_again_words(_item),
    do:
      gettext(
        "It waits for its parent again: the next import writes it once its parent is imported."
      )

  defp imported_anyway({:ok, _item}, socket, id),
    do: picked(socket, [id], &MishkaCmsMigration.import_items/3, :import)

  defp imported_anyway({:error, reason}, socket, _id),
    do: refused(socket, :import_anyway, reason)

  defp decide(socket, id, conflict, choice) do
    %{run: run, current_user: user} = socket.assigns

    with {:ok, %MigrationItem{} = item} <- own_item(MigrationItem.fetch(id, user), run) do
      MishkaCmsMigration.decide_item(item, choice, %{conflict: conflict},
        actor: user,
        tenant: run.site_id
      )
    end
  end

  defp own_item({:ok, %MigrationItem{site_id: site, source_host: host} = item}, %{
         site_id: site,
         source_host: host
       }),
       do: {:ok, item}

  defp own_item({:error, error}, _run), do: {:error, error}
  defp own_item(_other, _run), do: {:error, :not_found}

  defp branch_decided({:ok, count}, socket) do
    send_update(Decisions, id: @decisions_id, refresh: true)

    {:noreply,
     socket
     |> redrawn()
     |> put_flash(:info, ngettext("%{count} item decided.", "%{count} items decided.", count))}
  end

  defp branch_decided({:error, reason}, socket), do: {:noreply, refused(socket, :decide, reason)}

  defp expand(socket, id) do
    user = socket.assigns.current_user
    id |> MigrationItem.fetch(user, [:ancestors]) |> expanded(socket)
  end

  defp branch_changed(%{assigns: %{branch: %{id: id, ids: ids}}} = socket, %{id: changed})
       when is_map_key(ids, changed),
       do: expand(socket, id)

  defp branch_changed(socket, _item), do: socket

  defp redrawn(socket) do
    send_update(MishkaGervaz.Table.Web.Live, id: @table_id, gervaz_refresh: true)
    redraw_branch(socket)
  end

  defp redraw_branch(%{assigns: %{branch: %{id: id}}} = socket), do: expand(socket, id)
  defp redraw_branch(socket), do: socket

  defp picked(socket, ids, action, step, awaited \\ nil) do
    user = socket.assigns.current_user

    with {:ok, %MigrationRun{} = run} <- MigrationRun.fetch(socket.assigns.run.id, user),
         {:ok, _run} <- action.(run, ids, actor: user, tenant: run.site_id) do
      socket |> awaiting(ids, step, awaited) |> put_flash(:info, started(step, length(ids)))
    else
      {:ok, nil} -> refused(socket, step, :not_found)
      {:error, reason} -> refused(socket, step, reason)
    end
  end

  defp awaiting(socket, [id], step, nil) when step in [:dry_run, :import],
    do: update(socket, :awaiting, &Map.put(&1, id, step))

  defp awaiting(socket, _ids, :import_picked, id) when is_binary(id),
    do: update(socket, :awaiting, &Map.put(&1, id, :import))

  defp awaiting(socket, _ids, _step, _awaited), do: socket

  defp finished(socket, notification),
    do: notification |> MigrationItem.picked?() |> finished(notification.data, socket)

  defp finished(true, %MigrationItem{id: id} = item, %{assigns: %{awaiting: awaiting}} = socket)
       when is_map_key(awaiting, id) do
    {step, awaiting} = Map.pop!(awaiting, id)
    {result, reason} = result(step, item)

    socket
    |> assign(:awaiting, awaiting)
    |> put_flash(flash_kind(result), finished_words(step, item, result, reason))
  end

  defp finished(_picked, _item, socket), do: socket

  defp result(:dry_run, item), do: {item.plan, item.plan_reason}
  defp result(:import, item), do: {item.outcome, item.reason}

  defp flash_kind(:failed), do: :error
  defp flash_kind(_result), do: :info

  defp finished_words(step, item, result, nil), do: done_words(step, item, result)

  defp finished_words(step, item, result, reason),
    do:
      done_words(step, item, result) <>
        " " <> MigrationRun.reason_label(reason, item.source_kind) <> "."

  defp done_words(:dry_run, item, plan),
    do:
      gettext("Dry run of %{title}: %{plan}.",
        title: titled(item),
        plan: MigrationItem.plan_word(plan)
      )

  defp done_words(:import, item, outcome),
    do:
      gettext("Import of %{title}: %{outcome}.",
        title: titled(item),
        outcome: MigrationRun.outcome_word(outcome)
      )

  defp titled(%MigrationItem{title: title}) when is_binary(title) and title != "", do: title
  defp titled(_item), do: gettext("the item")

  defp started(:dry_run, _one), do: gettext("Dry run of the item started.")

  defp started(_import, count),
    do:
      ngettext(
        "Import of the item started.",
        "Import of %{count} items started.",
        count
      )

  defp refused(socket, step, reason) do
    error =
      Errors.Action.Failed.exception(resource: MigrationRun, label: label(step), reason: reason)

    put_flash(socket, :error, Errors.format_flash_message(error))
  end

  defp label(:dry_run), do: gettext("Dry run this item")
  defp label(:import), do: gettext("Import this item")
  defp label(:import_picked), do: gettext("Import the picked items")
  defp label(:import_anyway), do: gettext("Import anyway")
  defp label(:decide), do: gettext("Decide")

  defp saved_words(item), do: item |> MigrationItem.conflict() |> saved_words(item)

  defp saved_words(nil, %MigrationItem{mapped_id: nil}),
    do: gettext("It will be imported as its own.")

  defp saved_words(nil, _item), do: gettext("Mapped. The import links it to that record.")

  defp saved_words(_conflict, _item),
    do: gettext("Decided. The next dry run and import follow your decision.")

  defp close_map(socket),
    do:
      push_event(socket, "gervaz:exec-js", %{
        target: @map_modal,
        js: Jason.encode!(MishkaCmsCore.CoreComponents.hide_modal(@map_modal).ops)
      })

  defp expanded({:ok, %MigrationItem{} = item}, socket) do
    html = details_html(item, path(socket, MigrationRun.items_path(socket.assigns.run)))
    send_update(MishkaGervaz.Table.Web.Live, id: @table_id, expanded_html: html)
    assign(socket, :branch, branch_of(item))
  end

  defp expanded({:ok, nil}, socket) do
    send_update(MishkaGervaz.Table.Web.Live, id: @table_id, expanded_error: :not_found)
    assign(socket, :branch, nil)
  end

  defp expanded({:error, reason}, socket) do
    send_update(MishkaGervaz.Table.Web.Live, id: @table_id, expanded_error: reason)
    assign(socket, :branch, nil)
  end

  defp branch_of(%MigrationItem{ancestors: [_ | _] = ancestors} = item),
    do: %{id: item.id, ids: Map.new([item | ancestors], &{&1.id, true})}

  defp branch_of(_item), do: nil

  defp details_html(item, list_path) do
    assigns = %{item: item, json: json(item), list_path: list_path}

    ~H"""
    <section data-role="item-details" data-item-id={@item.id} class="grid gap-3">
      <Branch.branch item={@item} list_path={@list_path} />
      <PasswordNotice.item item={@item} />
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
