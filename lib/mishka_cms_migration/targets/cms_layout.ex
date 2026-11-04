# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.CmsLayout do
  @moduledoc """
  The `"menu"` items of a source: every menu of the site, classic and block
  (`MishkaCmsMigration.Sources.WordPress.Navigation`), written where an admin says it goes. A menu
  becomes the links of the site's layout, the core's own navigation, through the `:update` an
  admin's layout form runs (`MishkaCmsCore.Runtime.Layout`), on the run's site and as the admin who
  pressed Import: the admin needs the core's `admin:dashboard:runtime:layout`, and the core's own
  rules decide the rest, such as that the layout's template must compile.

  ## Where a menu goes

  Every site has the `site-main` layout (`MishkaCmsCore.Runtime.SiteLayout`), and its header is the
  `site-header` component, which draws the links the layout hands it before its own
  (`MishkaCmsCore.Install.StarterContent`, the `:nav` it seeds a site with). A top-level item is a
  link in the bar, and one with items under it is a group, a dropdown from `lg` up and a labelled
  list in the phone's menu panel, in the core's markup and classes. The core's group holds links,
  not groups, so an item's own link comes first in its group and every item under it follows,
  however deep, in menu order. An item with no address of its own is left out of the group.

  Each menu goes where its `"menu_goes_to"` decision says (`MishkaCmsMigration.MigrationItem`'s
  Decide…, kept in `decisions` across runs): Header links, which show in the top bar; Footer
  links, which show beside the footer's links; A component, which can be placed on any page or
  layout; or Leave out. The site's main menu (`MishkaCmsMigration.Sources.WordPress`'s `main`, the one at the
  theme's primary location) is pre-selected for Header links and writes at once. Every other menu
  waits for the admin's decision as `"menu_goes_to"`, as `"menu_goes_to: <menu>"` when it is a
  block menu with the same links as the classic menu `<menu>` (`"same_as"`), so both are shown and
  the admin leaves one out. A menu's name is never a rule.

  The footer is the `site-footer` component, whose free slot ("Anything to put beside the links",
  `render_slot(@inner_block)`) takes the links. The starter layout calls it self-closed, so the
  write turns the call into an opening and a closing tag in the layout's tree
  (`MishkaCmsCore.Runtime.Authoring.Tree`) and puts the links between them. Footer links are flat:
  a menu with items under items is listed in menu order, each item's link followed by the links
  under it.

  A component is a `MishkaCmsCore.Runtime.Component` of its own for the menu (the target's
  `writes_to/2`), named `nav-` and the menu's slug, as `nav-footer`, with the header's markup
  (`StarterContent.nav_links/1`, groups included) as its template. The admin places it with
  `<.component component_name="nav-footer" />` on any page or layout. The layout is not touched. A
  site that already has a component of that name waits for the admin's decision as
  `"component_name_taken"`: Use the existing component connects the menu to it and writes nothing,
  or the menu is left out.

  The layout is read before anything is written, in the dry run too (`existing/2`), with one query
  for every menu of the page, and read again by the one write of each menu (`prepare/3`), so a
  menu never writes over what another menu of the same run just put in the layout; the menus the
  layout holds from earlier writes get the layout's new `updated_at`, so a write of one is never
  taken for an edit in the CMS:

    * a site with no `site-main` layout, or one whose layout draws no `site-header` or
      `site-footer`, skips a menu placed there as `"no_layout"`;
    * a header or footer that already has links of its own, or that another menu of the same run is
      about to write, waits for an admin's decision as `"header_has_links"` or
      `"footer_has_links"` (`MishkaCmsMigration.MigrationItem`'s Decide…): Keep the site's own skips the menu as
      `"site_own_kept"`, and Replace with the imported menu writes it over the layout in place of
      those links; the site's own navigation is never written over on the import's own say. The
      main menu comes first, so a second menu is the one that asks;
    * otherwise the menu is written over the layout (`MishkaCmsMigration.Target`'s
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

  ## Links to pages that are not live

  A link to a page the site does not serve would lead nowhere: pages come in as drafts by default
  (`MishkaCmsMigration.Targets.CmsPage`). So a menu waits for an admin's decision as
  `"draft_pages"` (`MishkaCmsMigration.MigrationItem`'s Decide…) while it links a page that is not
  live, its labels after `": "`, as in `"draft_pages: Team, Leadership"`, unless another live page
  of the site answers that page's address, as the Blog's `/:lang/blog` answers `/blog`
  (`MishkaCmsCore.Runtime.PageEditions.urls/2`, read with one query of the live pages):

    * Publish the linked pages (`"import"`) makes those pages live through the core's own page
      `:update`, as the admin, in the menu's write: a page the core refuses to put live fails the
      menu, and nothing of it is written. A page published so is the admin's from then on, as one
      published in the CMS is: a later run keeps it as it is (`"edited_in_cms"`);
    * Leave those links out of the menu (`"keep"`) writes the menu without them, and the pages stay
      as they are.

  An import tells from the pages' records, once its pages are written (`prepare/3`). A dry run,
  which writes none, tells from what it plans for them (`waiting/2`): a page it would create or
  update is not live under the run's `pages` choice `"draft"`, nor with a note that keeps it a
  draft (`"draft_from_*"`), and any other from its record. It asks two queries more, for the
  pages' items and their records. A menu a run does not write, one WordPress did not change, is
  not asked about.

  ## Links and the site's language addresses

  The links are written as fixed addresses in the way the site names the language in its addresses
  now, while a source that runs a language plugin (Polylang or WPML) has addresses with a language
  prefix, and a site that gives every language a prefix may later be switched back. On such a run
  a menu waits for an admin's decision as `"language_urls"`, before anything else
  (`MishkaCmsMigration.Targets.Helpers.LanguageUrls`): Write links for the site's current mode
  (`"import"`) goes on, Wait (`"keep"`) skips it as `"waits_for_language_urls"`.

  ## A second run

  A re-run is held to the rules every target is: a menu the source did not change is
  `"unchanged"`, and a layout or component an admin changed since the import wrote it is kept as the
  admin left it (`"edited_in_cms"`). A menu the source changed is written again, its links in place of the ones
  the last import wrote.
  """

  use MishkaCmsMigration.Target,
    kind: "menu",
    resource: MishkaCmsCore.Runtime.Layout,
    create: :create,
    update: :update

  require Ash.Query

  alias MishkaCmsCore.Install.StarterContent
  alias MishkaCmsCore.Runtime.Authoring.Tree
  alias MishkaCmsCore.Runtime.Authoring.Tree.{Node, Serializer}
  alias MishkaCmsCore.Runtime.{Component, Languages, Layout, Page, PageEditions}
  alias MishkaCmsMigration.{MigrationItem, MigrationRun, Source, Target}
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Targets.CmsPage
  alias MishkaCmsMigration.Targets.Helpers.{LanguageUrls, Read}

  @layout "site-main"
  @slots %{header: "site-header", footer: "site-footer"}
  @conflicts %{header: "header_has_links", footer: "footer_has_links"}
  @recorded ~w(source_host source_kind source_id run_id title source_slug source_parent
               source_modified_at content_hash target_resource target_id outcome reason extra)a
  @kinds ["page", "post", "category", "tag"]
  @schemes ["http", "https", "mailto", "tel"]

  @impl MishkaCmsMigration.Target
  def resources, do: [Layout, Component]

  @impl MishkaCmsMigration.Target
  def writes_to(item, context) do
    case place(item, context) do
      :component -> {Component, %{create: :create, update: :update}}
      _layout_place -> {Layout, actions()}
    end
  end

  @impl MishkaCmsMigration.Target
  def existing(items, context) do
    goes = Enum.map(items, &{&1, goes_to(&1, context)})
    layout = if Enum.any?(goes, &in_layout?/1), do: layout(context)
    components = components(goes, context)

    {found, _taken} =
      goes
      |> Enum.sort_by(fn {item, _goes} -> item.attrs["main"] != true end)
      |> Enum.flat_map_reduce(MapSet.new(), &settle(&1, &2, layout, components, context))

    Map.new(found)
  end

  @impl MishkaCmsMigration.Target
  def prepare(item, context, write) do
    with :ok <- LanguageUrls.call(item, context), do: prepare_links(item, context, write)
  end

  @impl MishkaCmsMigration.Target
  def waiting(item, context) do
    with :ok <- LanguageUrls.call(item, context),
         do:
           item
           |> planned_drafts(context)
           |> unanswered(context)
           |> drafted(item, context)
           |> waited()
  end

  @impl MishkaCmsMigration.Target
  def attrs(item, %{record: record, prepared: prepared, source_host: host} = context) do
    addresses =
      context
      |> Target.decision(item, "draft_pages")
      |> settled(prepared, context)

    place = place(item, context)
    links = navigation(item.attrs["items"], addresses, host, place)
    written(place, item, record, links)
  end

  defp written(:component, item, _record, links),
    do: %{name: component_name(item), template: links}

  defp written(place, _item, layout, links),
    do: %{template: navigated(layout.template, place, links)}

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

  defp goes_to(item, context),
    do: context |> Target.decision(item, "menu_goes_to") |> chosen(item)

  defp chosen("header", _item), do: {:place, :header}
  defp chosen("footer", _item), do: {:place, :footer}
  defp chosen("component", _item), do: {:place, :component}
  defp chosen(nil, %Item{attrs: %{"main" => true}}), do: {:place, :header}

  defp chosen(nil, %Item{attrs: %{"same_as" => menu}}) when is_binary(menu),
    do: {:undecided, "menu_goes_to: " <> menu}

  defp chosen(nil, _item), do: {:undecided, "menu_goes_to"}

  defp place(item, context), do: item |> goes_to(context) |> elem(1)

  defp settle({item, {:place, :component}}, taken, _layout, components, context) do
    found =
      components
      |> Map.get(component_name(item))
      |> named(Target.decision(context, item, "component_name_taken"))

    {for(found <- found, do: {item.source_id, found}), taken}
  end

  defp settle({item, {:place, place}}, taken, layout, _components, context) do
    found =
      layout
      |> open(place, MapSet.member?(taken, place))
      |> decided(Target.decision(context, item, @conflicts[place]), @conflicts[place])

    {[{item.source_id, found}], claimed(found, taken, place)}
  end

  defp settle({item, undecided}, taken, _layout, _components, _context),
    do: {[{item.source_id, undecided}], taken}

  defp in_layout?({_item, {:place, place}}), do: place != :component
  defp in_layout?({_item, _undecided}), do: false

  defp components(goes, context) do
    names = for {item, {:place, :component}} <- goes, do: component_name(item)
    components(names, context.site_id, context)
  end

  defp components([], _site_id, _context), do: %{}

  defp components(names, site_id, context),
    do:
      Component
      |> Ash.Query.filter(name in ^names and site_id == ^site_id)
      |> Read.call(context)
      |> Map.new(&{&1.name, &1})

  defp named(nil, _decision), do: []
  defp named(_component, nil), do: [{:undecided, "component_name_taken"}]
  defp named(component, "keep"), do: [{:connected, component}]

  defp component_name(%Item{attrs: %{"slug" => slug}} = item) when is_binary(slug),
    do: "nav-" <> (Slug.slugify(slug) || item.source_id)

  defp component_name(item), do: "nav-" <> item.source_id

  defp claimed({:updated, _layout}, taken, place), do: MapSet.put(taken, place)
  defp claimed(_found, taken, _place), do: taken

  defp layout(context) do
    Layout
    |> Ash.Query.filter(name == ^@layout and site_id == ^context.site_id)
    |> Read.call(context)
    |> List.first()
  end

  defp open(nil, _place, _taken), do: {:skipped, "no_layout"}

  defp open(layout, place, taken),
    do: layout.template |> slot(place) |> opened(layout, taken)

  defp opened({:ok, tree, node}, layout, taken),
    do: {Tree.blank?(tree, node.id) and not taken, layout}

  defp opened(_no_slot, _layout, _taken), do: {:skipped, "no_layout"}

  defp decided({:skipped, _reason} = skipped, _decision, _conflict), do: skipped
  defp decided({true, layout}, _decision, _conflict), do: {:updated, layout}
  defp decided({false, layout}, "import", _conflict), do: {:updated, layout}
  defp decided({false, _layout}, "keep", _conflict), do: {:skipped, "site_own_kept"}
  defp decided({false, _layout}, nil, conflict), do: {:undecided, conflict}

  defp slot(template, place) do
    component = Map.fetch!(@slots, place)

    with {:ok, tree} <- Tree.parse(template),
         %Node{} = node <-
           Enum.find(Tree.walk(tree), &({"component_name", {:string, component}} in &1.attrs)),
         do: {:ok, tree, node}
  end

  defp navigated(template, place, links) do
    with {:ok, tree, node} <- slot(template, place),
         {:ok, links} <- Tree.parse(links),
         {:ok, tree} <- tree |> emptied(node) |> open_tag(node) |> Tree.insert(links, node.id, 0),
         {:ok, heex} <- Serializer.to_heex(tree) do
      heex
    else
      refused ->
        raise ArgumentError, "the site layout cannot take the menu: #{inspect(refused)}"
    end
  end

  defp open_tag(tree, node),
    do: %{
      tree
      | nodes: Map.update!(tree.nodes, node.id, &%{&1 | meta: Map.delete(&1.meta, :self_close)})
    }

  defp emptied(tree, node), do: Enum.reduce(node.children, tree, &without/2)

  defp without(id, tree), do: tree |> Tree.delete(id) |> elem(1)

  defp prepare_links(item, context, write) do
    linked = linked(item, context)

    drafts =
      linked
      |> Enum.filter(&match?({{"page", _id}, %Page{active: false}}, &1))
      |> unanswered(context)

    with :ok <- drafted(drafts, item, context),
         do:
           %{context | prepared: %{linked: linked, drafts: drafts}}
           |> fresh()
           |> write.()
           |> retimed(item, context)
  end

  defp fresh(%{record: %Layout{id: id}} = context) do
    Layout
    |> Ash.Query.filter(id == ^id)
    |> Read.call(context)
    |> List.first()
    |> then(&%{context | record: &1 || context.record})
  end

  defp fresh(context), do: context

  defp retimed({:ok, {:ok, %Layout{} = layout}} = written, item, context) do
    MigrationItem
    |> Ash.Query.filter(
      source_host == ^context.source_host and source_kind == ^item.kind and
        target_id == ^layout.id and source_id != ^item.source_id and
        not is_nil(target_updated_at)
    )
    |> Read.call(context)
    |> Enum.each(&MishkaCmsMigration.record_item!(retime(&1, layout), scope: context.scope))

    written
  end

  defp retimed(written, _item, _context), do: written

  defp retime(sibling, layout),
    do:
      sibling
      |> Map.take(@recorded)
      |> Map.put(:target_updated_at, layout.updated_at)

  defp settled("import", %{linked: linked, drafts: drafts}, context) do
    Enum.each(drafts, fn {_key, page} -> published!(page, context) end)
    addresses(linked)
  end

  defp settled("keep", %{linked: linked, drafts: drafts}, _context),
    do: linked |> addresses() |> Map.merge(Map.new(drafts, fn {key, _page} -> {key, nil} end))

  defp settled(_decision, %{linked: linked}, _context), do: addresses(linked)

  defp published!(page, context),
    do:
      page
      |> Ash.Changeset.for_update(:update, %{active: true},
        actor: context.actor,
        tenant: context.site_id
      )
      |> Ash.update!()

  defp drafted([], _item, _context), do: :ok

  defp drafted(drafts, item, context),
    do: context |> Target.decision(item, "draft_pages") |> undecided(drafts, item)

  defp undecided(nil, drafts, item), do: {:undecided, "draft_pages: " <> labels(drafts, item)}
  defp undecided(_decided, _drafts, _item), do: :ok

  defp waited(:ok), do: nil
  defp waited(undecided), do: undecided

  defp labels(drafts, item) do
    keys = Map.new(drafts, fn {key, _page} -> {key, true} end)

    item.attrs["items"]
    |> entries()
    |> Enum.filter(&is_map_key(keys, {&1["kind"], &1["id"]}))
    |> Enum.map(& &1["title"])
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  defp unanswered([], _context), do: []

  defp unanswered(drafts, context) do
    answered =
      Page
      |> Ash.Query.filter(active == true)
      |> Ash.Query.select([:path, :language, :extra, :site_id])
      |> Read.call(context)
      |> Enum.flat_map(&PageEditions.urls(&1, context.site_id))
      |> MapSet.new()

    Enum.reject(drafts, fn {_key, page} ->
      page |> PageEditions.urls(context.site_id) |> Enum.any?(&MapSet.member?(answered, &1))
    end)
  end

  defp planned_drafts(item, context) do
    links =
      for %{"kind" => "page", "id" => id} = entry <- entries(item.attrs["items"]),
          into: %{},
          do: {id, entry["url"]}

    pages = pages(Map.keys(links), context)
    records = pages |> Enum.map(& &1.target_id) |> Enum.reject(&is_nil/1) |> page_records(context)

    for page <- pages,
        draft = planned_draft(page, records[page.target_id], links[page.source_id], context),
        do: {{"page", page.source_id}, draft}
  end

  defp planned_draft(%{plan: plan} = page, record, link, context)
       when plan in [:created, :updated],
       do: page |> drafted_by_run?(context) |> would_be(record || unwritten(page, link, context))

  defp planned_draft(_page, %Page{active: false} = record, _link, _context), do: record
  defp planned_draft(_page, _record, _link, _context), do: nil

  defp drafted_by_run?(_page, %{options: %{pages: "draft"}}), do: true

  defp drafted_by_run?(%{plan_reason: reason}, _context) when is_binary(reason),
    do: String.contains?(reason, "draft_from_")

  defp drafted_by_run?(_page, _context), do: false

  defp would_be(true, page), do: page
  defp would_be(false, _page), do: nil

  defp unwritten(page, link, context),
    do: %{
      path: CmsPage.written_path(link, page),
      language: Languages.primary(context.site_id),
      extra: %{}
    }

  defp pages([], _context), do: []

  defp pages(ids, context),
    do:
      MigrationItem
      |> Ash.Query.filter(
        source_host == ^context.source_host and source_kind == "page" and source_id in ^ids and
          not left_out
      )
      |> Read.call(context)

  defp page_records([], _context), do: %{}

  defp page_records(ids, context),
    do: Page |> Ash.Query.filter(id in ^ids) |> Read.call(context) |> Map.new(&{&1.id, &1})

  defp addresses(linked),
    do:
      for(
        {{kind, _id} = key, record} <- linked,
        address = MigrationRun.record_address(kind, record),
        into: %{},
        do: {key, address}
      )

  defp linked(item, context),
    do:
      item
      |> written(context)
      |> Enum.group_by(& &1.source_kind)
      |> Enum.flat_map(fn {kind, items} -> kind |> Target.fetch() |> records(items, context) end)
      |> Map.new()

  defp records({:ok, target}, [%{source_kind: kind} | _] = items, context) do
    records =
      target.resource()
      |> Ash.Query.filter(id in ^Enum.map(items, & &1.target_id))
      |> Read.call(context)
      |> Map.new(&{&1.id, &1})

    for item <- items, record = records[item.target_id], do: {{kind, item.source_id}, record}
  end

  defp records({:error, :not_installed}, _items, _context), do: []

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
       do: found |> Map.fetch!({kind, id}) |> navigate()

  defp destination(%{"url" => url}, _found, host) when is_binary(url) do
    url = String.trim(url)
    url |> URI.parse() |> kept(url, Source.url_host(%{"url" => url}) == host)
  end

  defp destination(_entry, _found, _host), do: nil

  defp navigate(nil), do: nil
  defp navigate(address), do: {:navigate, address}

  defp kept(%URI{path: path, query: nil}, _url, true) when path in [nil, "", "/"],
    do: {:navigate, "/"}

  defp kept(%URI{scheme: scheme}, url, _on_source) when scheme in @schemes, do: {:href, url}
  defp kept(%URI{scheme: nil, host: nil, path: "/" <> _}, url, _on_source), do: {:href, url}
  defp kept(_uri, _url, _on_source), do: nil

  defp old?({:href, url}, context), do: Source.url_host(%{"url" => url}) == context.source_host
  defp old?(_destination, _context), do: false

  defp old_address([]), do: nil
  defp old_address(titles), do: "old_address: " <> Enum.join(titles, ", ")

  defp navigation(items, found, host, place) when place in [:header, :component] do
    items
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {entry, index} -> top(entry, index, found, host) end)
    |> StarterContent.nav_links()
  end

  defp navigation(items, found, host, :footer) do
    for(
      entry <- entries(items),
      destination = destination(entry, found, host),
      do: nav_entry(entry, destination)
    )
    |> StarterContent.nav_links()
  end

  defp top(%{"items" => [_ | _] = items} = entry, index, found, host) do
    links =
      for item <- [entry | entries(items)],
          destination = destination(item, found, host),
          do: nav_entry(item, destination)

    [%{label: title(entry), id: "#{index}", children: links}]
  end

  defp top(entry, _index, found, host),
    do: entry |> destination(found, host) |> top_link(entry)

  defp top_link(nil, _entry), do: []
  defp top_link(destination, entry), do: [nav_entry(entry, destination)]

  defp nav_entry(entry, {:navigate, path}), do: %{label: title(entry), to: path}

  defp nav_entry(%{"new_tab" => true} = entry, {:href, url}),
    do: %{label: title(entry), href: url, target: "_blank"}

  defp nav_entry(entry, {:href, url}), do: %{label: title(entry), href: url}

  defp title(entry), do: entry["title"] || ""
end
