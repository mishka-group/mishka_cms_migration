# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.KeepAddressesTest do
  @moduledoc """
  An import that keeps the WordPress addresses, against what the seeded WordPress answered
  (`/%year%/%monthnum%/%postname%/`, a posts page at `/blog/`): the site's Blog pages move to the
  source's structure and bases before any post is written, each post is served at its WordPress
  address, a Persian one included, and only what the site does not serve as it was is redirected.
  A dry run moves nothing, a second import moves nothing again, and the list of posts goes where the
  admin chose.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 1]

  require Ash.Query

  alias MishkaBlog.BlogPost
  alias MishkaCmsCore.Runtime.{Page, Redirect, Redirects}
  alias MishkaCmsCore.Settings
  alias MishkaCmsMigration.MigrationItem
  alias MishkaCmsMigration.Targets.PostRedirect

  @connection %{"url" => "http://localhost:8089", "user" => "admin"}
  @admin [
    "admin:dashboard:migration",
    "admin:dashboard:blog:post",
    "admin:dashboard:setting",
    "admin:dashboard:runtime:redirect",
    "admin:dashboard:runtime:page"
  ]
  @posts_page %{
    "/wp-json/wp/v2/pages/23" => {"application/json", ~s({"link":"http://localhost:8089/news/"})}
  }
  @release "/2025/12/release-1-0-announcement"
  @persian "/2026/02/نصب-وردپرس-روی-سرور"
  @polylang_export Path.expand("../../fixtures/wordpress/wxr/polylang.xml", __DIR__)

  setup do
    stub!(@posts_page)
    site = create_site!()
    forget_settings(~w(site.languages), [site.id])
    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
    blog_routed!(site)
    %{site: site, admin: migration_admin!(site, @admin)}
  end

  defp wordpress_run!(site, admin, options),
    do:
      %{source: "wordpress", connection: @connection, secret: "app password", options: options}
      |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)

  defp imported!(site, admin, options \\ %{}),
    do: site |> wordpress_run!(admin, options) |> dry_run!(admin) |> import!(admin)

  defp blog_pages(site),
    do:
      Page
      |> Ash.Query.filter(section == "blog")
      |> Ash.read!(tenant: site.id, authorize?: false)
      |> Map.new(&{&1.extra["record"] || &1.path, &1})

  defp outcomes(run, kind) do
    for %{kind: ^kind} = entry <- run.report.entries,
        into: %{},
        do: {entry.source_id, {entry.outcome, entry.reason}}
  end

  # What a dry run and an import can both say of an item: a write's outcome, whose note only the
  # import's write can complete, and why anything else is held.
  defp settled(%{outcome: outcome}) when outcome in [:created, :updated], do: {outcome, nil}
  defp settled(%{outcome: outcome, reason: reason}), do: {outcome, reason}

  defp edit_rule!(site, admin, from, to),
    do:
      Redirect
      |> Ash.read!(tenant: site.id, authorize?: false)
      |> Enum.find(&(&1.from_path == from))
      |> Ash.Changeset.for_update(:update, %{to: to}, actor: admin, tenant: site.id)
      |> Ash.update!()

  defp decide!(site, admin, source_id, choice),
    do:
      MigrationItem
      |> Ash.read!(tenant: site.id, authorize?: false)
      |> Enum.find(&(&1.source_kind == "post_redirect" and &1.source_id == source_id))
      |> MishkaCmsMigration.decide_item!(choice, actor: admin, tenant: site.id)

  defp kind_counts(run, kind), do: Enum.find(run.report.kinds, &(&1.kind == kind))

  defp rules(site) do
    for rule <- Ash.read!(Redirect, tenant: site.id, authorize?: false),
        into: %{},
        do: {{rule.from_path, rule.from_query}, rule.to}
  end

  describe "keeping the WordPress addresses" do
    test "a dry run moves no Blog page and writes no redirect", %{site: site, admin: admin} do
      before = blog_pages(site)
      site |> wordpress_run!(admin, %{}) |> dry_run!(admin)

      assert blog_pages(site) == before
      assert rules(site) == %{}
    end

    test "an import serves each post at its WordPress address and redirects only what moved",
         %{site: site, admin: admin} do
      run = imported!(site, admin)
      pages = blog_pages(site)

      assert {pages["blog:post"].path, pages["blog:category"].path, pages["blog:tag"].path,
              pages["blog:author"].path} ==
               {"/:lang/:year/:monthnum/:slug", "/:lang/category/*slug", "/:lang/tag/:slug",
                "/:lang/author/:slug"}

      posts =
        BlogPost |> Ash.read!(tenant: site.id, authorize?: false) |> Map.new(&{&1.number, &1})

      assert posts[44].slug == "release-1-0-announcement"

      redirects = outcomes(run, "post_redirect")
      assert redirects["44"] == {:skipped, "same_address"}
      assert redirects["36"] == {:skipped, "same_address"}
      assert redirects["39"] == {:skipped, "no_old_address"}

      rules = rules(site)
      assert rules[{"/", "p=44"}] == @release
      assert {:ok, @persian} = rules[{"/", "p=36"}] |> Redirects.normalize_path()
      refute is_map_key(rules, {@release, nil})

      # A nested category is served at its chain, as WordPress served it.
      assert redirects["category:3"] == {:skipped, "same_address"}
      refute is_map_key(rules, {"/category/news/releases", nil})
      assert rules[{"/category/news/releases/feed", nil}] == "/category/news/releases"

      # A post behind a password is a draft here: nothing is redirected to it.
      assert redirects["42"] == {:skipped, "not_served"}
      assert redirects["42?p"] == {:skipped, "not_served"}
      refute Enum.any?(Map.values(rules), &(&1 =~ "password-protected-preview"))

      for path <- ~w(/feed /feed/atom /rss2 /2026/02 /2026/02/feed),
          do: assert(rules[{path, nil}] == "/news", path)

      assert rules[{"/wp-sitemap.xml", nil}] == "/sitemap.xml"
      assert rules[{"/news/feed", nil}] == "/news"
      assert rules[{"/page/2", nil}] == "/news?page=2"
    end

    test "an author with no blogger on the site is sent to the list of posts", %{
      site: site,
      admin: admin
    } do
      run = imported!(site, admin)
      rules = rules(site)

      authors =
        for {"user:" <> _ = id, outcome} <- outcomes(run, "post_redirect"), do: {id, outcome}

      assert authors != []

      for {"user:" <> id, _outcome} <- authors, !String.contains?(id, ["?", "/"]) do
        user =
          Enum.find(MishkaCmsMigration.Test.WordPress.recorded("users"), &("#{&1["id"]}" == id))

        from = "/author/" <> user["slug"]

        assert rules[{from, nil}] in [nil, "/news"]

        assert rules[{from, nil}] == "/news" ==
                 is_nil(
                   Ash.read_first!(MishkaBlog.Blogger |> Ash.Query.filter(slug == ^user["slug"]),
                     tenant: site.id,
                     authorize?: false
                   )
                 )
      end
    end

    test "a first dry run plans each page, term, post and redirect as its import leaves it", %{
      site: site,
      admin: admin
    } do
      dry = site |> wordpress_run!(admin, %{}) |> dry_run!(admin)
      planned = Map.new(dry.report.entries, &{{&1.kind, &1.source_id}, &1.outcome})
      run = import!(dry, admin)

      # A file is downloaded only in the import, and the stub serves some no bytes.
      differ =
        for %{kind: kind, source_id: id, outcome: outcome} <- run.report.entries,
            kind in ~w(category tag page post post_redirect),
            not String.starts_with?(id, "media:"),
            planned[{kind, id}] != outcome,
            do: {kind, id, planned[{kind, id}], outcome}

      assert differ == []
    end

    test "a first dry run of an export plans the redirect of a Persian term's address as its import leaves it",
         %{site: site, admin: admin} do
      staged = Path.join(System.tmp_dir!(), "gervaz_#{System.unique_integer([:positive])}.xml")
      File.cp!(@polylang_export, staged)
      on_exit(fn -> File.rm(staged) end)

      dry =
        %{source: "wordpress_file", file: [%{path: staged, client_name: "export.xml"}]}
        |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)
        |> dry_run!(admin)

      planned = Map.new(dry.report.entries, &{{&1.kind, &1.source_id}, settled(&1)})
      run = import!(dry, admin)

      # An export gives سفر (#32) the address /category/سفر/, and the site serves it under /fa.
      assert planned[{"post_redirect", "category:32"}] == {:created, nil}

      differ =
        for %{kind: "post_redirect", source_id: id} = entry <- run.report.entries,
            not String.starts_with?(id, "media:"),
            planned[{"post_redirect", id}] != settled(entry),
            do: {id, planned[{"post_redirect", id}], settled(entry)}

      assert differ == []
    end

    test "a second import moves no page again and writes no redirect again", %{
      site: site,
      admin: admin
    } do
      imported!(site, admin)
      before = blog_pages(site)
      again = imported!(site, admin)

      assert blog_pages(site) == before

      assert %{created: 0, updated: 0, failed: 0} =
               again.report.kinds |> Enum.find(&(&1.kind == "post_redirect"))
    end

    test "a second dry run plans a redirect only for what its own walk plans to write", %{
      site: site,
      admin: admin
    } do
      imported!(site, admin)
      again = site |> wordpress_run!(admin, %{}) |> dry_run!(admin)

      planned_media =
        for {id, {:created, _reason}} <- outcomes(again, "media"), into: MapSet.new(), do: id

      created = for {id, {:created, _reason}} <- outcomes(again, "post_redirect"), do: id

      # The files the stub serves no bytes for failed in the import, and the dry run plans them again.
      assert Enum.all?(created, fn "media:" <> rest ->
               rest |> String.split(~r{[?/]}) |> hd() |> then(&MapSet.member?(planned_media, &1))
             end)

      assert outcomes(again, "post_redirect")["44"] == {:skipped, "same_address"}
    end

    # A first run under /blog redirects each WordPress address there; a run that keeps the
    # addresses serves the post at that address again, so the rule would send it to a 404.
    test "a run that keeps the addresses takes back the redirects an earlier /blog run wrote", %{
      site: site,
      admin: admin
    } do
      imported!(site, admin, %{post_address: "blog", blog_pages: "create"})
      assert rules(site)[{@release, nil}] == "/blog/release-1-0-announcement"
      assert rules(site)[{"/", "p=44"}] == "/blog/release-1-0-announcement"

      run = imported!(site, admin, %{post_address: "keep", blog_pages: "use"})

      redirects = outcomes(run, "post_redirect")
      assert redirects["44"] == {:skipped, "same_address"}
      refute is_map_key(rules(site), {@release, nil})

      # The rule on the post's old query follows the post to where it is served now.
      assert rules(site)[{"/", "p=44"}] == @release

      # The rule is archived, as an admin's Archive leaves it, and a later run asks nothing of it.
      assert %{results: [%{from_path: @release}]} =
               Redirect
               |> Ash.Query.for_read(:archived, %{}, tenant: site.id, authorize?: false)
               |> Ash.Query.filter(from_path == ^@release)
               |> Ash.read!()

      again = imported!(site, admin, %{post_address: "keep", blog_pages: "use"})
      assert outcomes(again, "post_redirect")["44"] == {:skipped, "same_address"}
      assert %{updated: 0, failed: 0, undecided: 0} = kind_counts(again, "post_redirect")
    end

    test "a rule is out of date unless it sends to the post's own path, query and host", %{
      site: site,
      admin: admin
    } do
      run = imported!(site, admin)

      {:ok, item} =
        MishkaCmsMigration.Source.Item.build(%{
          kind: "post_redirect",
          source_id: "p=44",
          attrs: %{"from" => "/", "query" => "p=44", "to" => %{"kind" => "post", "id" => "44"}}
        })

      context = %{mode: :import, actor: admin, site_id: site.id, source_host: run.source_host}

      outdated = fn to ->
        rule = %Redirect{from_path: "/", from_query: "p=44", to: to}
        PostRedirect.outdated([{item, rule, :written}], context) == %{"p=44" => {:updated, rule}}
      end

      refute outdated.(@release)
      refute outdated.(@release <> "/")
      assert outdated.("//evil.com" <> @release)
      assert outdated.("https://evil.com" <> @release)
      assert outdated.(@release <> "?p=44")
      assert outdated.("/blog/release-1-0-announcement")
    end

    # The admin's edit is never undone on the import's own: the item waits for their decision, in
    # the dry run and in the import, and their answer holds for every later run.
    test "a redirect an admin edited that hides the post's address waits; Archive takes it back",
         %{
           site: site,
           admin: admin
         } do
      imported!(site, admin, %{post_address: "blog", blog_pages: "create"})
      edit_rule!(site, admin, @release, "/about-us")

      planned = site |> wordpress_run!(admin, %{}) |> dry_run!(admin)
      assert outcomes(planned, "post_redirect")["44"] == {:undecided, "redirect_edited"}

      run = imported!(site, admin, %{post_address: "keep", blog_pages: "use"})

      assert outcomes(run, "post_redirect")["44"] == {:undecided, "redirect_edited"}
      assert rules(site)[{@release, nil}] == "/about-us"
      assert rules(site)[{"/", "p=44"}] == @release

      planned = site |> wordpress_run!(admin, %{}) |> dry_run!(admin)
      assert outcomes(planned, "post_redirect")["44"] == {:undecided, "redirect_edited"}

      decide!(site, admin, "44", "import")

      run = imported!(site, admin)
      assert outcomes(run, "post_redirect")["44"] == {:skipped, "same_address"}
      refute is_map_key(rules(site), {@release, nil})

      again = imported!(site, admin)
      assert outcomes(again, "post_redirect")["44"] == {:skipped, "same_address"}
      assert %{undecided: 0, updated: 0, failed: 0} = kind_counts(again, "post_redirect")
    end

    test "a redirect an admin edited that hides the post's address is kept when they say Keep", %{
      site: site,
      admin: admin
    } do
      imported!(site, admin, %{post_address: "blog", blog_pages: "create"})
      edit_rule!(site, admin, @release, "/about-us")
      imported!(site, admin, %{post_address: "keep", blog_pages: "use"})

      decide!(site, admin, "44", "keep")

      for _run <- 1..2 do
        run = imported!(site, admin)
        assert outcomes(run, "post_redirect")["44"] == {:skipped, "edited_in_cms"}
        assert rules(site)[{@release, nil}] == "/about-us"
        assert kind_counts(run, "post_redirect").undecided == 0
      end
    end

    test "a redirect an admin sent elsewhere waits, and Send it there writes it to the post", %{
      site: site,
      admin: admin
    } do
      options = %{post_address: "blog", blog_pages: "create"}
      run = imported!(site, admin, options)
      edit_rule!(site, admin, @release, "/about-us")

      run = imported!(site, admin, options)
      assert outcomes(run, "post_redirect")["44"] == {:undecided, "redirect_edited"}
      assert rules(site)[{@release, nil}] == "/about-us"

      decide!(site, admin, "44", "import")

      run = imported!(site, admin, options)
      assert {:updated, _note} = outcomes(run, "post_redirect")["44"]
      assert rules(site)[{@release, nil}] == "/blog/release-1-0-announcement"

      again = imported!(site, admin, options)
      assert outcomes(again, "post_redirect")["44"] == {:skipped, "unchanged"}
    end

    test "a post whose address is a page of the site waits, and Import with another slug writes it",
         %{site: site, admin: admin} do
      create_page!(site_id: site.id, path: @release, active: true)
      blog_routed!(site)

      run = imported!(site, admin)
      assert outcomes(run, "post")["44"] == {:undecided, "address_taken"}

      MigrationItem
      |> Ash.read!(tenant: site.id, authorize?: false)
      |> Enum.find(&(&1.source_kind == "post" and &1.source_id == "44"))
      |> MishkaCmsMigration.decide_item!("import", actor: admin, tenant: site.id)

      run = imported!(site, admin)
      assert {:created, note} = outcomes(run, "post")["44"]
      assert note =~ "another_slug"

      assert [%{slug: "release-1-0-announcement-44"}] =
               BlogPost
               |> Ash.Query.filter(number == 44)
               |> Ash.read!(tenant: site.id, authorize?: false)
    end
  end

  describe "the posts list page" do
    test "WordPress's posts page serves the list, and that page is not imported", %{
      site: site,
      admin: admin
    } do
      run = imported!(site, admin)

      assert %{path: "/:lang/news", extra: %{"record" => "blog:home"}} =
               blog_pages(site)["blog:home"]

      assert outcomes(run, "page")["23"] == {:skipped, "posts_list_here"}
    end

    test "the front page serves the list", %{site: site, admin: admin} do
      imported!(site, admin, %{posts_page: "front"})
      assert blog_pages(site)["blog:home"].path == "/:lang"
    end

    test "a page the admin picks gives the list its address and is archived", %{
      site: site,
      admin: admin
    } do
      picked = create_page!(site_id: site.id, path: "/journal", active: true)
      imported!(site, admin, %{posts_page: picked.id})

      assert blog_pages(site)["blog:home"].path == "/:lang/journal"
      refute Enum.any?(Ash.read!(Page, tenant: site.id, authorize?: false), &(&1.id == picked.id))
    end

    test "the Blog's /blog keeps the list where it is", %{site: site, admin: admin} do
      imported!(site, admin, %{posts_page: "blog", post_address: "blog"})
      pages = blog_pages(site)

      assert (pages["blog:home"] || pages["/:lang/blog"]).path == "/:lang/blog"
      assert pages["blog:post"].path == "/:lang/blog/:slug"
    end
  end
end
