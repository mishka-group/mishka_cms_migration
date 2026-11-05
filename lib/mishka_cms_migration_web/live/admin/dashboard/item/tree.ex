# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Tree do
  @moduledoc """
  The Items table's Map view (`MishkaCmsMigration.MigrationItem`'s `switchable_templates`): a Gervaz
  table template that draws the items as the source nests them, for deciding where each part of a
  site goes before it is imported. The List view is the stock `MishkaGervaz.Table.Templates.Table`,
  and the table's template switcher moves between them.

  Each kind is a section, in the order the sources walk the kinds, its items a tree by their
  `source_parent`, siblings by title: an item under the one the source puts it under, indented, and
  a chevron on an item with children that folds them away and back (`Phoenix.LiveView.JS`). An item
  whose parent the table has not loaded, or that sits under none, is at the top of its kind, so a
  kind that does not nest, such as the tags, is a flat list, and an item in a loop of parents is
  drawn once. Each row shows its checkbox, title and source id, its Plan
  (`MishkaCmsMigration.MigrationItem.plan_cell/1`, which names the record an item is mapped to),
  and its row actions: Dry run this item and Import this item, Map to… for a category or a tag,
  Leave out and Bring back.

  The tree is drawn from the rows the table has loaded (`keep_loaded_records`), as a LiveView stream
  holds no nesting; Load more adds the next page to it. The filters, the bulk actions, the
  switcher, the states and the pagination are Gervaz's own (`MishkaGervaz.Table.Templates.Shared`).

  Every part carries a `data-role` (`item-tree`, `item-tree-kind` with `data-kind`,
  `item-tree-node` with `data-item-id`, `data-source-id` and `data-parent`, `item-tree-children`,
  `item-tree-fold`), so a test reads the tree without reading its markup.
  """

  use MishkaGervaz.Table.Behaviours.Template
  use MishkaGervaz.Messages

  import MishkaGervaz.Helpers, only: [dynamic_component: 1, accessible?: 2]

  alias MishkaCmsMigration.{MigrationItem, MigrationRun}
  alias MishkaGervaz.Table.Templates.Shared
  alias Phoenix.LiveView.JS

  @impl true
  def name, do: :item_tree

  @impl true
  def label, do: dgettext("mishka_gervaz", "Map")

  @impl true
  def icon, do: "hero-share"

  @impl true
  def description, do: dgettext("mishka_gervaz", "The items as the source nests them")

  @impl true
  def features, do: [:filter, :select, :bulk_actions, :paginate]

  @impl true
  def default_options, do: []

  @impl true
  def render(assigns) do
    %{static: static, state: state} = assigns

    assigns =
      assigns
      |> assign(:show_checkboxes, checkboxes?(static, state))
      |> assign(:show_filters, Enum.any?(static.filters, &accessible?(&1, state)))
      |> assign(:kinds, kinds(state.loaded_records))
      |> assign_new(:filter_actions, fn -> nil end)

    ~H"""
    <div id={@static.id} class="mishka-gervaz-table" data-role="item-tree">
      <Shared.render_filters
        :if={@show_filters}
        static={@static}
        state={@state}
        myself={@myself}
        filter_actions={@filter_actions}
      />
      <Shared.render_bulk_actions
        :if={@show_checkboxes}
        static={@static}
        state={@state}
        myself={@myself}
      />
      <div class="mb-[14px] flex justify-end">
        <Shared.render_template_switcher
          switchable_templates={@static.switchable_templates}
          current_template={@state.template}
          ui_adapter={@static.ui_adapter}
          myself={@myself}
        />
      </div>

      <div :if={not @empty? and not @failed?} class="grid gap-4">
        <section
          :for={{kind, nodes} <- @kinds}
          data-role="item-tree-kind"
          data-kind={kind}
          class="rounded-[16px] border border-[#ecebe6] bg-white p-2 shadow-[0_1px_2px_rgba(30,28,24,0.04)]"
        >
          <h3 class="m-0 flex items-center gap-2 px-3 pb-1 pt-2 text-[11px] font-semibold uppercase tracking-[0.05em] text-[#a8a5a0]">
            <MishkaCmsCore.CoreComponents.icon
              name={MigrationRun.kind_icon(kind)}
              class="size-[13px]"
            />
            {MigrationRun.kind_label(kind)}
          </h3>
          <ul role="tree" class="m-0 list-none p-0">
            <.render_item
              :for={node <- nodes}
              node={node}
              static={@static}
              state={@state}
              show_checkboxes={@show_checkboxes}
              myself={@myself}
            />
          </ul>
        </section>
      </div>

      <Shared.render_empty_state :if={@empty?} static={@static} state={@state} myself={@myself} />
      <Shared.render_error_state :if={@failed?} static={@static} state={@state} myself={@myself} />
      <Shared.render_pagination :if={not @failed?} static={@static} state={@state} myself={@myself} />
    </div>
    """
  end

  @doc """
  One item of the tree, `@node` (`{item, its children's nodes}`), and the items under it, drawn
  folded open.
  """
  @impl true
  def render_item(assigns) do
    {record, below} = assigns.node

    assigns =
      assign(assigns,
        record: record,
        below: below,
        dom: "item-tree-#{record.id}",
        checked: Shared.record_checked?(assigns.state, record.id),
        actions: Shared.non_accordion_actions(assigns.static.row_actions)
      )

    ~H"""
    <li
      role="treeitem"
      aria-expanded={@below != [] && "true"}
      data-role="item-tree-node"
      data-item-id={@record.id}
      data-source-id={@record.source_id}
      data-parent={@record.source_parent}
      class="min-w-0"
    >
      <div class={[
        "flex min-w-0 flex-wrap items-center gap-x-3 gap-y-2 rounded-[11px] px-3 py-2 transition-colors hover:bg-[#faf9f6]",
        @checked && "bg-[#f7f7fd]"
      ]}>
        <button
          :if={@below != []}
          type="button"
          id={"#{@dom}-fold"}
          data-role="item-tree-fold"
          aria-label={dgettext("mishka_gervaz", "Fold or unfold")}
          phx-click={
            JS.toggle(to: "##{@dom}-children")
            |> JS.toggle_class("-rotate-90", to: "##{@dom}-fold")
          }
          class="grid size-[22px] flex-none place-items-center rounded-[6px] text-[#a8a5a0] transition-transform hover:text-[#5c5a54]"
        >
          <MishkaCmsCore.CoreComponents.icon name="hero-chevron-down" class="size-[13px]" />
        </button>
        <span :if={@below == []} class="size-[22px] flex-none" aria-hidden="true"></span>
        <.dynamic_component
          :if={@show_checkboxes}
          module={@static.ui_adapter}
          function={:checkbox}
          name="select_row"
          value={@record.id}
          checked={@checked}
          class="gervaz-row-checkbox"
          phx-click="toggle_select"
          phx-value-id={@record.id}
          phx-target={@myself}
        />
        <div class="min-w-[160px] flex-1">
          <div
            data-role="item-title"
            title={@record.title}
            class="truncate text-[13px] font-semibold text-[#17161a]"
          >
            {@record.title || dgettext("mishka_gervaz", "Untitled")}
          </div>
          <div
            data-role="item-source-id"
            class="mt-[2px] font-['Space_Grotesk'] text-[11px] font-medium text-[#a8a5a0]"
          >
            {"#" <> @record.source_id}
          </div>
        </div>
        <div class="min-w-[150px] max-w-[320px]">{MigrationItem.plan_cell(@record)}</div>
        <Shared.render_row_actions
          row_actions={@actions}
          record={@record}
          static={@static}
          state={@state}
          myself={@myself}
        />
      </div>
      <ul
        :if={@below != []}
        id={"#{@dom}-children"}
        role="group"
        data-role="item-tree-children"
        class="m-0 ms-[22px] list-none border-s border-[#f0efea] p-0 ps-2"
      >
        <.render_item
          :for={node <- @below}
          node={node}
          static={@static}
          state={@state}
          show_checkboxes={@show_checkboxes}
          myself={@myself}
        />
      </ul>
    </li>
    """
  end

  defp checkboxes?(static, state),
    do:
      :select in static.features and static.bulk_actions != [] and
        Shared.has_visible_bulk_actions?(static.bulk_actions, state.archive_status)

  defp kinds(records) do
    order =
      MigrationRun.kind_options() |> Enum.map(&elem(&1, 1)) |> Enum.with_index() |> Map.new()

    records
    |> Enum.group_by(& &1.source_kind)
    |> Enum.sort_by(fn {kind, _records} -> Map.get(order, kind, map_size(order)) end)
    |> Enum.map(fn {kind, records} -> {kind, tree(records)} end)
  end

  defp tree(records) do
    records = Enum.sort_by(records, &String.downcase(&1.title || ""))
    loaded = MapSet.new(records, & &1.source_id)
    {roots, nested} = Enum.split_with(records, &root?(&1, loaded))
    children = Enum.group_by(nested, & &1.source_parent)
    {grown, seen} = grown(roots, children, MapSet.new())

    {looped, _seen} =
      records |> Enum.reject(&MapSet.member?(seen, &1.id)) |> grown(children, seen)

    grown ++ looped
  end

  defp root?(%{source_parent: nil}, _loaded), do: true
  defp root?(%{source_parent: parent}, loaded), do: not MapSet.member?(loaded, parent)

  defp grown(records, children, seen) do
    Enum.flat_map_reduce(records, seen, fn record, seen ->
      case MapSet.member?(seen, record.id) do
        true ->
          {[], seen}

        false ->
          {below, seen} =
            children
            |> Map.get(record.source_id, [])
            |> grown(children, MapSet.put(seen, record.id))

          {[{record, below}], seen}
      end
    end)
  end
end
