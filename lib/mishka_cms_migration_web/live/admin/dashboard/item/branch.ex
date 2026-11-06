# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Branch do
  @moduledoc """
  Where an item sits at the source, drawn in its expanded row on the Items page
  (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Index`): the item under its parents
  (`MishkaCmsMigration.MigrationItem`'s `:ancestors`), the top one first, each with where it stands
  (`MishkaCmsMigration.MigrationItem.standing/1`): Needs your decision, Not imported yet, Imported,
  Connected, Left out by you or Not in the source. An item with no parent draws nothing.

  An item that waits for its parent (`MishkaCmsMigration.MigrationItem.waits_for_parent/1`) says so
  first, with what holds it in its row's words, such as "Its parent Team (#25) needs your decision:
  decide it and import it, then this one again."

  Each item of the branch has what can be done on it there, as buttons the page answers:

    * the choices of the decision it waits for (`decide_node`, with its id, conflict and choice),
      the recommended one first (`MishkaCmsMigration.MigrationItem.choice_options/1`);
    * Import it (`import_node`), for one not imported yet, once the admin confirms;
    * Show in the list, which narrows the table to it by its title and kind (`JS.patch/1`).

  And for the branch as a whole:

    * Decide all N: one choice for every item of the branch that waits for the same decision
      (`decide_branch`, with their ids), once the admin confirms;
    * Import the branch (`import_branch`): every item of it not imported yet, parents first, as a
      job of picked items walks them, offered once nothing in it waits for a decision;
    * Import anyway (`import_anyway`), for the item that waits for its parent: written now without
      it, at the top level (a page keeps its own address), once the admin confirms; Wait for its
      parent instead (`decide_node` on `"parent_missing"` with `"keep"`) takes that back.

  Every part carries a `data-role` (`item-branch`, `item-branch-node` with `data-source-id` and
  `data-standing`, `item-branch-decide`, `item-branch-import`, `item-branch-show`,
  `item-branch-decide-all`, `item-branch-import-all`, `item-branch-import-anyway`), so a test reads
  it without reading its markup.
  """

  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsMigration.{MigrationItem, MigrationRun}
  alias MishkaCmsMigration.Workers.Helpers.Needs
  alias Phoenix.LiveView.JS

  attr :item, MigrationItem, required: true, doc: "the expanded item, with its `:ancestors`"
  attr :list_path, :string, required: true, doc: "the Items page's address, to show an item in"

  @doc "Where `@item` sits and what can be done on its branch, or nothing for an item with no parent."
  def branch(%{item: %{ancestors: [_ | _] = ancestors} = item} = assigns) do
    nodes = ancestors ++ [item]
    waiting = Enum.filter(nodes, &(MigrationItem.standing(&1) == :undecided))
    importable = Enum.filter(nodes, &(MigrationItem.standing(&1) == :not_imported))

    assigns =
      assign(assigns,
        nodes: Enum.with_index(nodes),
        waits: MigrationItem.waits_for_parent(item),
        decide_all: decide_all(waiting),
        import_all: import_all(nodes, waiting, importable),
        parent: Needs.parent_name(List.last(ancestors), item.source_parent),
        without_parent: MigrationItem.without_parent?(item.decisions)
      )

    ~H"""
    <section
      data-role="item-branch"
      data-item-id={@item.id}
      data-waits={@waits && "true"}
      class={[
        "grid gap-3 rounded-[12px] border p-4",
        if(@waits, do: "border-[#f3e2b8] bg-[#fffaf0]", else: "border-[#ecebe6] bg-white")
      ]}
    >
      <div>
        <h4 class="m-0 flex items-center gap-2 text-[13px] font-bold text-[#1b1a18]">
          <MishkaCmsCore.CoreComponents.icon
            name={if(@waits, do: "hero-pause-circle", else: "hero-share")}
            class={if(@waits, do: "size-[15px] text-[#8a5a00]", else: "size-[15px] text-[#5b57d6]")}
          />
          {title(@waits, @item)}
        </h4>
        <p
          :if={@waits}
          data-role="item-branch-waits"
          class="m-0 mt-1 text-[12.5px] font-medium text-[#6d5413]"
        >
          {MigrationRun.reason_label(@waits, @item.source_kind)}.
        </p>
      </div>

      <ul role="tree" class="m-0 grid list-none gap-1 p-0">
        <li
          :for={{node, depth} <- @nodes}
          role="treeitem"
          data-role="item-branch-node"
          data-item-id={node.id}
          data-source-id={node.source_id}
          data-standing={MigrationItem.standing(node)}
          style={"padding-inline-start: #{depth * 20}px"}
          class="min-w-0"
        >
          <div class="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-2 rounded-[10px] px-2 py-[6px] hover:bg-[#faf9f6]">
            <span :if={depth > 0} class="text-[#c9c6bf]" aria-hidden="true">└</span>
            <span class="min-w-[140px] flex-1 truncate text-[13px] font-semibold text-[#17161a]">
              {node.title || gettext("Untitled")}
              <span class="ms-1 font-['Space_Grotesk'] text-[11px] font-medium text-[#a8a5a0]">
                {"#" <> node.source_id}
              </span>
              <span
                :if={node.id == @item.id}
                class="ms-1 text-[11px] font-semibold text-[#8a877f]"
              >
                {gettext("(this item)")}
              </span>
            </span>
            <.standing node={node} />
            <div class="flex flex-wrap items-center gap-1.5">
              <.node_actions node={node} item={@item} list_path={@list_path} />
            </div>
          </div>
          <p
            :if={MigrationItem.standing(node) == :not_listed}
            class="m-0 ms-6 text-[11.5px] font-medium text-[#a8a5a0]"
          >
            {gettext("The source does not list it, such as a page in the trash.")}
          </p>
        </li>
      </ul>

      <div
        :if={@decide_all || @import_all || @waits || @without_parent}
        class="flex flex-wrap items-center gap-2 border-t border-[#f0efea] pt-3"
      >
        <%= if @decide_all do %>
          <span class="text-[12px] font-semibold text-[#5c5a54]">
            {ngettext(
              "Decide the item that waits:",
              "Decide all %{count} that wait the same way:",
              length(@decide_all.ids)
            )}
          </span>
          <button
            :for={{word, choice} <- MigrationItem.choice_options(@decide_all.conflict)}
            type="button"
            data-role="item-branch-decide-all"
            data-choice={choice}
            phx-click="decide_branch"
            phx-value-ids={Enum.join(@decide_all.ids, ",")}
            phx-value-conflict={@decide_all.conflict}
            phx-value-choice={choice}
            data-confirm={
              ngettext(
                "Answer this item with “%{choice}”? It holds for every later dry run and import.",
                "Answer these %{count} items with “%{choice}”? It holds for every later dry run and import.",
                length(@decide_all.ids),
                choice: word
              )
            }
            class={button_class(:primary)}
          >
            {word}
          </button>
        <% end %>
        <button
          :if={@import_all}
          type="button"
          data-role="item-branch-import-all"
          phx-click="import_branch"
          phx-value-ids={Enum.join(Enum.map(@import_all, & &1.id), ",")}
          phx-value-item={@item.id}
          data-confirm={
            gettext("Import these %{count} items now, parents first: %{titles}?",
              count: length(@import_all),
              titles: Enum.map_join(@import_all, ", ", &(&1.title || "#" <> &1.source_id))
            )
          }
          class={button_class(:primary)}
        >
          <MishkaCmsCore.CoreComponents.icon name="hero-arrow-down-tray" class="size-[13px]" />
          {gettext("Import the branch, parents first")}
        </button>
        <button
          :if={@waits && not @without_parent && MigrationItem.standing(@item) == :not_imported}
          type="button"
          data-role="item-branch-import-anyway"
          phx-click="import_anyway"
          phx-value-id={@item.id}
          data-confirm={
            gettext(
              "Import %{title} now, without waiting for %{parent}? It is written at the top level, not under its parent (a page keeps its own address), and later imports keep it so until you choose Wait for its parent.",
              title: @item.title || "#" <> @item.source_id,
              parent: @parent
            )
          }
          class={button_class(:secondary)}
        >
          {gettext("Import anyway, without its parent")}
        </button>
        <span
          :if={@without_parent}
          data-role="item-branch-without-parent"
          class="text-[12px] font-medium text-[#5c5a54]"
        >
          {gettext("You decided to import it without its parent.")}
        </span>
        <button
          :if={@without_parent}
          type="button"
          data-role="item-branch-wait"
          phx-click="decide_node"
          phx-value-id={@item.id}
          phx-value-conflict="parent_missing"
          phx-value-choice="keep"
          data-confirm={wait_words(@item)}
          class={button_class(:secondary)}
        >
          {gettext("Wait for its parent instead")}
        </button>
      </div>
    </section>
    """
  end

  def branch(assigns), do: ~H""

  attr :node, :map, required: true

  defp standing(assigns) do
    assigns = assign(assigns, :standing, MigrationItem.standing(assigns.node))

    ~H"""
    <span class={[
      "inline-flex w-fit items-center gap-[5px] rounded-[20px] px-[10px] py-[3px] text-[10px] font-bold whitespace-nowrap",
      standing_class(@standing)
    ]}>
      {MigrationItem.standing_word(@standing)}
    </span>
    """
  end

  attr :node, :map, required: true
  attr :item, :map, required: true
  attr :list_path, :string, required: true

  defp node_actions(%{node: %{id: nil}} = assigns), do: ~H""

  defp node_actions(assigns) do
    standing = MigrationItem.standing(assigns.node)

    assigns =
      assign(assigns,
        standing: standing,
        conflict: standing == :undecided && MigrationItem.conflict(assigns.node)
      )

    ~H"""
    <button
      :for={{word, choice} <- (@conflict && MigrationItem.choice_options(@conflict)) || []}
      type="button"
      data-role="item-branch-decide"
      data-choice={choice}
      phx-click="decide_node"
      phx-value-id={@node.id}
      phx-value-conflict={@conflict}
      phx-value-choice={choice}
      class={button_class(:choice)}
    >
      {word}
    </button>
    <button
      :if={@standing == :not_imported}
      type="button"
      data-role="item-branch-import"
      phx-click="import_node"
      phx-value-id={@node.id}
      data-confirm={
        gettext("Import %{title} now? It writes this item alone into the CMS.",
          title: @node.title || "#" <> @node.source_id
        )
      }
      class={button_class(:choice)}
    >
      {gettext("Import it")}
    </button>
    <button
      :if={@node.id != @item.id}
      type="button"
      data-role="item-branch-show"
      phx-click={JS.patch(shown(@list_path, @node))}
      class={button_class(:link)}
    >
      {gettext("Show in the list")}
    </button>
    """
  end

  defp title(nil, item),
    do: gettext("Where this %{kind} sits", kind: MigrationRun.kind_one(item.source_kind))

  defp title(_waits, item),
    do:
      gettext("This %{kind} waits for its parent", kind: MigrationRun.kind_one(item.source_kind))

  defp wait_words(%{target_id: id} = item) when is_binary(id),
    do:
      gettext(
        "Wait for its parent instead? %{title} stays where the import wrote it until the source changes it; the next import then writes it under its parent, once its parent is imported.",
        title: item.title || "#" <> item.source_id
      )

  defp wait_words(item),
    do:
      gettext(
        "Wait for its parent instead? The next import writes %{title} once its parent is imported, not before.",
        title: item.title || "#" <> item.source_id
      )

  defp decide_all([_, _ | _] = waiting),
    do: waiting |> Enum.map(&MigrationItem.conflict/1) |> Enum.uniq() |> same_way(waiting)

  defp decide_all(_one_or_none), do: nil

  defp same_way([conflict], waiting), do: %{conflict: conflict, ids: Enum.map(waiting, & &1.id)}
  defp same_way(_mixed, _waiting), do: nil

  defp import_all(nodes, [], [_, _ | _] = importable),
    do:
      nodes
      |> Enum.any?(&(MigrationItem.standing(&1) in [:not_listed, :left_out]))
      |> importable(importable)

  defp import_all(_nodes, _waiting, _importable), do: nil

  defp importable(true, _importable), do: nil
  defp importable(false, importable), do: importable

  defp shown(list_path, node),
    do:
      list_path <>
        "?" <>
        URI.encode_query(%{
          "items_filter_search" => node.title || node.source_id,
          "items_filter_source_kind" => node.source_kind
        })

  defp standing_class(:undecided), do: MigrationRun.outcome_class(:undecided)
  defp standing_class(:imported), do: MigrationRun.outcome_class(:created)
  defp standing_class(:connected), do: "bg-[#eeedfb] text-[#5b57d6]"
  defp standing_class(:not_listed), do: MigrationRun.outcome_class(:failed)
  defp standing_class(_not_imported_or_left_out), do: MigrationRun.outcome_class(:skipped)

  defp button_class(:primary),
    do:
      "inline-flex h-[30px] items-center gap-1.5 rounded-[9px] bg-[#5b57d6] px-3 text-[12px] font-bold text-white transition-colors hover:bg-[#4f4bcc]"

  defp button_class(:secondary),
    do:
      "inline-flex h-[30px] items-center gap-1.5 rounded-[9px] border border-[#ecebe6] bg-white px-3 text-[12px] font-bold text-[#3a382f] transition-colors hover:bg-[#f7f6f3]"

  defp button_class(:choice),
    do:
      "inline-flex h-[26px] items-center rounded-[8px] border border-[#ecebe6] bg-white px-2.5 text-[11.5px] font-semibold text-[#3a382f] transition-colors hover:border-[#c3c1f0] hover:bg-[#f4f3fd]"

  defp button_class(:link),
    do:
      "inline-flex h-[26px] items-center px-1.5 text-[11.5px] font-semibold text-[#4f4bcc] hover:underline"
end
