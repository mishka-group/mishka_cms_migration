# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.BlogTest do
  @moduledoc """
  A WordPress site's authors, categories, tags and posts moved into Mishka Blog, against what the
  seeded WordPress answered: what a dry run reports, what an import writes and where, what a second
  run does with it, and a node whose Blog targets are stopped. A post's content is read for what it
  means, with LazyHTML, not as markup. An author becomes the blogger of the site's user with their
  email, the editor `shahryar@mishka.tools` in the seed's story, and under `"create"` of a new user.

  A second run sees an item WordPress changed when the item's hash is no longer the one the first
  run recorded, so a test has WordPress change its items by changing the recorded hashes.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0, recorded: 1]

  alias MishkaBlog.{Blogger, BlogPost, Collection, Tag}
  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Runtime.{Languages, Redirect, Redirects}
  alias MishkaCmsCore.Settings
  alias MishkaCmsMigration.{Events, MigrationItem}
  alias MishkaCmsMigration.MigrationRun.Options
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Targets.{BlogCollection, BlogTag, PostRedirect}
  alias MishkaCmsMigration.Test.Plugins.ContentConverter

  @connection %{"url" => "http://localhost:8089", "user" => "admin"}
  @admin ["admin:dashboard:migration", "admin:dashboard:blog:post"]
  @people @admin ++ ["admin:dashboard:user"]
  @editor "shahryar@mishka.tools"

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
      |> Ash.read!(
        tenant: site.id,
        authorize?: false,
        load: [:tenant_collections, :tenant_tags, :tenant_bloggers]
      )
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

  defp bloggers(site),
    do: Blogger |> Ash.read!(tenant: site.id, authorize?: false) |> Map.new(&{&1.slug, &1})

  defp accounts(site) do
    User
    |> Ash.read!(tenant: site.id, authorize?: false, load: [:permissions])
    |> Enum.filter(&(&1.site_id == site.id))
    |> Map.new(&{to_string(&1.email), &1})
  end

  defp kept(blogger),
    do: Map.take(blogger, [:id, :user_id, :display_name, :slug, :bio, :avatar_url, :updated_at])

  defp emails(recording), do: recording |> recorded() |> Map.new(&{&1["email"], &1})

  defp tag!(site, admin, attrs),
    do:
      Tag
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(%{language: Languages.primary(site.id)}, attrs),
        actor: admin,
        tenant: site.id
      )
      |> Ash.create!()

  defp collection!(site, admin, attrs),
    do:
      Collection
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(%{language: Languages.primary(site.id), status: :active}, attrs),
        actor: admin,
        tenant: site.id
      )
      |> Ash.create!()

  defp own_terms!(site, admin) do
    attrs = %{name: "Elixir, as the site has it", slug: "elixir"}
    {tag!(site, admin, attrs), collection!(site, admin, attrs)}
  end

  defp slugs(resource, site),
    do:
      resource |> Ash.read!(tenant: site.id, authorize?: false) |> Enum.frequencies_by(& &1.slug)

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

  describe "terms the site already has" do
    test "a dry run reports the tag and the category of the same slug as connected, the others as ones to create, and writes nothing",
         %{site: site, admin: admin} do
      own_terms!(site, admin)
      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      assert %{"10" => {:skipped, "connected"}} = outcomes(run, "tag")
      assert %{"6" => {:skipped, "connected"}} = outcomes(run, "category")
      assert counts(run, "tag").created == length(recorded("tags")) - 1
      assert counts(run, "category").created == length(recorded("categories")) - 1
      assert map_size(blog(Tag, site)) == 1
      assert map_size(blog(Collection, site)) == 1
    end

    test "an import writes no second copy, keeps the site's own as it is, and links the posts to it",
         %{site: site, admin: admin} do
      {tag, collection} = own_terms!(site, admin)
      run = imported!(site, admin)

      assert counts(run, "tag") ==
               %{created: length(recorded("tags")) - 1, updated: 0, skipped: 1, failed: 0}

      assert counts(run, "category") ==
               %{created: length(recorded("categories")) - 1, updated: 0, skipped: 1, failed: 0}

      assert slugs(Tag, site)["elixir"] == 1
      assert slugs(Collection, site)["elixir"] == 1
      assert blog(Tag, site)["Elixir, as the site has it"].id == tag.id
      assert blog(Collection, site)["Elixir, as the site has it"].id == collection.id
      refute is_map_key(blog(Tag, site), "Elixir")
      refute is_map_key(blog(Collection, site), "Elixir")

      post = posts(site)["Phoenix LiveView tips"]
      assert tag.id in Enum.map(post.tenant_tags, & &1.id)
      assert collection.id in Enum.map(post.tenant_collections, & &1.id)
    end

    test "a second run keeps them connected and the site's own untouched", %{
      site: site,
      admin: admin
    } do
      {tag, collection} = own_terms!(site, admin)
      imported!(site, admin)
      change_in_wordpress!("tag")
      change_in_wordpress!("category")
      again = imported!(site, admin)

      assert %{"10" => {:skipped, "connected"}} = outcomes(again, "tag")
      assert %{"6" => {:skipped, "connected"}} = outcomes(again, "category")
      assert slugs(Tag, site)["elixir"] == 1
      assert blog(Tag, site)["Elixir, as the site has it"].updated_at == tag.updated_at

      assert blog(Collection, site)["Elixir, as the site has it"].updated_at ==
               collection.updated_at
    end

    test "a slug WordPress keeps percent-encoded is matched as the Blog stores it", %{
      site: site,
      admin: admin
    } do
      tag = tag!(site, admin, %{name: "WordPress, in Persian", slug: "wrdprs"})
      collection = collection!(site, admin, %{name: "Tutorials, in Persian", slug: "amwzsh"})

      run = imported!(site, admin)

      assert %{"20" => {:skipped, "connected"}} = outcomes(run, "tag")
      assert %{"9" => {:skipped, "connected"}} = outcomes(run, "category")

      post = posts(site)["نصب وردپرس روی سرور"]
      assert Enum.map(post.tenant_tags, & &1.id) == [tag.id]
      assert Enum.map(post.tenant_collections, & &1.id) == [collection.id]
    end

    test "a category that sat under a connected one is written under the site's own", %{
      site: site,
      admin: admin
    } do
      own = collection!(site, admin, %{name: "Guides, as the site has it", slug: "tutorials"})

      imported!(site, admin)
      collections = blog(Collection, site)

      assert collections["WordPress"].parent_collection_id == own.id
      assert parent_name(collections, "Migration") == "WordPress"
      assert slugs(Collection, site)["tutorials"] == 1
    end

    test "only the run's own site is looked at: another site's term of the same slug is not connected",
         %{site: site, admin: admin} do
      other = create_site!()
      own_terms!(other, migration_admin!(other, @admin))

      run = imported!(site, admin)

      assert counts(run, "tag").created == length(recorded("tags"))
      assert counts(run, "category").created == length(recorded("categories"))
      assert blog(Tag, site)["Elixir"].slug == "elixir"
      assert map_size(blog(Tag, other)) == 1
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

  describe "authors" do
    setup %{site: site}, do: %{admin: migration_admin!(site, @people)}

    test "a dry run plans a blogger for the author whose email is a user of the site, skips the others as having no user, and writes nothing",
         %{site: site, admin: admin} do
      create_user!(email: @editor, site_id: site.id)
      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      assert outcomes(run, "user") == %{
               "2" => {:created, nil},
               "1" => {:skipped, "no_user"},
               "3" => {:skipped, "no_user"},
               "4" => {:skipped, "no_user"},
               "5" => {:skipped, "no_user"}
             }

      assert bloggers(site) == %{}
    end

    test "an import makes the site's user with the editor's email a blogger with the WordPress profile, and makes no user",
         %{site: site, admin: admin} do
      editor = create_user!(email: @editor, site_id: site.id)
      before = accounts(site)

      run = imported!(site, admin)

      assert counts(run, "user") == %{created: 1, updated: 0, skipped: 4, failed: 0}
      assert %{"shahryar" => blogger} = bloggers(site)
      assert map_size(bloggers(site)) == 1
      assert blogger.user_id == editor.id
      assert blogger.display_name == "Shahryar Tavakkoli"
      assert blogger.bio == emails("users")[@editor]["description"]
      assert blogger.avatar_url == emails("users")[@editor]["avatar_urls"]["96"]
      assert is_nil(blogger.contact_email)
      refute blogger.can_publish_directly
      assert Map.keys(accounts(site)) == Map.keys(before)
    end

    test "an author whose user already has a blogger is linked to it, and the profile is kept, on every run",
         %{site: site, admin: admin} do
      editor = create_user!(email: @editor, site_id: site.id)

      own =
        Blogger
        |> Ash.Changeset.for_create(
          :create,
          %{user_id: editor.id, display_name: "Shahryar, in the CMS", slug: "mine", bio: "Mine"},
          actor: admin,
          tenant: site.id
        )
        |> Ash.create!()

      run = imported!(site, admin)

      assert %{"2" => {:skipped, "connected"}} = outcomes(run, "user")
      assert site |> bloggers() |> Map.values() |> Enum.map(&kept/1) == [kept(own)]

      change_in_wordpress!("user")
      again = imported!(site, admin)

      assert %{"2" => {:skipped, "connected"}} = outcomes(again, "user")
      assert site |> bloggers() |> Map.values() |> Enum.map(&kept/1) == [kept(own)]
    end

    test "under create, an author with no user gets a new user of the site, unconfirmed, with no permission and no password anyone knows, and a blogger",
         %{site: site, admin: admin} do
      editor = create_user!(email: @editor, site_id: site.id)
      run = imported!(site, admin, %{authors: "create"})
      wordpress = emails("users")
      accounts = accounts(site)

      assert counts(run, "user") ==
               %{created: map_size(wordpress), updated: 0, skipped: 0, failed: 0}

      assert accounts[@editor].id == editor.id

      for {email, %{"username" => username, "slug" => slug}} <- wordpress, email != @editor do
        user = accounts[email]

        assert user.site_id == site.id
        assert is_nil(user.confirmed_at)
        assert user.permissions == []

        for guess <- ["", email, username, slug, "app password", "Password123!"],
            do: refute(Bcrypt.verify_pass(guess, user.hashed_password))
      end

      hashes =
        for {email, _row} <- wordpress, email != @editor, do: accounts[email].hashed_password

      assert hashes |> Enum.uniq() |> length() == map_size(wordpress) - 1

      bloggers = bloggers(site)
      assert map_size(bloggers) == map_size(wordpress)

      for {email, %{"slug" => slug, "name" => name}} <- wordpress do
        assert bloggers[slug].user_id == accounts[email].id
        assert bloggers[slug].display_name == name
      end

      assert bloggers["omid"].display_name == "امید رحیمی"
    end

    test "a second run keeps every author's user and blogger, each unchanged", %{
      site: site,
      admin: admin
    } do
      imported!(site, admin, %{authors: "create"})
      accounts = accounts(site)
      bloggers = bloggers(site)

      again = imported!(site, admin, %{authors: "create"})

      assert again |> outcomes("user") |> Map.values() |> Enum.uniq() == [{:skipped, "unchanged"}]
      assert accounts(site) == accounts
      assert bloggers(site) == bloggers

      change_in_wordpress!("user")
      third = imported!(site, admin, %{authors: "create"})

      assert counts(third, "user").updated == map_size(bloggers)
      assert accounts(site) == accounts

      assert for({slug, blogger} <- bloggers(site), do: {slug, blogger.id, blogger.user_id}) ==
               for({slug, blogger} <- bloggers, do: {slug, blogger.id, blogger.user_id})
    end

    test "an author skipped for having no user becomes a blogger once the site has the user", %{
      site: site,
      admin: admin
    } do
      run = imported!(site, admin)
      assert %{"2" => {:skipped, "no_user"}} = outcomes(run, "user")

      editor = create_user!(email: @editor, site_id: site.id)
      again = imported!(site, admin)

      assert %{"2" => {:created, nil}} = outcomes(again, "user")
      assert bloggers(site)["shahryar"].user_id == editor.id
    end

    test "a site admin's run matches only its own site's users: never another site's or a master with that email",
         %{site: site, admin: admin} do
      other = create_site!()
      elsewhere = create_user!(email: @editor, site_id: other.id)
      master = create_user!(email: "nadia.karimi@example.test")

      run = imported!(site, admin)

      assert %{"2" => {:skipped, "no_user"}, "3" => {:skipped, "no_user"}} = outcomes(run, "user")
      assert bloggers(site) == %{}

      created = imported!(site, admin, %{authors: "create"})

      assert %{"2" => {:created, nil}, "3" => {:created, nil}} = outcomes(created, "user")
      own = accounts(site)
      bloggers = bloggers(site)

      for {email, slug} <- [{@editor, "shahryar"}, {"nadia.karimi@example.test", "nadia"}] do
        assert own[email].site_id == site.id
        assert bloggers[slug].user_id == own[email].id
        refute own[email].id in [elsewhere.id, master.id]
      end

      assert %{site_id: site_id, hashed_password: hash} =
               Ash.get!(User, elsewhere.id, authorize?: false)

      assert {site_id, hash} == {other.id, elsewhere.hashed_password}
      assert is_nil(Ash.get!(User, master.id, authorize?: false).site_id)
      assert bloggers(other) == %{}
    end

    test "an admin who may not see the site's users connects none and makes none", %{site: site} do
      admin = migration_admin!(site, @admin)
      create_user!(email: @editor, site_id: site.id)
      before = accounts(site)

      run = imported!(site, admin)
      assert %{"2" => {:skipped, "no_user"}} = outcomes(run, "user")

      created = imported!(site, admin, %{authors: "create"})

      assert created |> outcomes("user") |> Map.values() |> Enum.uniq() == [
               {:failed, "forbidden"}
             ]

      assert Map.keys(accounts(site)) == Map.keys(before)
      assert bloggers(site) == %{}
    end
  end

  describe "a post's author" do
    setup %{site: site}, do: %{admin: migration_admin!(site, @people)}

    test "an import makes each post's author its blogger, and says which posts have none", %{
      site: site,
      admin: admin
    } do
      create_user!(email: @editor, site_id: site.id)
      run = imported!(site, admin)
      editor = bloggers(site)["shahryar"]
      posts = posts(site)
      outcomes = outcomes(run, "post")

      for %{"id" => id, "author" => author, "title" => %{"raw" => title}} <- recorded("posts") do
        {:created, reason} = outcomes[to_string(id)]
        authors = Enum.map(posts[title].tenant_bloggers, & &1.id)

        if author == 2 do
          assert authors == [editor.id]
          refute to_string(reason) =~ "author_missing"
        else
          assert authors == []
          assert reason =~ "author_missing"
        end
      end
    end

    test "a post whose author was linked to the user's own blogger names that blogger", %{
      site: site,
      admin: admin
    } do
      editor = create_user!(email: @editor, site_id: site.id)

      own =
        Blogger
        |> Ash.Changeset.for_create(
          :create,
          %{user_id: editor.id, display_name: "Shahryar, in the CMS", slug: "mine"},
          actor: admin,
          tenant: site.id
        )
        |> Ash.create!()

      imported!(site, admin)

      assert Enum.map(posts(site)["Release 1.0 announcement"].tenant_bloggers, & &1.id) == [
               own.id
             ]
    end

    test "under create, every post names its author's blogger", %{site: site, admin: admin} do
      run = imported!(site, admin, %{authors: "create"})
      bloggers = Map.new(bloggers(site), fn {_slug, blogger} -> {blogger.id, blogger.slug} end)
      slugs = Map.new(recorded("users"), &{&1["id"], &1["slug"]})
      posts = posts(site)

      for %{"author" => author, "title" => %{"raw" => title}} <- recorded("posts"),
          do: assert(Enum.map(posts[title].tenant_bloggers, &bloggers[&1.id]) == [slugs[author]])

      refute Enum.any?(run.report.entries, &(&1.reason && &1.reason =~ "author_missing"))
    end

    test "a dry run says nothing of authors, since it writes no blogger", %{
      site: site,
      admin: admin
    } do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      refute Enum.any?(run.report.entries, &(&1.reason && &1.reason =~ "author_missing"))
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
               "40" => {:created, "draft_from_pending; author_missing"},
               "41" => {:created, "draft_from_private; author_missing"},
               "42" => {:created, "draft_from_password; author_missing"}
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

    test "an import keeps a post's table whole, with its header, rows and cells", %{
      site: site,
      admin: admin
    } do
      imported!(site, admin)
      html = content(posts(site)["Every core block in one post"])

      assert texts(html, "table > thead > tr > th") == ["Block", "Becomes"]

      assert texts(html, "table > tbody > tr > td") ==
               ["core/paragraph", "text", "core/table", "table"]
    end

    test "an import keeps a usable address on every image of every post", %{
      site: site,
      admin: admin
    } do
      imported!(site, admin)
      pages = site |> posts() |> Map.values() |> Enum.map(&content/1)
      images = pages |> Enum.map(&(&1 |> LazyHTML.query("img") |> Enum.count())) |> Enum.sum()

      located =
        pages
        |> Enum.flat_map(&(&1 |> LazyHTML.query("img[src]") |> LazyHTML.attribute("src")))

      assert images >= 10
      assert length(located) == images
      assert Enum.all?(located, &String.starts_with?(&1, "http://localhost:8089/wp-content/"))
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

      assert %{"53" => {:created, "author_missing; unconverted: acme/callout, core/latest-posts"}} =
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

      assert %{"53" => {:created, "author_missing; unconverted: core/latest-posts"}} =
               outcomes(run, "post")
    end

    test "an import points a post's links to the run's posts at their Blog addresses, and keeps every other link",
         %{site: site, admin: admin} do
      imported!(site, admin)
      posts = posts(site)
      html = content(posts["Linking between posts and media"])
      hrefs = html |> LazyHTML.query("a") |> LazyHTML.attribute("href")

      assert {posts["Welcome to the Mishka Test Blog"].slug,
              posts["Every core block in one post"].slug} ==
               {"welcome-to-the-mishka-test-blog", "gutenberg-all-core-blocks"}

      assert Enum.frequencies(hrefs)["/blog/welcome-to-the-mishka-test-blog"] == 2
      assert Enum.frequencies(hrefs)["/blog/gutenberg-all-core-blocks"] == 2
      assert "/blog/classic-editor-with-shortcodes#a-heading-after-the-more-tag" in hrefs

      assert for(
               link <- LazyHTML.query(html, "a"),
               Enum.any?(LazyHTML.query(link, "img")),
               do: LazyHTML.attribute(link, "href")
             ) == [["/blog/welcome-to-the-mishka-test-blog"]]

      for kept <- [
            "http://localhost:8089/?page_id=25",
            "/about/team/",
            "http://localhost:8089/2026/01/this-post-was-deleted/",
            "http://localhost:8089/2026/01/welcome-to-the-mishka-test-blog/hero/",
            "http://localhost:8089/category/news/",
            "http://localhost:8089/?cat=2",
            "http://localhost:8089/tag/elixir/",
            "http://localhost:8089/author/nadia/",
            "http://localhost:8089/wp-content/uploads/2026/11/guide.pdf",
            "https://elixir-lang.org/",
            "mailto:hello@example.test"
          ],
          do: assert(kept in hrefs)
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

  describe "post addresses" do
    @movers @admin ++ ["admin:dashboard:runtime:redirect"]
    @release "/2025/12/release-1-0-announcement"

    setup %{site: site}, do: %{admin: migration_admin!(site, @movers)}

    defp redirects(site),
      do:
        Redirect |> Ash.read!(tenant: site.id, authorize?: false) |> Map.new(&{&1.from_path, &1})

    defp published, do: Enum.filter(recorded("posts"), &(&1["status"] == "publish"))

    defp old_path(row) do
      {:ok, path} = Redirects.normalize_path(row["link"])
      path
    end

    defp redirect!(site, admin, attrs),
      do:
        Redirect
        |> Ash.Changeset.for_create(:create, attrs, actor: admin, tenant: site.id)
        |> Ash.create!()

    test "a dry run plans a redirect from each published post's old address, and writes none", %{
      site: site,
      admin: admin
    } do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      unpublished = length(recorded("posts")) - length(published())

      assert counts(run, "post_redirect") ==
               %{created: length(published()), updated: 0, skipped: unpublished, failed: 0}

      assert for({_id, {:skipped, reason}} <- outcomes(run, "post_redirect"), do: reason) ==
               List.duplicate("no_old_address", unpublished)

      assert redirects(site) == %{}
    end

    test "an import sends each published post's old address to its Blog address with a 301, on the run's site only",
         %{site: site, admin: admin} do
      other = create_site!()
      run = imported!(site, admin)
      redirects = redirects(site)
      posts = posts(site)

      assert counts(run, "post_redirect").created == length(published())
      assert map_size(redirects) == length(published())

      assert %{to: "/blog/release-1-0-announcement", status: 301, active: true} =
               redirects[@release]

      for row <- published(),
          do: assert(redirects[old_path(row)].to == "/blog/" <> posts[row["title"]["raw"]].slug)

      refute is_map_key(redirects, "/2026/03/private-team-notes")
      assert redirects(other) == %{}
    end

    test "a second run writes no second redirect, and keeps one an admin edited", %{
      site: site,
      admin: admin
    } do
      imported!(site, admin)
      again = imported!(site, admin)

      assert %{created: 0, updated: 0, failed: 0} = counts(again, "post_redirect")

      assert again |> outcomes("post_redirect") |> Map.values() |> Enum.uniq() |> Enum.sort() ==
               [{:skipped, "no_old_address"}, {:skipped, "unchanged"}]

      redirects(site)[@release]
      |> Ash.Changeset.for_update(:update, %{to: "/news/release-1-0"},
        actor: admin,
        tenant: site.id
      )
      |> Ash.update!()

      change_in_wordpress!("post_redirect")
      third = imported!(site, admin)

      assert %{"44" => {:skipped, "edited_in_cms"}} = outcomes(third, "post_redirect")
      assert counts(third, "post_redirect").updated == length(published()) - 1
      assert map_size(redirects(site)) == length(published())
      assert redirects(site)[@release].to == "/news/release-1-0"
    end

    test "an old address the site already redirects is reported, and the site's own rule is kept",
         %{site: site, admin: admin} do
      redirect!(site, admin, %{from_path: @release <> "/", to: "/news/release-1-0"})
      run = imported!(site, admin)

      assert {:failed, reason} = outcomes(run, "post_redirect")["44"]
      assert reason =~ "already redirects that address"
      assert counts(run, "post_redirect").created == length(published()) - 1
      assert redirects(site)[@release].to == "/news/release-1-0"
    end

    test "with no redirects chosen, an import writes the posts and no redirect, and says why", %{
      site: site,
      admin: admin
    } do
      run = imported!(site, admin, %{post_address: "blog_without_redirects"})

      assert counts(run, "post").created == length(recorded("posts"))

      assert run |> outcomes("post_redirect") |> Map.values() |> Enum.uniq() ==
               [{:skipped, "not_chosen"}]

      assert redirects(site) == %{}
    end

    test "an old address whose post was not imported is left out", %{site: site, admin: admin} do
      target = MishkaCmsMigration.Targets.BlogPost
      {:ok, _stopped} = MishkaInstaller.Event.Event.stop(:name, target, false)
      on_exit(fn -> {:ok, _enabled} = MishkaInstaller.Event.Event.enable(target, false) end)

      run = imported!(site, admin)

      assert run |> outcomes("post_redirect") |> Map.values() |> Enum.uniq() |> Enum.sort() ==
               [{:skipped, "no_old_address"}, {:skipped, "post_missing"}]

      assert redirects(site) == %{}
    end

    test "an old address that is already its post's Blog address is left out", %{
      site: site,
      admin: admin
    } do
      run = imported!(site, admin, %{post_address: "blog_without_redirects"})
      {:ok, options} = Options.builder(%{})

      context = %{
        mode: :import,
        actor: admin,
        site_id: site.id,
        run_id: run.id,
        source_host: run.source_host,
        options: options,
        parent_id: nil,
        record: nil
      }

      items =
        for {id, from} <- [{"44", "/blog/release-1-0-announcement/"}, {"43", @release}],
            do: %Item{kind: "post_redirect", source_id: id, attrs: %{"from" => from}}

      assert PostRedirect.existing(items, context) == %{"44" => {:skipped, "same_address"}}
    end
  end
end
