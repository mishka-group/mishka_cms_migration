# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.CmsLayoutTest do
  @moduledoc """
  A WordPress site's main menu moved into the links of the run's site layout's header, against what
  the seeded WordPress answered: what a dry run plans, where an import points each link (the pages,
  posts and categories it wrote, the site's home, an outside site), that a link to what was not
  imported keeps its old address and the report says so, that the site's own links wait for an
  admin's decision and are kept or replaced as decided, that links to pages that are not live wait
  for one too, and what a second run does. Pages are imported live, at their old addresses, unless
  a test is about the drafts pages come in as by default.

  The layout is the core's `site-main` frame, its header the `site-header` component the core's
  starter draws, with no links of its own. Its links are read through the core's own tree of the
  template, for what they point at, not as markup.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0, stub!: 1, recorded: 1]

  alias MishkaCmsCore.Runtime.Authoring.Tree
  alias MishkaCmsCore.Runtime.{Component, Layout, Page}
  alias MishkaCmsMigration.MigrationItem
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Targets.CmsLayout

  @connection %{"url" => "http://localhost:8089", "user" => "admin"}
  @admin [
    "admin:dashboard:migration",
    "admin:dashboard:runtime:page",
    "admin:dashboard:blog:post",
    "admin:dashboard:runtime:layout",
    "admin:dashboard:runtime:component"
  ]
  @header {"component_name", {:string, "site-header"}}

  @frame ~S"""
  <div class="flex min-h-screen flex-col">
    <.component component_name="site-header" site="acme" lang="en" current_user={assigns[:current_user]}>
    </.component>
    <main id="site-main">{@inner_content}</main>
    <.component component_name="site-footer" site="acme" />
  </div>
  """

  setup do
    stub!()
    site = create_site!()
    %{site: site, admin: migration_admin!(site, @admin)}
  end

  defp layout!(site, template \\ @frame),
    do:
      create_layout!(
        site_id: site.id,
        name: "site-main",
        path: "/layouts/site-main",
        template: template
      )

  defp wordpress_run!(site, admin, options \\ %{pages: "publish"}) do
    %{source: "wordpress", connection: @connection, secret: "app password", options: options}
    |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)
  end

  defp imported!(site, admin, options \\ %{pages: "publish"}),
    do: site |> wordpress_run!(admin, options) |> dry_run!(admin) |> import!(admin)

  defp drafts!(site, admin, choice) do
    site |> wordpress_run!(admin, %{}) |> dry_run!(admin)
    decide!(site, admin, choice)
    imported!(site, admin, %{})
  end

  defp live_paths(site),
    do:
      Page
      |> Ash.read!(tenant: site.id, authorize?: false)
      |> Enum.filter(& &1.active)
      |> MapSet.new(& &1.path)

  defp outcomes(run) do
    for %{kind: "menu"} = entry <- run.report.entries,
        into: %{},
        do: {entry.source_id, {entry.outcome, entry.reason}}
  end

  defp template(site) do
    [layout] =
      Layout
      |> Ash.read!(tenant: site.id, authorize?: false)
      |> Enum.filter(&(&1.site_id == site.id and &1.name == "site-main"))

    layout.template
  end

  # The header's links, in the order the page draws them, each its label and where it goes: a
  # group's links are drawn twice, in its dropdown and in the phone's panel, and are read once.
  defp links(site) do
    {:ok, tree} = site |> template() |> Tree.parse()
    header = Enum.find(Tree.walk(tree), &(@header in &1.attrs))

    tree
    |> Tree.subtree(header.id)
    |> Tree.walk()
    |> Enum.filter(&(&1.tag == ".link"))
    |> Enum.map(&{label(tree, &1), destination(&1.attrs)})
    |> Enum.uniq()
  end

  # The footer's links, each its label and where it goes.
  defp footer_links(site) do
    {:ok, tree} = site |> template() |> Tree.parse()

    footer =
      Enum.find(Tree.walk(tree), &({"component_name", {:string, "site-footer"}} in &1.attrs))

    tree
    |> Tree.subtree(footer.id)
    |> Tree.walk()
    |> Enum.filter(&(&1.tag == ".link"))
    |> Enum.map(&{label(tree, &1), destination(&1.attrs)})
  end

  defp component(site, name),
    do:
      Component
      |> Ash.read!(tenant: site.id, authorize?: false)
      |> Enum.find(&(&1.site_id == site.id and &1.name == name))

  defp component_links(component) do
    {:ok, tree} = Tree.parse(component.template)

    for %{tag: ".link"} = link <- Tree.walk(tree),
        uniq: true,
        do: {label(tree, link), destination(link.attrs)}
  end

  defp label(tree, link),
    do: tree |> Tree.children(link.id) |> Enum.map_join(& &1.text) |> String.trim()

  defp destination(attrs) do
    case Map.new(attrs) do
      %{"navigate" => {:string, path}} -> {:navigate, path}
      %{"href" => {:string, url}, "target" => {:string, target}} -> {:href, url, target}
      %{"href" => {:string, url}} -> {:href, url}
    end
  end

  defp leave_out!(site, admin, kind, source_id) do
    MigrationItem
    |> Ash.read!(tenant: site.id, authorize?: false)
    |> Enum.find(&(&1.source_kind == kind and &1.source_id == source_id))
    |> MishkaCmsMigration.leave_out_item!(actor: admin, tenant: site.id)
  end

  defp own_links,
    do:
      String.replace(
        @frame,
        ~s(current_user={assigns[:current_user]}>\n),
        ~s(current_user={assigns[:current_user]}>\n    <.link navigate="/pricing">Pricing</.link>\n)
      )

  defp decide!(site, admin, choice, source_id \\ "22"),
    do:
      MigrationItem
      |> Ash.read!(tenant: site.id, authorize?: false)
      |> Enum.find(&(&1.source_kind == "menu" and &1.source_id == source_id))
      |> MishkaCmsMigration.decide_item!(choice, actor: admin, tenant: site.id)

  defp menu_items_with(changes),
    do:
      {"application/json",
       Jason.encode!(
         for item <- recorded("menu-items"), do: Map.merge(item, changes[item["id"]] || %{})
       )}

  describe "a dry run" do
    test "plans the main menu over the layout's header and leaves every other menu for the admin to place, writing nothing",
         %{site: site, admin: admin} do
      layout = layout!(site)

      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      assert outcomes(run) == %{
               "22" => {:updated, nil},
               "23" => {:undecided, "menu_goes_to"},
               "navigation-105" => {:undecided, "menu_goes_to"}
             }

      assert template(site) == layout.template
    end

    test "reads the site's layout with one query, and none for a menu that is not the main one",
         %{site: site, admin: admin} do
      layout!(site)
      context = %{actor: admin, site_id: site.id}
      main = %Item{kind: "menu", source_id: "22", attrs: %{"main" => true}}
      other = %Item{kind: "menu", source_id: "23", attrs: %{"main" => false}}

      assert [_layout] = queries_while(fn -> CmsLayout.existing([main, other], context) end)
      assert queries_while(fn -> CmsLayout.existing([other], context) end) == []
    end
  end

  describe "an import" do
    test "puts the main menu in the layout's header, each link at what the run wrote for it",
         %{site: site, admin: admin} do
      layout!(site)
      other = create_site!()
      untouched = layout!(other)

      run = imported!(site, admin)

      assert outcomes(run) == %{
               "22" => {:updated, nil},
               "23" => {:undecided, "menu_goes_to"},
               "navigation-105" => {:undecided, "menu_goes_to"}
             }

      assert links(site) == [
               {"Home", {:navigate, "/"}},
               {"About", {:navigate, "/about"}},
               {"Team", {:navigate, "/about/team"}},
               {"Leadership", {:navigate, "/about/team/leadership"}},
               {"Contact", {:navigate, "/contact"}},
               {"Blog", {:navigate, "/blog"}},
               {"News", {:navigate, "/blog/category/news"}},
               {"Releases", {:navigate, "/blog/category/releases"}},
               {"Announcements", {:navigate, "/blog/category/announcements"}},
               {"Tutorials", {:navigate, "/blog/category/tutorials"}},
               {"Docs", {:navigate, "/docs"}},
               {"Getting started", {:navigate, "/docs/getting-started"}},
               {"Start here", {:navigate, "/blog/welcome-to-the-mishka-test-blog"}},
               {"Elixir", {:href, "https://elixir-lang.org/", "_blank"}}
             ]

      assert template(other) == untouched.template
    end

    test "writes a menu the admin sends to the header over the main menu only once the admin decides to replace it",
         %{site: site, admin: admin} do
      layout!(site)
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, "header", "23")

      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      assert outcomes(run)["22"] == {:updated, nil}
      assert outcomes(run)["23"] == {:undecided, "header_has_links"}

      decide!(site, admin, "import", "23")
      run = imported!(site, admin)

      assert outcomes(run)["23"] == {:updated, "old_address: RSS feed"}
      assert links(site) |> Enum.map(&elem(&1, 0)) == ["Contact", "Docs", "RSS feed"]
    end

    test "keeps the main menu in the header when the admin keeps it against a second menu",
         %{site: site, admin: admin} do
      layout!(site)
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, "header", "23")
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, "keep", "23")

      run = imported!(site, admin)

      assert outcomes(run)["22"] == {:updated, nil}
      assert outcomes(run)["23"] == {:skipped, "site_own_kept"}
      assert {"Home", {:navigate, "/"}} in links(site)
      assert length(links(site)) == 14
    end

    test "offers a waiting menu the places it can go, each with a tip", %{
      site: site,
      admin: admin
    } do
      layout!(site)
      site |> wordpress_run!(admin) |> dry_run!(admin)

      menu =
        MigrationItem
        |> Ash.read!(tenant: site.id, authorize?: false)
        |> Enum.find(&(&1.source_kind == "menu" and &1.source_id == "23"))

      assert MigrationItem.conflict(menu) == "menu_goes_to"
      options = MigrationItem.decision_options(%{form: %Phoenix.HTML.Form{data: menu}})

      assert Enum.map(options, &elem(&1, 1)) == ["header", "footer", "component", "leave_out"]
      assert options |> Enum.at(0) |> elem(0) =~ "top bar"
      assert options |> Enum.at(1) |> elem(0) =~ "flat"
      assert options |> Enum.at(2) |> elem(0) =~ "any page or layout"
    end

    test "leaves out a menu the admin decides to leave out, and never writes it",
         %{site: site, admin: admin} do
      layout!(site)
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, "leave_out", "23")

      run = imported!(site, admin)

      assert outcomes(run)["23"] == {:skipped, "left_out_by_admin"}
      assert length(links(site)) == 14
    end

    test "names the classic menu a block menu has the same links as, and waits like any other",
         %{site: site, admin: admin} do
      layout!(site)

      contact =
        ~s(<!-- wp:navigation-link {"label":"Reach us","type":"page","id":29,"url":"http://localhost:8089/contact/","kind":"post-type"} /-->)

      navigation =
        for post <- recorded("navigation"), do: %{post | "content" => %{"raw" => contact}}

      stub!(%{
        "/wp-json/wp/v2/navigation" => {"application/json", Jason.encode!(navigation)},
        "/wp-json/wp/v2/menu-items" =>
          {"application/json",
           Jason.encode!(for item <- recorded("menu-items"), item["id"] == 102, do: item)}
      })

      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      assert outcomes(run)["navigation-105"] == {:undecided, "menu_goes_to: Footer"}
    end

    test "puts a menu the admin sends to the footer in the footer's free slot, beside the header's menu",
         %{site: site, admin: admin} do
      layout!(site)
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, "footer", "23")

      run = imported!(site, admin)

      assert outcomes(run)["22"] == {:updated, nil}
      assert outcomes(run)["23"] == {:updated, "old_address: RSS feed"}

      assert footer_links(site) == [
               {"Contact", {:navigate, "/contact"}},
               {"Docs", {:navigate, "/docs"}},
               {"RSS feed", {:href, "http://localhost:8089/feed/"}}
             ]

      assert length(links(site)) == 14
    end

    test "lists a nested block menu flat in the footer, each link followed by the links under it",
         %{site: site, admin: admin} do
      layout!(site)
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, "footer", "navigation-105")

      imported!(site, admin)

      assert footer_links(site) |> Enum.map(&elem(&1, 0)) ==
               ["Home", "About", "Team", "Contact", "Blog"]
    end

    test "leaves a footer with links of its own for an admin's decision, and keeps them",
         %{site: site, admin: admin} do
      own =
        String.replace(
          @frame,
          ~s(<.component component_name="site-footer" site="acme" />),
          ~s(<.component component_name="site-footer" site="acme"><.link navigate="/terms">Terms</.link></.component>)
        )

      layout!(site, own)
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, "footer", "23")

      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      assert outcomes(run)["23"] == {:undecided, "footer_has_links"}

      decide!(site, admin, "keep", "23")
      run = imported!(site, admin)

      assert outcomes(run)["23"] == {:skipped, "site_own_kept"}
      assert footer_links(site) == [{"Terms", {:navigate, "/terms"}}]
    end

    test "a menu written into the header after another into the footer keeps both, and a change of the first is written, not taken for an edit",
         %{site: site, admin: admin} do
      layout!(site)
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, "footer", "23")
      imported!(site, admin)

      stub!(%{
        "/wp-json/wp/v2/menu-items" => menu_items_with(%{88 => %{"title" => %{"raw" => "Start"}}})
      })

      run = imported!(site, admin)

      assert outcomes(run)["22"] == {:updated, nil}
      assert {"Start", {:navigate, "/"}} in links(site)
      assert length(footer_links(site)) == 3
    end

    test "writes a menu the admin sends to a component as a component named from its slug, and leaves the layout alone",
         %{site: site, admin: admin} do
      layout = layout!(site)
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, "component", "23")

      run = imported!(site, admin)
      footer = component(site, "nav-footer")

      assert outcomes(run)["23"] == {:created, "old_address: RSS feed"}

      assert component_links(footer) == [
               {"Contact", {:navigate, "/contact"}},
               {"Docs", {:navigate, "/docs"}},
               {"RSS feed", {:href, "http://localhost:8089/feed/"}}
             ]

      assert footer_links(site) == []
      assert length(links(site)) == 14
      assert template(site) != layout.template

      item =
        MigrationItem
        |> Ash.read!(tenant: site.id, authorize?: false)
        |> Enum.find(&(&1.source_kind == "menu" and &1.source_id == "23"))

      assert {item.target_id, item.target_resource} == {footer.id, inspect(Component)}

      assert %{record_paths: %{admin: admin_path, name: "nav-footer"}} =
               Ash.load!(item, :record_paths, actor: admin, tenant: site.id)

      assert admin_path =~ "/admin/dashboard/runtime/components"
    end

    test "keeps a nested block menu's groups in its component, as the header draws them",
         %{site: site, admin: admin} do
      layout!(site)
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, "component", "navigation-105")

      imported!(site, admin)

      {:ok, tree} =
        "nav-main-navigation"
        |> then(&component(site, &1))
        |> Map.fetch!(:template)
        |> Tree.parse()

      buttons = for %{tag: "button"} = node <- Tree.walk(tree), do: Map.new(node.attrs)["id"]

      assert buttons == [{:string, "site-nav-2-button"}]
    end

    test "writes a component again when the source changes it, and keeps it once an admin edits it",
         %{site: site, admin: admin} do
      layout!(site)
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, "component", "23")
      imported!(site, admin)
      assert outcomes(imported!(site, admin))["23"] == {:skipped, "unchanged"}

      stub!(%{
        "/wp-json/wp/v2/menu-items" =>
          menu_items_with(%{102 => %{"title" => %{"raw" => "Reach us"}}})
      })

      assert outcomes(imported!(site, admin))["23"] == {:updated, "old_address: RSS feed"}

      assert {"Reach us", {:navigate, "/contact"}} in component_links(
               component(site, "nav-footer")
             )

      component(site, "nav-footer")
      |> Ash.Changeset.for_update(:update, %{description: "Mine"}, actor: admin, tenant: site.id)
      |> Ash.update!()

      stub!(%{
        "/wp-json/wp/v2/menu-items" =>
          menu_items_with(%{102 => %{"title" => %{"raw" => "Write"}}})
      })

      assert outcomes(imported!(site, admin))["23"] == {:skipped, "edited_in_cms"}
    end

    test "waits when the site already has a component with the name, and connects to it once the admin decides so",
         %{site: site, admin: admin} do
      layout!(site)

      own =
        create_component!(site_id: site.id, name: "nav-footer", template: "<p>Mine</p>")

      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, "component", "23")

      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      assert outcomes(run)["23"] == {:undecided, "component_name_taken"}

      decide!(site, admin, "keep", "23")
      run = imported!(site, admin)

      assert outcomes(run)["23"] == {:skipped, "connected"}
      assert component(site, "nav-footer").template == own.template
    end

    test "keeps the rest of the layout, and groups an item's links under it as the core draws a group",
         %{site: site, admin: admin} do
      layout!(site)
      imported!(site, admin)

      {:ok, tree} = site |> template() |> Tree.parse()
      nodes = Tree.walk(tree)

      assert Enum.any?(nodes, &({"component_name", {:string, "site-footer"}} in &1.attrs))
      assert Enum.any?(nodes, &(&1.kind == :eex and &1.text == "@inner_content"))

      buttons = for %{tag: "button"} = node <- nodes, do: Map.new(node.attrs)["id"]
      assert buttons == for(n <- 2..4, do: {:string, "site-nav-#{n}-button"})
    end

    test "keeps the old address of what was left out or not imported, and the report names it",
         %{site: site, admin: admin} do
      layout!(site)
      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      leave_out!(site, admin, "page", "25")

      run = import!(run, admin)

      assert outcomes(run)["22"] == {:updated, "old_address: Team, Leadership"}

      assert {"Team", {:href, "http://localhost:8089/about/team/"}} in links(site)

      assert {"Leadership", {:href, "http://localhost:8089/about/team/leadership/"}} in links(
               site
             )

      assert {"Contact", {:navigate, "/contact"}} in links(site)
    end

    test "keeps a custom link's address, a path on the site too, and leaves out one with no address",
         %{site: site, admin: admin} do
      layout!(site)

      stub!(%{
        "/wp-json/wp/v2/menu-items" =>
          menu_items_with(%{88 => %{"url" => "/feed/"}, 101 => %{"url" => "#"}})
      })

      imported!(site, admin)

      assert {"Home", {:href, "/feed/"}} in links(site)
      refute Enum.any?(links(site), &(elem(&1, 0) == "Elixir"))
    end

    test "leaves a header with links of its own for an admin's decision, and keeps them", %{
      site: site,
      admin: admin
    } do
      layout = layout!(site, own_links())
      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      assert outcomes(run)["22"] == {:undecided, "header_has_links"}

      run = import!(run, admin)

      assert outcomes(run)["22"] == {:undecided, "header_has_links"}
      assert template(site) == layout.template
    end

    test "keeps the header's own links once an admin decides so, on every later run", %{
      site: site,
      admin: admin
    } do
      layout = layout!(site, own_links())
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, "keep")

      for _run <- 1..2,
          do: assert(outcomes(imported!(site, admin))["22"] == {:skipped, "site_own_kept"})

      assert template(site) == layout.template
    end

    test "replaces the header's own links with the main menu once an admin decides so", %{
      site: site,
      admin: admin
    } do
      layout!(site, own_links())
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, "import")

      run = imported!(site, admin)

      assert outcomes(run)["22"] == {:updated, nil}
      refute Enum.any?(links(site), &(elem(&1, 0) == "Pricing"))
      assert [{"Home", {:navigate, "/"}} | _] = links(site)
      assert outcomes(imported!(site, admin))["22"] == {:skipped, "unchanged"}
    end

    test "leaves the menu out of a site with no layout header", %{site: site, admin: admin} do
      assert outcomes(imported!(site, admin))["22"] == {:skipped, "no_layout"}

      layout!(site, ~S(<main>{@inner_content}</main>))

      assert outcomes(imported!(site, admin))["22"] == {:skipped, "no_layout"}
    end

    test "fails the menu for an admin who may not change layouts", %{site: site} do
      layout = layout!(site)
      admin = migration_admin!(site, List.delete(@admin, "admin:dashboard:runtime:layout"))

      run = imported!(site, admin)

      assert outcomes(run)["22"] == {:failed, "forbidden"}
      assert template(site) == layout.template
    end
  end

  describe "links to pages that are not live" do
    @drafts "draft_pages: About, Team, Leadership, Contact, Blog, Docs, Getting started"

    test "leave the main menu for an admin's decision, naming them, in the dry run and the import",
         %{site: site, admin: admin} do
      layout = layout!(site)
      run = site |> wordpress_run!(admin, %{}) |> dry_run!(admin)

      assert outcomes(run)["22"] == {:undecided, @drafts}

      assert MishkaCmsMigration.MigrationRun.reason_label(@drafts) ==
               "Links to pages that are not live: About, Team, Leadership, Contact, Blog, Docs, Getting started"

      assert outcomes(import!(run, admin))["22"] == {:undecided, @drafts}
      assert template(site) == layout.template
      assert live_paths(site) == MapSet.new()
    end

    test "leave out a page whose address another live page answers, as the Blog's /:lang/blog answers /blog",
         %{site: site, admin: admin} do
      layout!(site)

      create_page!(
        site_id: site.id,
        path: "/:lang/blog",
        extra: %{"serves_all_languages" => true}
      )

      run = site |> wordpress_run!(admin, %{}) |> dry_run!(admin)
      without_blog = String.replace(@drafts, " Blog,", "")

      assert outcomes(run)["22"] == {:undecided, without_blog}
      assert outcomes(import!(run, admin))["22"] == {:undecided, without_blog}
    end

    test "Publish the linked pages puts them live and writes the menu with its links to them",
         %{site: site, admin: admin} do
      layout!(site)

      run = drafts!(site, admin, "import")

      assert outcomes(run)["22"] == {:updated, nil}

      assert MapSet.new(
               ~w(/about /about/team /about/team/leadership /contact /blog /docs /docs/getting-started)
             ) == live_paths(site)

      assert {"Team", {:navigate, "/about/team"}} in links(site)
    end

    test "Leave those links out of the menu writes the menu without them and keeps the pages drafts",
         %{site: site, admin: admin} do
      layout!(site)

      run = drafts!(site, admin, "keep")

      assert outcomes(run)["22"] == {:updated, nil}
      assert live_paths(site) == MapSet.new()

      assert links(site) == [
               {"Home", {:navigate, "/"}},
               {"News", {:navigate, "/blog/category/news"}},
               {"Releases", {:navigate, "/blog/category/releases"}},
               {"Announcements", {:navigate, "/blog/category/announcements"}},
               {"Tutorials", {:navigate, "/blog/category/tutorials"}},
               {"Start here", {:navigate, "/blog/welcome-to-the-mishka-test-blog"}},
               {"Elixir", {:href, "https://elixir-lang.org/", "_blank"}}
             ]
    end
  end

  describe "links and the site's language addresses" do
    defp prefix_all!(site),
      do:
        MishkaCmsCore.Settings.put("site.language_urls", "prefix_all",
          site_id: site.id,
          category: "general"
        )

    defp polylang! do
      index = recorded("index")
      body = index |> Map.update!("namespaces", &["pll/v1" | &1]) |> Jason.encode!()
      stub!(%{"/wp-json/" => {"application/json", body}})
    end

    test "a site that prefixes every language leaves the main menu for a decision, in the dry run and the import",
         %{site: site, admin: admin} do
      layout = layout!(site)
      prefix_all!(site)
      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      assert outcomes(run)["22"] == {:undecided, "language_urls: prefix_all"}
      assert outcomes(import!(run, admin))["22"] == {:undecided, "language_urls: prefix_all"}
      assert template(site) == layout.template
    end

    test "a source that runs a language plugin does too, whatever the site's mode",
         %{site: site, admin: admin} do
      layout!(site)
      polylang!()
      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      assert run.extra["languages"] == "polylang"
      assert outcomes(run)["22"] == {:undecided, "language_urls: polylang"}

      assert MishkaCmsMigration.MigrationRun.reason_label("language_urls: polylang") =~
               "Polylang"
    end

    test "Write links for the site's current mode writes the menu with the site's addresses",
         %{site: site, admin: admin} do
      layout!(site)
      prefix_all!(site)
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, "import")

      run = imported!(site, admin)

      assert outcomes(run)["22"] == {:updated, nil}
      assert {"News", {:navigate, "/en/blog/category/news"}} in links(site)
    end

    test "Wait leaves the menu unwritten until the admin decides otherwise",
         %{site: site, admin: admin} do
      layout = layout!(site)
      prefix_all!(site)
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, "keep")

      run = imported!(site, admin)

      assert outcomes(run)["22"] == {:skipped, "waits_for_language_urls"}
      assert template(site) == layout.template
    end
  end

  describe "a second run" do
    test "leaves alone a menu WordPress did not change", %{site: site, admin: admin} do
      layout!(site)
      imported!(site, admin)

      assert outcomes(imported!(site, admin))["22"] == {:skipped, "unchanged"}
    end

    test "writes a menu WordPress changed in place of the links it wrote, unless an admin changed the layout since",
         %{site: site, admin: admin} do
      layout = layout!(site)
      imported!(site, admin)

      stub!(%{
        "/wp-json/wp/v2/menu-items" => menu_items_with(%{88 => %{"title" => %{"raw" => "Start"}}})
      })

      run = imported!(site, admin)

      assert outcomes(run)["22"] == {:updated, nil}
      assert [{"Start", {:navigate, "/"}}, {"About", _} | _] = links(site)
      assert Enum.count(links(site), &(elem(&1, 0) == "Elixir")) == 1

      layout
      |> Ash.Changeset.for_update(:update, %{description: "Ours now"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      stub!(%{
        "/wp-json/wp/v2/menu-items" => menu_items_with(%{88 => %{"title" => %{"raw" => "Begin"}}})
      })

      run = imported!(site, admin)

      assert outcomes(run)["22"] == {:skipped, "edited_in_cms"}
      assert [{"Start", _} | _] = links(site)
    end
  end
end
