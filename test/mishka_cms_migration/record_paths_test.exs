# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.RecordPathsTest do
  @moduledoc """
  Where the CMS record of an imported item is, for each kind the extension writes: its place in the
  admin, found the way the list's own search finds it, and its page on the site only while the
  record is live.
  """
  use MishkaCmsMigration.DataCase, async: false

  alias MishkaBlog.{Blogger, BlogPost, Collection, Comment, Tag}
  alias MishkaCmsCore.Runtime.{Media, Page, Redirect}
  alias MishkaCmsMigration.MigrationRun

  setup do
    %{site: create_site!()}
  end

  defp paths(kind, record), do: MigrationRun.record_paths(kind, record)

  test "a post is found in the Posts list by its slug, and on the site once it is published", %{
    site: site
  } do
    post = %BlogPost{slug: "hello world", language: "en", site_id: site.id, status: :published}

    assert %{admin: "/admin/dashboard/blog/posts?posts_search=hello+world", public: public} =
             paths("post", post)

    assert public == "/blog/hello%20world"

    for status <- [:draft, :scheduled, :archived],
        do: assert(%{public: nil} = paths("post", %{post | status: status}))
  end

  test "a category, a tag and a blogger are found in their lists by their slug, and have a page",
       %{site: site} do
    assert %{
             admin: "/admin/dashboard/blog/collections?collections_search=news",
             public: "/blog/category/news"
           } =
             paths("category", %Collection{
               slug: "news",
               site_id: site.id,
               language: "en",
               status: :active
             })

    assert %{public: nil} =
             paths("category", %Collection{
               slug: "news",
               site_id: site.id,
               language: "en",
               status: :draft
             })

    assert %{admin: "/admin/dashboard/blog/tags?tags_search=elixir", public: "/blog/tag/elixir"} =
             paths("tag", %Tag{slug: "elixir", site_id: site.id, language: "en"})

    assert %{
             admin: "/admin/dashboard/blog/bloggers?bloggers_search=omid",
             public: "/blog/author/omid"
           } =
             paths("user", %Blogger{slug: "omid", site_id: site.id})
  end

  test "a comment opens the comments of its post, and has no page of its own", %{site: site} do
    post_id = Ecto.UUID.generate()

    assert %{admin: admin, public: nil} =
             paths("comment", %Comment{post_id: post_id, site_id: site.id})

    assert admin == "/admin/dashboard/blog/comments?comments_filter_post_id=#{post_id}"
  end

  test "a page is found by its path, and on the site only while it is active", %{site: site} do
    page = %Page{path: "/about", language: "en", site_id: site.id, active: true}

    assert %{admin: "/admin/dashboard/runtime/pages?pages_search=%2Fabout", public: "/about"} =
             paths("page", page)

    assert %{public: nil} = paths("page", %{page | active: false})
  end

  test "a file is found by its name and served from its path, a redirect found by its old address",
       %{site: site} do
    media = %Media{name: "hero.jpg", relative_path: "/uploads/hero.jpg", site_id: site.id}

    assert %{
             admin: "/admin/dashboard/runtime/medias?search=hero.jpg",
             public: "/uploads/hero.jpg"
           } =
             paths("media", media)

    redirect = %Redirect{from_path: "/2025/12/hello/", site_id: site.id}

    assert %{admin: admin, public: nil} = paths("post_redirect", redirect)
    assert admin == "/admin/dashboard/runtime/redirects?redirects_search=%2F2025%2F12%2Fhello%2F"
  end

  test "a kind this extension names no pages for has none" do
    assert paths("gallery", %Page{}) == nil
  end
end
