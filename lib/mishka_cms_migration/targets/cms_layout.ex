# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.CmsLayout do
  @moduledoc """
  The `"menu"` items of a source: the site's main menu written as the links of its layout's header,
  the core's own navigation, through the `:update` an admin's layout form runs
  (`MishkaCmsCore.Runtime.Layout`), on the run's site and as the admin who pressed Import: the admin
  needs the core's `admin:dashboard:runtime:layout`, and the core's own rules decide the rest, such
  as that the layout's template must compile.

  ## Where the menu goes

  Every site has the `site-main` layout (`MishkaCmsCore.Runtime.SiteLayout`), and its header is the
  `site-header` component, which draws the links the layout hands it before its own
  (`MishkaCmsCore.Install.StarterContent`, the `:nav` it seeds a site with). The main menu
  (`MishkaCmsMigration.Sources.WordPress`'s `main`) becomes those links, so the site draws it as it
  draws its own: a top-level item is a link in the bar, and one with items under it is a group, a
  dropdown from `lg` up and a labelled list in the phone's menu panel, in the core's markup and
  classes. The core's group holds links, not groups, so an item's own link comes first in its group
  and every item under it follows, however deep, in menu order. An item with no address of its own
  is left out of the group.

  The layout is read before anything is written, in the dry run too (`existing/2`), with one query:

    * a menu that is not the main one is skipped as `"not_main_menu"`;
    * a site with no `site-main` layout, or one whose layout draws no `site-header`, skips the main
      menu as `"no_layout"`;
    * a header that already has links of its own waits for an admin's decision as
      `"header_has_links"` (`MishkaCmsMigration.MigrationItem`'s Decide…): Keep the site's own
      skips the main menu as `"site_own_kept"`, and Replace with the imported menu writes it over
      the layout in place of those links; the site's own navigation is never written over on the
      import's own say;
    * otherwise the main menu is written over the layout (`MishkaCmsMigration.Target`'s
      `{:updated, record}`), and the layout is its record.

  The template is changed as the core's editor changes one: read into its tree
  (`MishkaCmsCore.Runtime.Authoring.Tree`), the header's links put in, and written back the way the
  editor saves it (`MishkaCmsCore.Runtime.Authoring.Tree.Serializer.to_heex/1`), so the layout comes
  back formatted as a save in the builder formats it.

  ## Where each link points

  An item that points at a page, a post, a category or a tag points at the CMS record the same run,
  or an earlier one, wrote for it, at the address the site serves it at, live or not yet
  (`MishkaCmsMigration.MigrationRun.record_address/2`), as a live navigation. One whose record was
  never written, or that an admin left out, keeps its address at the source. A custom link to the
  source's own home is the site's home, `/`; any other link keeps its address and opens as WordPress
  said it does (`new_tab`). Only `http`, `https`, `mailto` and `tel` addresses, and a path on the
  site, are links; an item with any other, such as `#`, has none.

  The import's report names the items that still point at the source's host, after `"old_address:
  "`, so an admin can see which links leave the site; a dry run, which writes nothing, names none.
  The items' records are found with one query for the items (`note/2`) and one more, then one for
  each kind of record they point at, when the menu is written (`prepare/3`).

  ## A second run

  A re-run is held to the rules every target is: a menu the source did not change is
  `"unchanged"`, and a layout an admin changed since the import wrote it is kept as the admin left it
  (`"edited_in_cms"`). A menu the source changed is written again, its links in place of the ones
  the last import wrote.
  """

  use MishkaCmsMigration.Target,
    kind: "menu",
    resource: MishkaCmsCore.Runtime.Layout,
    create: :create,
    update: :update

  require Ash.Query

  alias MishkaCmsCore.Runtime.Authoring.Tree
  alias MishkaCmsCore.Runtime.Authoring.Tree.{Node, Serializer}
  alias MishkaCmsCore.Runtime.Layout
  alias MishkaCmsMigration.{MigrationItem, MigrationRun, Source, Target}
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Targets.Helpers.Read

  @layout "site-main"
  @header {"component_name", {:string, "site-header"}}
  @kinds ["page", "post", "category", "tag"]
  @schemes ["http", "https", "mailto", "tel"]
  @braces %{"{" => "&lbrace;", "}" => "&rbrace;"}

  @bar_link ~s(class="text-dim dark:text-dim-dark")
  @menu_link ~s(role="menuitem" class="flex items-center rounded-[9px] px-[11px] py-[9px] text-[13px] font-medium text-fg hover:bg-wash dark:text-fg-dark dark:hover:bg-wash-dark")
  @panel_link ~s(class="rounded-[9px] px-[11px] py-[9px] text-dim hover:bg-wash dark:text-dim-dark dark:hover:bg-wash-dark")

  @impl MishkaCmsMigration.Target
  def existing(items, context), do: Map.new(items, &{&1.source_id, placed(&1, context)})

  @impl MishkaCmsMigration.Target
  def prepare(item, context, write), do: write.(%{context | prepared: addresses(item, context)})

  @impl MishkaCmsMigration.Target
  def attrs(item, %{record: layout, prepared: addresses, source_host: host}),
    do: %{template: navigated(layout.template, navigation(item.attrs["items"], addresses, host))}

  @impl MishkaCmsMigration.Target
  def note(_item, %{mode: :dry_run}), do: nil

  def note(item, context) do
    written = item |> written(context) |> Map.new(&{{&1.source_kind, &1.source_id}, &1.target_id})

    item.attrs["items"]
    |> entries()
    |> Enum.filter(&(&1 |> destination(written, context.source_host) |> old?(context)))
    |> Enum.map(& &1["title"])
    |> old_address()
  end

  defp placed(%Item{attrs: %{"main" => true}} = item, context),
    do: context |> layout() |> open(Target.decision(context, item, "header_has_links"))

  defp placed(_menu, _context), do: {:skipped, "not_main_menu"}

  defp layout(context) do
    Layout
    |> Ash.Query.filter(name == ^@layout and site_id == ^context.site_id)
    |> Read.call(context)
    |> List.first()
  end

  defp open(nil, _decision), do: {:skipped, "no_layout"}
  defp open(layout, decision), do: layout.template |> header() |> opened(layout, decision)

  defp opened({:ok, tree, header}, layout, decision),
    do: tree |> Tree.blank?(header.id) |> blank(layout, decision)

  defp opened(_no_header, _layout, _decision), do: {:skipped, "no_layout"}

  defp blank(true, layout, _decision), do: {:updated, layout}
  defp blank(false, layout, "import"), do: {:updated, layout}
  defp blank(false, _layout, "keep"), do: {:skipped, "site_own_kept"}
  defp blank(false, _layout, nil), do: {:undecided, "header_has_links"}

  defp header(template) do
    with {:ok, tree} <- Tree.parse(template),
         %Node{} = header <- Enum.find(Tree.walk(tree), &(@header in &1.attrs)),
         do: {:ok, tree, header}
  end

  defp navigated(template, links) do
    with {:ok, tree, header} <- header(template),
         {:ok, links} <- Tree.parse(links),
         {:ok, tree} <- tree |> emptied(header) |> Tree.insert(links, header.id, 0),
         {:ok, heex} <- Serializer.to_heex(tree) do
      heex
    else
      refused ->
        raise ArgumentError, "the site layout's header cannot take the menu: #{inspect(refused)}"
    end
  end

  defp emptied(tree, header), do: Enum.reduce(header.children, tree, &without/2)

  defp without(id, tree), do: tree |> Tree.delete(id) |> elem(1)

  defp addresses(item, context),
    do:
      item
      |> written(context)
      |> Enum.group_by(& &1.source_kind)
      |> Enum.flat_map(fn {kind, items} ->
        kind |> Target.fetch() |> addressed(items, context)
      end)
      |> Map.new()

  defp addressed({:ok, target}, [%{source_kind: kind} | _] = items, context) do
    records =
      target.resource()
      |> Ash.Query.filter(id in ^Enum.map(items, & &1.target_id))
      |> Read.call(context)
      |> Map.new(&{&1.id, &1})

    for item <- items,
        record = records[item.target_id],
        address = MigrationRun.record_address(kind, record),
        do: {{kind, item.source_id}, address}
  end

  defp addressed({:error, :not_installed}, _items, _context), do: []

  defp written(item, context),
    do: item.attrs["items"] |> entries() |> Enum.flat_map(&reference/1) |> written_items(context)

  defp written_items([], _context), do: []

  defp written_items(references, context) do
    {kinds, ids} = Enum.unzip(references)

    MigrationItem
    |> Ash.Query.filter(
      source_host == ^context.source_host and source_kind in ^kinds and source_id in ^ids and
        not is_nil(target_id) and not left_out
    )
    |> Read.call(context)
    |> Enum.filter(&({&1.source_kind, &1.source_id} in references))
  end

  defp entries(items), do: Enum.flat_map(items || [], &[&1 | entries(&1["items"])])

  defp reference(%{"kind" => kind, "id" => id}) when kind in @kinds and is_binary(id),
    do: [{kind, id}]

  defp reference(_entry), do: []

  defp destination(%{"kind" => kind, "id" => id}, found, _host)
       when is_map_key(found, {kind, id}),
       do: {:navigate, Map.fetch!(found, {kind, id})}

  defp destination(%{"url" => url}, _found, host) when is_binary(url) do
    url = String.trim(url)
    url |> URI.parse() |> kept(url, Source.url_host(%{"url" => url}) == host)
  end

  defp destination(_entry, _found, _host), do: nil

  defp kept(%URI{path: path, query: nil}, _url, true) when path in [nil, "", "/"],
    do: {:navigate, "/"}

  defp kept(%URI{scheme: scheme}, url, _on_source) when scheme in @schemes, do: {:href, url}
  defp kept(%URI{scheme: nil, host: nil, path: "/" <> _}, url, _on_source), do: {:href, url}
  defp kept(_uri, _url, _on_source), do: nil

  defp old?({:href, url}, context), do: Source.url_host(%{"url" => url}) == context.source_host
  defp old?(_destination, _context), do: false

  defp old_address([]), do: nil
  defp old_address(titles), do: "old_address: " <> Enum.join(titles, ", ")

  defp navigation(items, found, host) do
    items
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {entry, index} -> top(entry, index, found, host) end)
  end

  defp top(%{"items" => [_ | _] = items} = entry, index, found, host) do
    links =
      for item <- [entry | entries(items)],
          destination = destination(item, found, host),
          do: {item, destination}

    group(entry["title"], links, index)
  end

  defp top(entry, _index, found, host),
    do: entry |> destination(found, host) |> link(entry, @bar_link)

  defp link(nil, _entry, _style), do: ""

  defp link(destination, entry, style),
    do: ~s(<.link #{to(destination, entry)} #{style}>#{text(entry["title"])}</.link>)

  defp to({:navigate, path}, _entry), do: ~s(navigate="#{attribute(path)}")

  defp to({:href, url}, %{"new_tab" => true}),
    do: ~s(href="#{attribute(url)}" target="_blank" rel="noopener noreferrer")

  defp to({:href, url}, _entry), do: ~s(href="#{attribute(url)}")

  defp text(title),
    do:
      (title || "")
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()
      |> String.replace(Map.keys(@braces), &Map.fetch!(@braces, &1))

  defp attribute(address),
    do: URI.encode(address, &(URI.char_reserved?(&1) or URI.char_unreserved?(&1) or &1 == ?%))

  defp group(_title, [], _index), do: ""

  defp group(title, links, index) do
    base = "site-nav-#{index}"
    menu_items = Enum.map_join(links, "\n", fn {item, to} -> link(to, item, @menu_link) end)
    panel_items = Enum.map_join(links, "\n", fn {item, to} -> link(to, item, @panel_link) end)

    ~s"""
    <div
      phx-click-away={
        Phoenix.LiveView.JS.hide(to: "##{base}-menu")
        |> Phoenix.LiveView.JS.set_attribute({"aria-expanded", "false"}, to: "##{base}-button")
      }
      phx-window-keydown={
        Phoenix.LiveView.JS.hide(to: "##{base}-menu")
        |> Phoenix.LiveView.JS.set_attribute({"aria-expanded", "false"}, to: "##{base}-button")
      }
      phx-key="Escape"
      class="relative max-lg:hidden"
    >
      <button
        type="button"
        id="#{base}-button"
        aria-haspopup="menu"
        aria-expanded="false"
        phx-click={
          Phoenix.LiveView.JS.toggle(to: "##{base}-menu")
          |> Phoenix.LiveView.JS.toggle_attribute({"aria-expanded", "true", "false"})
        }
        class="flex h-[38px] cursor-pointer items-center gap-1.5 rounded-[11px] border border-edge bg-surface px-2.5 text-[13px] font-medium text-fg dark:border-edge-dark dark:bg-surface-dark dark:text-fg-dark"
      >
        <span>#{text(title)}</span>
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="text-faint dark:text-faint-dark">
          <path d="M6 9l6 6 6-6"></path>
        </svg>
      </button>
      <div
        id="#{base}-menu"
        role="menu"
        class="absolute start-0 top-[46px] z-50 hidden min-w-[190px] overflow-hidden rounded-[14px] border border-edge bg-surface p-1.5 shadow-[0_18px_44px_rgba(30,28,24,0.16)] dark:border-edge-dark dark:bg-surface-dark dark:shadow-[0_18px_44px_rgba(0,0,0,0.5)]"
      >
    #{menu_items}
      </div>
    </div>
    <div role="group" aria-labelledby="#{base}-label" class="flex flex-col gap-0.5 lg:hidden">
      <span id="#{base}-label" class="px-[11px] pt-2 pb-1 text-[11.5px] font-semibold tracking-wide text-subtle uppercase dark:text-subtle-dark">
        #{text(title)}
      </span>
    #{panel_items}
    </div>
    """
  end
end
