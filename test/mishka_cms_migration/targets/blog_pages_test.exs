# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.BlogPagesTest do
  @moduledoc """
  The run's Blog pages choice, against what the seeded WordPress answered
  (`/%year%/%monthnum%/%postname%/`, a posts page at `/news/`): `"use"` creates the Blog pages a
  site is missing where the run serves posts and moves the ones it has, `"create"` creates them at
  the Blog's defaults and moves nothing. A dry run plans exactly what the import then does, a second
  import creates and moves nothing, and a page of the admin's own at a Blog page's path is left
  alone while that Blog page waits.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 1]

  require Ash.Query

  alias MishkaBlog.{Address, Provision}
  alias MishkaCmsCore.Runtime.{ExtensionProvision, Page, Redirect}
  alias MishkaCmsCore.Settings

  @connection %{"url" => "http://localhost:8089", "user" => "admin"}
  @admin [
           "admin:dashboard:migration",
           "admin:dashboard:blog:post",
           "admin:dashboard:setting",
           "admin:dashboard:runtime:redirect"
         ] ++ ExtensionProvision.required(Provision.manifest())
  @posts_page %{
    "/wp-json/wp/v2/pages/23" => {"application/json", ~s({"link":"http://localhost:8089/news/"})}
  }
  @release "/2025/12/release-1-0-announcement"
  @post "/:lang/blog/:slug"
  @tags "/:lang/blog/tags"

  setup do
    stub!(@posts_page)
    site = create_site!()
    forget_settings(~w(site.languages), [site.id])
    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
    site_routed!(site)
    %{site: site, admin: migration_admin!(site, @admin)}
  end

  defp run!(site, admin, options),
    do:
      %{source: "wordpress", connection: @connection, secret: "app password", options: options}
      |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)

  defp imported!(site, admin, options \\ %{}),
    do: site |> run!(admin, options) |> dry_run!(admin) |> import!(admin)

  defp blog_pages(site),
    do:
      Page
      |> Ash.Query.filter(section == "blog")
      |> Ash.read!(tenant: site.id, authorize?: false)
      |> Map.new(&{&1.extra["record"] || &1.path, &1.path})

  defp steps(run), do: Map.new(run.extra["blog_pages"], &{&1["page"], {&1["action"], &1["path"]}})

  defp rules(site) do
    for rule <- Ash.read!(Redirect, tenant: site.id, authorize?: false),
        into: %{},
        do: {{rule.from_path, rule.from_query}, rule.to}
  end

  describe "a site with no Blog pages" do
    test "use creates every one where the run serves posts, at the WordPress addresses", %{
      site: site,
      admin: admin
    } do
      run = imported!(site, admin)
      pages = blog_pages(site)

      assert map_size(pages) == length(Provision.page_paths())

      assert {pages["blog:post"], pages["blog:category"], pages["blog:home"], pages[@tags]} ==
               {"/:lang/:year/:monthnum/:slug", "/:lang/category/*slug", "/:lang/news", @tags}

      assert Enum.all?(run.extra["blog_pages"], &(&1["action"] == "create"))
      assert Address.path(site.id, "blog:post", "en") == {:ok, "/:lang/:year/:monthnum/:slug"}

      redirects =
        for %{kind: "post_redirect", source_id: id, outcome: outcome, reason: reason} <-
              run.report.entries,
            into: %{},
            do: {id, {outcome, reason}}

      assert redirects["44"] == {:skipped, "same_address"}
      assert rules(site)[{"/", "p=44"}] == @release
    end

    test "create puts every one at the Blog's defaults, and the WordPress address is redirected",
         %{site: site, admin: admin} do
      imported!(site, admin, %{blog_pages: "create"})
      pages = blog_pages(site)

      assert {pages["blog:post"], pages["blog:home"]} == {@post, "/:lang/blog"}
      assert rules(site)[{@release, nil}] == "/blog/release-1-0-announcement"
    end

    test "a dry run writes nothing and plans what the import then does", %{
      site: site,
      admin: admin
    } do
      dry = site |> run!(admin, %{}) |> dry_run!(admin)

      assert blog_pages(site) == %{}
      assert length(dry.extra["blog_pages"]) == length(Provision.page_paths())

      run = import!(dry, admin)
      assert run.extra["blog_pages"] == dry.extra["blog_pages"]
    end

    test "a second import creates and moves nothing", %{site: site, admin: admin} do
      imported!(site, admin)
      before = blog_pages(site)
      again = imported!(site, admin)

      assert blog_pages(site) == before
      assert again.extra["blog_pages"] == []
    end

    test "a page of the admin's own at a Blog page's address is left, and that Blog page waits",
         %{site: site, admin: admin} do
      own = create_page!(site_id: site.id, path: "/news", active: true)
      dry = site |> run!(admin, %{}) |> dry_run!(admin)
      run = import!(dry, admin)

      assert steps(run)["/:lang/blog"] == {"taken", "/:lang/news"}
      assert run.extra["blog_pages"] == dry.extra["blog_pages"]
      refute Map.has_key?(blog_pages(site), "blog:home")
      assert blog_pages(site)["blog:post"] == "/:lang/:year/:monthnum/:slug"
      assert Ash.get!(Page, own.id, tenant: site.id, authorize?: false).path == "/news"
    end

    test "an admin who may not set up the Blog's pages gets none, and the plan says so", %{
      site: site
    } do
      admin = migration_admin!(site, @admin -- ["admin:dashboard:runtime:component"])
      dry = site |> run!(admin, %{}) |> dry_run!(admin)
      run = import!(dry, admin)

      assert Enum.all?(run.extra["blog_pages"], &(&1["action"] == "not_allowed"))
      assert run.extra["blog_pages"] == dry.extra["blog_pages"]
      assert blog_pages(site) == %{}
    end
  end

  describe "a site with some Blog pages" do
    setup %{site: site} do
      Provision.ensure_pages!(site, %{@post => @post, @tags => @tags})
      site_routed!(site)
      :ok
    end

    test "use creates the missing ones and moves the ones it has", %{site: site, admin: admin} do
      run = imported!(site, admin)
      steps = steps(run)

      assert steps[@post] == {"move", "/:lang/:year/:monthnum/:slug"}
      assert steps["/:lang/blog/category/:slug"] == {"create", "/:lang/category/*slug"}
      refute Map.has_key?(steps, @tags)

      assert map_size(blog_pages(site)) == length(Provision.page_paths())
      assert blog_pages(site)["blog:post"] == "/:lang/:year/:monthnum/:slug"
    end

    test "create moves none of them and creates the rest at the defaults", %{
      site: site,
      admin: admin
    } do
      run = imported!(site, admin, %{blog_pages: "create"})

      assert Enum.all?(run.extra["blog_pages"], &(&1["action"] == "create"))
      assert Enum.all?(run.extra["blog_pages"], &(&1["path"] == &1["page"]))
      assert blog_pages(site)["blog:post"] == @post
      assert map_size(blog_pages(site)) == length(Provision.page_paths())
    end
  end
end
