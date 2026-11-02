# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.BlogTest do
  @moduledoc """
  A WordPress site's categories, tags and posts moved into Mishka Blog, against what the seeded
  WordPress answered: what a dry run reports, what an import writes and where, what a second run
  does with it, and a node whose Blog targets are stopped. A post's content is read for what it
  means, with LazyHTML, not as markup.

  A second run sees an item WordPress changed when the item's hash is no longer the one the first
  run recorded, so a test has WordPress change its items by changing the recorded hashes.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0, recorded: 1]

  alias MishkaBlog.{BlogPost, Collection, Tag}
  alias MishkaCmsCore.Settings
  alias MishkaCmsMigration.{Events, MigrationItem}
  alias MishkaCmsMigration.Targets.{BlogCollection, BlogTag}
  alias MishkaCmsMigration.Test.Plugins.ContentConverter

  @connection %{"url" => "http://localhost:8089", "user" => "admin"}
  @admin ["admin:dashboard:migration", "admin:dashboard:blog:post"]

  setup do
    stub!()
    site = create_site!()
    %{site: site, admin: migration_admin!(site, @admin)}
  end

  defp wordpress_run!(site, admin) do
    %{source: "wordpress", connection: @connection, secret: "app password"}
    |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)
  end

  defp imported!(site, admin),
    do: site |> wordpress_run!(admin) |> dry_run!(admin) |> import!(admin)

  defp counts(run, kind) do
    run.report.kinds
    |> Enum.find(&(&1.kind == kind))
    |> Map.take([:created, :updated, :skipped, :failed])
  end

  defp outcomes(run, kind) do
    for %{kind: ^kind} = entry <- run.report.entries,
        into: %{},
        do: {entry.source_id, {entry.outcome, entry.reason}}
  end

  defp blog(resource, site),
    do: resource |> Ash.read!(tenant: site.id, authorize?: false) |> Map.new(&{&1.name, &1})

  defp parent_name(collections, name) do
    parent_id = collections[name].parent_collection_id
    Enum.find_value(collections, fn {parent, %{id: id}} -> id == parent_id && parent end)
  end

  defp names(recording), do: recording |> recorded() |> Enum.map(& &1["name"]) |> Enum.sort()

  defp posts(site),
    do:
      BlogPost
      |> Ash.read!(tenant: site.id, authorize?: false, load: [:tenant_collections, :tenant_tags])
      |> Map.new(&{&1.title, &1})

  defp content(post), do: LazyHTML.from_fragment(post.content)

  defp texts(html, selector),
    do: html |> LazyHTML.query(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

  defp sources(html, selector),
    do:
      html |> LazyHTML.query(selector) |> LazyHTML.attribute("src") |> Enum.map(&Path.basename/1)

  defp named(recording, ids) do
    names = Map.new(recorded(recording), &{&1["id"], &1["name"]})
    ids |> Enum.map(&names[&1]) |> Enum.sort()
  end

  defp change_in_wordpress!(kind) do
    Repo.query!(
      "UPDATE mishka_cms_migration_items SET content_hash = 'changed' WHERE source_kind = $1",
      [kind]
    )
  end

  describe "a dry run" do
    test "reports every category and tag as one to create, and writes nothing", %{
      site: site,
      admin: admin
    } do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      assert counts(run, "category") ==
               %{created: length(recorded("categories")), updated: 0, skipped: 0, failed: 0}

      assert counts(run, "tag") ==
               %{created: length(recorded("tags")), updated: 0, skipped: 0, failed: 0}

      assert blog(Collection, site) == %{}
      assert blog(Tag, site) == %{}
      assert Ash.read!(MigrationItem, tenant: site.id, authorize?: false) == []
    end

    test "skips them as no_target where the Blog targets are stopped", %{site: site, admin: admin} do
      for target <- [BlogCollection, BlogTag] do
        {:ok, _stopped} = MishkaInstaller.Event.Event.stop(:name, target, false)
        on_exit(fn -> {:ok, _enabled} = MishkaInstaller.Event.Event.enable(target, false) end)
      end

      run = imported!(site, admin)

      for {kind, recording} <- [{"category", "categories"}, {"tag", "tags"}] do
        assert counts(run, kind) ==
                 %{created: 0, updated: 0, skipped: length(recorded(recording)), failed: 0}

        assert run |> outcomes(kind) |> Map.values() |> Enum.uniq() == [{:skipped, "no_target"}]
      end

      assert blog(Collection, site) == %{}
      assert blog(Tag, site) == %{}
    end
  end

  describe "an import" do
    test "writes every category and tag into the Blog of the run's site only", %{
      site: site,
      admin: admin
    } do
      other = create_site!()
      run = imported!(site, admin)

      assert counts(run, "category").created == length(recorded("categories"))
      assert counts(run, "tag").created == length(recorded("tags"))

      collections = blog(Collection, site)
      tags = blog(Tag, site)

      assert collections |> Map.keys() |> Enum.sort() == names("categories")
      assert tags |> Map.keys() |> Enum.sort() == names("tags")

      assert {collections["Migration"].slug, tags["Release notes"].slug} ==
               {"migration", "release-notes"}

      assert collections["Announcements"].description == "General announcements."
      assert is_nil(collections["Uncategorized"].description)
      assert Enum.all?(Map.values(collections), &(&1.status == :active))

      assert blog(Collection, other) == %{}
      assert blog(Tag, other) == %{}
    end

    test "puts each category under its parent, however deep, whichever WordPress lists first", %{
      site: site,
      admin: admin
    } do
      imported!(site, admin)
      collections = blog(Collection, site)
      named = Map.new(recorded("categories"), &{&1["id"], &1["name"]})

      for %{"name" => name, "parent" => parent} <- recorded("categories"),
          do: assert(parent_name(collections, name) == named[parent])

      assert parent_name(collections, "Migration") == "WordPress"
      assert parent_name(collections, "WordPress") == "Tutorials"
      assert is_nil(parent_name(collections, "Tutorials"))
    end

    test "decodes a slug WordPress keeps percent-encoded before the Blog writes it", %{
      site: site,
      admin: admin
    } do
      imported!(site, admin)

      assert blog(Tag, site)["وردپرس"].slug == "wrdprs"
      assert blog(Collection, site)["آموزش‌ها"].slug == "amwzsh"
    end

    test "writes them, and the posts, in the language the site leads with", %{
      site: site,
      admin: admin
    } do
      forget_settings(~w(site.languages), [site.id])
      {:ok, _} = Settings.put("site.languages", ["fa", "en"], site_id: site.id)

      imported!(site, admin)

      for resource <- [Collection, Tag],
          do: assert(resource |> blog(site) |> Map.values() |> Enum.all?(&(&1.language == "fa")))

      assert site |> posts() |> Map.values() |> Enum.map(& &1.language) |> Enum.uniq() == ["fa"]
    end
  end

  describe "a second run" do
    test "skips every category and tag WordPress did not change as unchanged", %{
      site: site,
      admin: admin
    } do
      imported!(site, admin)
      written = for resource <- [Collection, Tag], do: blog(resource, site)

      again = imported!(site, admin)

      for kind <- ["category", "tag"] do
        assert %{created: 0, updated: 0, failed: 0} = counts(again, kind)
        assert again |> outcomes(kind) |> Map.values() |> Enum.uniq() == [{:skipped, "unchanged"}]
      end

      assert for(resource <- [Collection, Tag], do: blog(resource, site)) == written
    end

    test "writes over what WordPress changed, and keeps a tag an admin edited in the Blog", %{
      site: site,
      admin: admin
    } do
      imported!(site, admin)
      seo = blog(Tag, site)["SEO"]

      seo
      |> Ash.Changeset.for_update(:update, %{name: "Search engines"},
        actor: admin,
        tenant: site.id
      )
      |> Ash.update!()

      change_in_wordpress!("tag")
      again = imported!(site, admin)

      assert counts(again, "tag") ==
               %{created: 0, updated: length(recorded("tags")) - 1, skipped: 1, failed: 0}

      assert %{"15" => {:skipped, "edited_in_cms"}} = outcomes(again, "tag")

      tags = blog(Tag, site)
      assert tags["Search engines"].id == seo.id
      refute is_map_key(tags, "SEO")
    end
  end

  describe "posts" do
    test "a dry run reports every post as one to create, says which become drafts and what is left as text, and writes nothing",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      outcomes = outcomes(run, "post")

      assert counts(run, "post") ==
               %{created: length(recorded("posts")), updated: 0, skipped: 0, failed: 0}

      assert %{
               "32" => {:created, nil},
               "40" => {:created, "draft_from_pending"},
               "41" => {:created, "draft_from_private"},
               "42" => {:created, "draft_from_password"},
               "53" => {:created, "unconverted: acme/callout, core/latest-posts"},
               "34" => {:created, "unconverted: unknown_plugin_shortcode, pullbox"}
             } = outcomes

      assert posts(site) == %{}
    end

    test "an import writes each post into the Blog of the run's site only, with its status and dates",
         %{site: site, admin: admin} do
      other = create_site!()
      run = imported!(site, admin)
      posts = posts(site)

      assert counts(run, "post").created == length(recorded("posts"))
      assert map_size(posts) == length(recorded("posts"))

      assert %{
               status: :published,
               published_at: ~U[2025-12-15 08:30:00Z],
               scheduled_publish_at: nil
             } =
               posts["Release 1.0 announcement"]

      assert %{
               status: :scheduled,
               published_at: nil,
               scheduled_publish_at: ~U[2099-05-20 06:30:00Z]
             } =
               posts["Scheduled release notes"]

      for title <- [
            "Draft roadmap",
            "Pending review: a guest guide",
            "Private team notes",
            "Password protected preview"
          ],
          do: assert(%{status: :draft, published_at: nil} = posts[title])

      assert %{
               "40" => {:created, "draft_from_pending"},
               "41" => {:created, "draft_from_private"},
               "42" => {:created, "draft_from_password"}
             } =
               outcomes(run, "post")

      assert for({title, %{featured: true}} <- posts, do: title) == [
               "Welcome to the Mishka Test Blog"
             ]

      assert posts["Every core block in one post"].slug == "gutenberg-all-core-blocks"
      assert posts["Release 1.0 announcement"].excerpt == "Version 1.0 is out."
      assert is_nil(posts["A minimal post"].excerpt)
      refute posts["نصب وردپرس روی سرور"].slug =~ "%"

      assert posts(other) == %{}
    end

    test "an import links each post to the Blog categories and tags its WordPress post names", %{
      site: site,
      admin: admin
    } do
      imported!(site, admin)
      posts = posts(site)

      for %{"title" => %{"raw" => title}, "categories" => categories, "tags" => tags} <-
            recorded("posts") do
        assert posts[title].tenant_collections |> Enum.map(& &1.name) |> Enum.sort() ==
                 named("categories", categories)

        assert posts[title].tenant_tags |> Enum.map(& &1.name) |> Enum.sort() ==
                 named("tags", tags)
      end

      assert posts["Every core block in one post"].tenant_tags != []
    end

    test "an import leaves out a category or tag that was never written, and still writes the post",
         %{
           site: site,
           admin: admin
         } do
      {:ok, _stopped} = MishkaInstaller.Event.Event.stop(:name, BlogTag, false)
      on_exit(fn -> {:ok, _enabled} = MishkaInstaller.Event.Event.enable(BlogTag, false) end)

      run = imported!(site, admin)
      post = posts(site)["Phoenix LiveView tips"]

      assert counts(run, "post").created == length(recorded("posts"))
      assert post.tenant_tags == []
      assert Enum.map(post.tenant_collections, & &1.name) != []
    end

    test "an import keeps a post's blocks as their HTML", %{site: site, admin: admin} do
      imported!(site, admin)
      post = posts(site)["Every core block in one post"]
      html = content(post)

      assert texts(html, "p strong") == ["bold"]
      assert texts(html, "h2") == ["A level two heading"]
      assert texts(html, "ol > li") == ["Step one", "Step two"]
      assert texts(html, "ul > li > ul > li") == ["Nested one", "Nested two"]
      assert [code] = texts(html, "pre > code")
      assert code =~ ~s(def world, do: "Hello <World> & friends")
      assert "photo.webp" in sources(html, "img")
      assert LazyHTML.text(html) =~ "An image linked to its file, with a caption"
      assert texts(html, ".grid h3") == ["Get the migration newsletter"]
      refute post.content =~ "wp:"
    end

    test "an import makes a classic post's paragraphs, and HTML of its [caption] and [gallery]",
         %{
           site: site,
           admin: admin
         } do
      imported!(site, admin)
      post = posts(site)["A classic editor post with shortcodes"]
      html = content(post)

      assert [first | _] = texts(html, "p")
      assert first =~ "written in the classic editor"

      assert sources(html, "img") |> Enum.take(4) ==
               ["hero-300x169.jpg", "gallery-1.jpg", "gallery-2.jpg", "gallery-3.jpg"]

      assert LazyHTML.text(html) =~ "The hero image, with a caption"
      assert sources(html, "video") == ["sample.mp4"]
      refute post.content =~ "[caption"
      refute post.content =~ "[gallery"
    end

    test "an import keeps a plugin's block nobody converts as escaped text, and says so", %{
      site: site,
      admin: admin
    } do
      run = imported!(site, admin)
      html = content(posts(site)["Unknown and dynamic blocks"])

      assert %{"53" => {:created, "unconverted: acme/callout, core/latest-posts"}} =
               outcomes(run, "post")

      assert LazyHTML.text(html) =~
               ~s(<!-- wp:acme/callout {"tone":"info","title":"Heads up"} -->)

      assert html |> LazyHTML.query("div strong") |> Enum.to_list() == []
      assert texts(html, "p") |> Enum.member?("Page two starts here.")
    end

    test "an import offers a plugin's block to migration:content:convert, and writes what a plugin makes of it",
         %{site: site, admin: admin} do
      register_plugin!(ContentConverter, Events.convert_event())
      Process.register(self(), :__migration_probe__)

      run = imported!(site, admin)

      assert_receive {:convert,
                      %{name: "acme/callout", attrs: %{"title" => "Heads up"}, raw: raw}, _meta}

      assert raw =~ "acme-callout"

      assert texts(content(posts(site)["Unknown and dynamic blocks"]), "aside strong") == [
               "Heads up"
             ]

      assert %{"53" => {:created, "unconverted: core/latest-posts"}} = outcomes(run, "post")
    end

    test "a second run skips every post WordPress did not change, and keeps one an admin edited",
         %{
           site: site,
           admin: admin
         } do
      imported!(site, admin)
      again = imported!(site, admin)

      assert %{created: 0, updated: 0, failed: 0} = counts(again, "post")
      assert again |> outcomes("post") |> Map.values() |> Enum.uniq() == [{:skipped, "unchanged"}]

      draft = posts(site)["Draft roadmap"]

      draft
      |> Ash.Changeset.for_update(:update, %{title: "Roadmap, edited"},
        actor: admin,
        tenant: site.id
      )
      |> Ash.update!()

      change_in_wordpress!("post")
      third = imported!(site, admin)

      assert counts(third, "post") ==
               %{created: 0, updated: length(recorded("posts")) - 1, skipped: 1, failed: 0}

      assert %{"39" => {:skipped, "edited_in_cms"}} = outcomes(third, "post")
      posts = posts(site)
      assert posts["Roadmap, edited"].id == draft.id
      refute is_map_key(posts, "Draft roadmap")
    end
  end
end
