# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.CmsPageTest do
  @moduledoc """
  A WordPress site's pages moved into the CMS's pages, against what the seeded WordPress answered:
  what a dry run plans, where an import writes each page and whether it is live, which page the site
  keeps as its own, what a second run does, and that a page's content is written as text and markup
  the page can never run. A row the seeded WordPress has no case for (a slug in another script, a
  hostile paragraph) comes from the fake source.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0, recorded: 1]

  alias MishkaCmsCore.Runtime.Authoring.Tree
  alias MishkaCmsCore.Runtime.{Page, Seo}
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Targets.CmsPage

  @connection %{"url" => "http://localhost:8089", "user" => "admin"}
  @admin ["admin:dashboard:migration", "admin:dashboard:runtime:page"]

  @paths %{
    "22" => "/",
    "23" => "/blog",
    "24" => "/about",
    "25" => "/about/team",
    "26" => "/about/team/leadership",
    "27" => "/docs",
    "28" => "/docs/getting-started",
    "29" => "/contact",
    "3" => "/privacy-policy",
    "30" => "/coming-soon",
    "31" => "/internal-notes"
  }
  @published ~w(22 23 24 25 26 27 28 29)

  setup do
    stub!()
    site = create_site!()
    %{site: site, admin: migration_admin!(site, @admin)}
  end

  defp wordpress_run!(site, admin, options \\ %{}) do
    %{source: "wordpress", connection: @connection, secret: "app password", options: options}
    |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)
  end

  defp imported!(site, admin, options \\ %{}),
    do: site |> wordpress_run!(admin, options) |> dry_run!(admin) |> import!(admin)

  defp counts(run) do
    run.report.kinds
    |> Enum.find(&(&1.kind == "page"))
    |> Map.take([:created, :updated, :skipped, :failed])
  end

  defp outcomes(run) do
    for %{kind: "page"} = entry <- run.report.entries,
        into: %{},
        do: {entry.source_id, {entry.outcome, entry.reason}}
  end

  defp pages(site),
    do: Page |> Ash.read!(tenant: site.id, authorize?: false) |> Map.new(&{&1.path, &1})

  defp by_source(pages), do: Map.new(@paths, fn {id, path} -> {id, pages[path]} end)

  defp fake_pages!(site, admin, rows) do
    for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)
    migrate!(site, admin, %{"page" => rows})
  end

  defp row(id, fields),
    do:
      Map.merge(
        %{
          "id" => id,
          "title" => "Page #{id}",
          "slug" => "page-#{id}",
          "permalink_template" => "http://old.example.com/%pagename%/",
          "content" => [%{"html" => "<p>Page #{id}</p>"}]
        },
        fields
      )

  defp change_in_wordpress! do
    Repo.query!(
      "UPDATE mishka_cms_migration_items SET content_hash = 'changed' WHERE source_kind = 'page'"
    )
  end

  defp rendered(template) do
    quoted =
      Phoenix.LiveView.TagEngine.compile(template,
        line: 1,
        indentation: 0,
        file: "page",
        caller: __ENV__,
        trim: true,
        tag_handler: Phoenix.LiveView.HTMLEngine
      )

    {rendered, _binding} = Code.eval_quoted(quoted, [assigns: %{}], __ENV__)
    rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
  end

  describe "a dry run" do
    test "plans every page at its old path, says which are not live at the source, and writes nothing in the CMS",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      assert counts(run) ==
               %{created: length(recorded("pages")), updated: 0, skipped: 0, failed: 0}

      assert %{"31" => {:created, "draft_from_private"}, "3" => {:created, nil}} = outcomes(run)
      assert pages(site) == %{}
      assert imported_items(site) == []
    end

    test "reports a page whose path the site has as skipped, and writes nothing in the CMS", %{
      site: site,
      admin: admin
    } do
      create_page!(site_id: site.id, path: "/contact")
      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      assert %{"29" => {:skipped, "path_taken"}, "24" => {:created, nil}} = outcomes(run)
      assert counts(run).skipped == 1
      assert map_size(pages(site)) == 1
    end
  end

  describe "an import as drafts" do
    test "writes every page at its old path, nested as WordPress nests it, and none of them live",
         %{site: site, admin: admin} do
      other = create_site!()
      run = imported!(site, admin)
      pages = pages(site)

      assert counts(run) ==
               %{created: length(recorded("pages")), updated: 0, skipped: 0, failed: 0}

      assert pages |> Map.keys() |> Enum.sort() == @paths |> Map.values() |> Enum.sort()
      assert pages |> Map.values() |> Enum.all?(&(&1.active == false))
      assert pages["/about/team/leadership"].title == "Leadership"
      assert pages["/privacy-policy"].title == "Privacy Policy"
      assert pages(other) == %{}
    end

    test "writes each page in the site's language, in the site's layout, for the builder to open",
         %{site: site, admin: admin} do
      layout = create_layout!(site_id: site.id, name: "site-main")
      imported!(site, admin)
      pages = pages(site)

      assert pages |> Map.values() |> Enum.map(& &1.language) |> Enum.uniq() ==
               [MishkaCmsCore.Runtime.Languages.primary(site.id)]

      assert pages |> Map.values() |> Enum.map(& &1.layout_id) |> Enum.uniq() == [layout.id]

      for {_path, page} <- pages do
        assert {:ok, %Tree{roots: [_wrapper]}} = Tree.parse(page.template)
      end
    end
  end

  describe "an import live at the old addresses" do
    test "puts the published pages live, and the others not, saying why", %{
      site: site,
      admin: admin
    } do
      run = imported!(site, admin, %{pages: "publish"})
      pages = site |> pages() |> by_source()

      assert counts(run).created == length(recorded("pages"))
      assert for({id, %{active: true}} <- pages, do: id) |> Enum.sort() == Enum.sort(@published)
      assert %{"3" => {:created, nil}, "31" => {:created, "draft_from_private"}} = outcomes(run)
      assert %{active: false} = pages["31"]
    end

    test "keeps the bodies WordPress gave, and the blocks nobody converted as text", %{
      site: site,
      admin: admin
    } do
      run = imported!(site, admin, %{pages: "publish"})
      pages = site |> pages() |> by_source()

      assert {:created, "unconverted: core/latest-posts"} = outcomes(run)["22"]

      home = LazyHTML.from_fragment(pages["22"].template)
      assert home |> LazyHTML.query("h1") |> LazyHTML.text() == "Welcome to the Mishka Test Blog"
      assert home |> LazyHTML.query("a") |> LazyHTML.attribute("href") |> length() == 2
    end
  end

  describe "a page the site has" do
    test "is kept as it is, and the WordPress page at its path is skipped with the reason", %{
      site: site,
      admin: admin
    } do
      own = create_page!(site_id: site.id, path: "/contact", title: "Our own contact")
      run = imported!(site, admin)

      assert %{"29" => {:skipped, "path_taken"}} = outcomes(run)
      assert counts(run) == %{created: 10, updated: 0, skipped: 1, failed: 0}

      kept = pages(site)["/contact"]
      assert {kept.id, kept.title, kept.template} == {own.id, "Our own contact", own.template}
    end

    test "leaves out the pages under it, which the walk does for any item whose parent is not imported",
         %{site: site, admin: admin} do
      create_page!(site_id: site.id, path: "/docs")
      run = imported!(site, admin)

      assert %{"27" => {:skipped, "path_taken"}, "28" => {:skipped, "parent_missing"}} =
               outcomes(run)

      refute is_map_key(pages(site), "/docs/getting-started")
    end

    test "answered by a pattern, as the Blog's /:lang/blog answers /blog, refuses the page live and has it as a draft",
         %{site: site, admin: admin} do
      create_page!(
        site_id: site.id,
        path: "/:lang/blog",
        extra: %{"serves_all_languages" => true}
      )

      assert %{"23" => {:created, nil}} = site |> imported!(admin) |> outcomes()
      assert %{active: false} = pages(site)["/blog"]

      other = create_site!()
      other_admin = migration_admin!(other, @admin)

      create_page!(
        site_id: other.id,
        path: "/:lang/blog",
        extra: %{"serves_all_languages" => true}
      )

      live = imported!(other, other_admin, %{pages: "publish"})
      assert {:failed, reason} = outcomes(live)["23"]
      assert reason =~ "already answers at /blog"
      refute is_map_key(pages(other), "/blog")
    end

    test "is found whether or not it is live, and a later run writes the page once the path is free",
         %{site: site, admin: admin} do
      own = create_page!(site_id: site.id, path: "/contact", active: false)
      assert %{"29" => {:skipped, "path_taken"}} = site |> imported!(admin) |> outcomes()

      own |> Ash.destroy!(actor: admin, tenant: site.id)
      assert %{"29" => {:created, _unconverted}} = site |> imported!(admin) |> outcomes()
      assert Map.has_key?(pages(site), "/contact")
    end
  end

  describe "a second run" do
    test "skips every page WordPress did not change as unchanged, and writes no second copy", %{
      site: site,
      admin: admin
    } do
      imported!(site, admin)
      again = imported!(site, admin)

      assert counts(again) ==
               %{created: 0, updated: 0, skipped: length(recorded("pages")), failed: 0}

      assert again |> outcomes() |> Map.values() |> Enum.uniq() == [{:skipped, "unchanged"}]
      assert map_size(pages(site)) == length(recorded("pages"))
    end

    test "writes over what WordPress changed, the choice to go live included, and keeps a page an admin edited",
         %{site: site, admin: admin} do
      imported!(site, admin)
      about = pages(site)["/about"]

      about
      |> Ash.Changeset.for_update(:update, %{title: "About, edited"},
        actor: admin,
        tenant: site.id
      )
      |> Ash.update!()

      change_in_wordpress!()
      third = imported!(site, admin, %{pages: "publish"})

      assert counts(third) ==
               %{created: 0, updated: length(recorded("pages")) - 1, skipped: 1, failed: 0}

      assert %{"24" => {:skipped, "edited_in_cms"}} = outcomes(third)
      pages = pages(site)
      assert pages["/about"].title == "About, edited"
      assert pages["/about"].id == about.id
      assert pages["/contact"].active
    end
  end

  describe "an address" do
    test "that is not ASCII is transliterated the way the CMS slugs a name, and the report says so",
         %{site: site, admin: admin} do
      run =
        fake_pages!(site, admin, [
          row(1, %{
            "slug" => "وردپرس",
            "permalink_template" => "http://old.example.com/about/%pagename%/"
          })
        ])

      assert %{"1" => {:created, "path_made_ascii"}} = outcomes(run)
      assert Map.keys(pages(site)) == ["/about/wrdprs"]
    end

    test "of a draft WordPress gave no slug yet comes from the slug it would generate", %{
      site: site,
      admin: admin
    } do
      run =
        fake_pages!(site, admin, [
          row(1, %{"slug" => "", "generated_slug" => "my-draft", "title" => "My draft"})
        ])

      assert counts(run).created == 1
      assert Map.keys(pages(site)) == ["/my-draft"]
    end
  end

  describe "a page not live at the source" do
    test "is told apart by why, and a page behind a password is one of them", %{
      site: site,
      admin: admin
    } do
      run =
        fake_pages!(site, admin, [
          row(1, %{"password" => "secret"}),
          row(2, %{"password" => ""})
        ])

      assert %{"1" => {:created, "draft_from_password"}, "2" => {:created, nil}} = outcomes(run)
    end

    test "that WordPress holds pending or scheduled is not live either" do
      for {status, note} <- [
            {"pending", "draft_from_pending"},
            {"future", "draft_from_future"},
            {"draft", nil},
            {"publish", nil}
          ] do
        {:ok, item} =
          Item.build(%{kind: "page", source_id: 1, title: "T", attrs: %{"status" => status}})

        assert CmsPage.note(item, %{}) == note
      end
    end
  end

  describe "files" do
    test "an import points a page's images and links to the site's files at their Media files, and keeps its other links",
         %{site: site} do
      admin = migration_admin!(site, @admin ++ ["admin:dashboard:runtime:media"])
      imported!(site, admin)

      media =
        MishkaCmsCore.Runtime.Media
        |> Ash.read!(tenant: site.id, authorize?: false)
        |> Map.new(&{&1.name, &1.relative_path})

      pages = pages(site)
      team = LazyHTML.from_fragment(pages["/about/team"].template)
      docs = LazyHTML.from_fragment(pages["/docs"].template)
      hrefs = docs |> LazyHTML.query("a") |> LazyHTML.attribute("href")

      assert team |> LazyHTML.query("img") |> LazyHTML.attribute("src") |> Enum.sort() ==
               Enum.sort([media["avatar-nadia"], media["avatar-omid"], media["avatar-shahryar"]])

      assert media["guide"] in hrefs
    end
  end

  describe "SEO" do
    test "an import keeps what Yoast SEO kept for a page as its SEO tags, its share image at its Media file",
         %{site: site} do
      admin = migration_admin!(site, @admin ++ ["admin:dashboard:runtime:media"])
      imported!(site, admin)

      cover =
        MishkaCmsCore.Runtime.Media
        |> Ash.read!(tenant: site.id, authorize?: false)
        |> Enum.find(&(&1.name == "cover"))

      pages = pages(site)
      about = Seo.stored_tags(pages["/about"].seo_tags)

      assert Seo.tag_value(about, "title") == "About the Mishka Test Blog"
      assert Seo.tag_value(about, "description") =~ "Who writes the Mishka Test Blog"
      assert Seo.tag_value(about, "og:image") == cover.relative_path
      assert Seo.tag_value(Seo.stored_tags(pages["/docs"].seo_tags), "title") =~ "Guides"
      assert pages["/"].seo_tags == []
    end
  end

  describe "links to pages" do
    defp hrefs(page),
      do:
        page.template
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("a")
        |> LazyHTML.attribute("href")

    test "an import points a page's links to the site's other pages at the paths they are written at",
         %{site: site, admin: admin} do
      imported!(site, admin)
      pages = pages(site)

      assert "/about/team" in hrefs(pages["/about"])
      assert "/contact" in hrefs(pages["/about"])
      assert ["/blog", "/docs"] -- hrefs(pages["/"]) == []
      assert "/docs/getting-started" in hrefs(pages["/docs"])

      old_site =
        for page <- Map.values(pages), href <- hrefs(page), href =~ "localhost:8089", do: href

      assert Enum.all?(old_site, &(&1 =~ "/wp-content/uploads/"))
    end

    test "a link keeps its query and fragment, and goes to the path however it was written" do
      html =
        ~s(<a href="http://localhost:8089/contact/?ref=nav#form">a</a>) <>
          ~s(<a href="/about/team/">b</a>) <>
          ~s(<a href="http://localhost:8089/?page_id=25&amp;x=1#staff">c</a>) <>
          ~s(<a href="http://localhost:8089/%d9%88%d8%b1%d8%af%d9%be%d8%b1%d8%b3/">d</a>)

      pages = %{
        "http://localhost:8089/contact/?ref=nav#form" => "http://localhost:8089/contact/",
        "/about/team/" => "http://localhost:8089/about/team/",
        "http://localhost:8089/?page_id=25&x=1#staff" => "http://localhost:8089/about/team/",
        "http://localhost:8089/%d9%88%d8%b1%d8%af%d9%be%d8%b1%d8%b3/" =>
          "http://localhost:8089/%d9%88%d8%b1%d8%af%d9%be%d8%b1%d8%b3/"
      }

      assert html
             |> CmsPage.relinked(pages)
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("a")
             |> LazyHTML.attribute("href") ==
               ["/contact?ref=nav#form", "/about/team", "/about/team#staff", "/wrdprs"]
    end

    test "a link to a page with no address of its own yet, and any other link, is kept as it is" do
      html =
        ~s(<a href="http://localhost:8089/?page_id=30">a</a>) <>
          ~s(<a href="http://localhost:8089/category/news/">b</a>) <>
          ~s(<a href="https://elixir-lang.org/">c</a>)

      pages = %{"http://localhost:8089/?page_id=30" => "http://localhost:8089/?page_id=30"}

      assert CmsPage.relinked(html, pages) == html
      assert CmsPage.relinked(html, %{}) == html
      assert CmsPage.relinked(html, nil) == html
    end
  end

  describe "content" do
    @hostile """
    <p>Total: {send(self(), :curly)} and <%= send(self(), :eex) %></p>\
    <pre><code>fn x -> {x} end</code></pre>\
    <img src="a.png" title="<%= send(self(), :attribute) %> {send(self(), :curly_attribute)}">\
    <script>var t = "<%= send(self(), :script) %>"; var o = {a: 1};</script>\
    <!-- <%= send(self(), :comment) %> -->\
    <p>after</p></div><div>outside\
    """

    test "with a { or a <% in it neither breaks the page nor runs", %{site: site, admin: admin} do
      run =
        fake_pages!(site, admin, [row(1, %{"content" => [%{"html" => @hostile}]})])

      assert counts(run).created == 1
      [page] = Map.values(pages(site))

      refute page.template =~ "<%"
      assert {:ok, %Tree{roots: [_wrapper]}} = Tree.parse(page.template)

      html = rendered(page.template)

      for ran <- [:curly, :eex, :attribute, :curly_attribute, :script, :comment],
          do: refute_received(^ran)

      assert html =~ "{send(self(), :curly)}"
      assert html =~ "{x}"
      assert html =~ "{a: 1}"
      assert html =~ "&lt;%= send(self(), :eex)"
    end

    test "with an attribute HEEx would read as code fails that page alone, and writes no page for it",
         %{site: site, admin: admin} do
      run =
        fake_pages!(site, admin, [
          row(1, %{"content" => [%{"html" => ~s(<div :if="true">hidden</div>)}]}),
          row(2, %{})
        ])

      assert %{"1" => {:failed, _reason}, "2" => {:created, nil}} = outcomes(run)
      assert Map.keys(pages(site)) == ["/page-2"]
    end

    test "that an unconverted block leaves as text with braces is shown as it was", %{
      site: site,
      admin: admin
    } do
      imported!(site, admin)
      template = site |> pages() |> Map.fetch!("/") |> Map.fetch!(:template)

      assert rendered(template) =~ "wp:latest-posts {&quot;postsToShow&quot;:3"
    end
  end

  describe "an admin who may not write pages" do
    test "fails the pages with the CMS's refusal and leaves out the ones under them, and writes none",
         %{site: site} do
      admin = migration_admin!(site, ["admin:dashboard:migration"])
      run = imported!(site, admin)

      assert %{created: 0, updated: 0} = counts(run)

      assert run |> outcomes() |> Map.values() |> Enum.uniq() |> Enum.sort() ==
               [{:failed, "forbidden"}, {:skipped, "parent_missing"}]

      assert pages(site) == %{}
    end
  end
end
