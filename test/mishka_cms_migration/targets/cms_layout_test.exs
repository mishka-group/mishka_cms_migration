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
  alias MishkaCmsCore.Runtime.{Layout, Page}
  alias MishkaCmsMigration.MigrationItem
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Targets.CmsLayout

  @connection %{"url" => "http://localhost:8089", "user" => "admin"}
  @admin [
    "admin:dashboard:migration",
    "admin:dashboard:runtime:page",
    "admin:dashboard:blog:post",
    "admin:dashboard:runtime:layout"
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

  defp decide!(site, admin, choice),
    do:
      MigrationItem
      |> Ash.read!(tenant: site.id, authorize?: false)
      |> Enum.find(&(&1.source_kind == "menu" and &1.source_id == "22"))
      |> MishkaCmsMigration.decide_item!(choice, actor: admin, tenant: site.id)

  defp menu_items_with(changes),
    do:
      {"application/json",
       Jason.encode!(
         for item <- recorded("menu-items"), do: Map.merge(item, changes[item["id"]] || %{})
       )}

  describe "a dry run" do
    test "plans the main menu over the layout's header and leaves the other menu out, writing nothing",
         %{site: site, admin: admin} do
      layout = layout!(site)

      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      assert outcomes(run) == %{
               "22" => {:updated, nil},
               "23" => {:skipped, "not_main_menu"}
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

      assert outcomes(run) == %{"22" => {:updated, nil}, "23" => {:skipped, "not_main_menu"}}

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
