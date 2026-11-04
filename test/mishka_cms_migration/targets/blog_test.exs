# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.BlogTest do
  @moduledoc """
  A WordPress site's authors, categories, tags, posts and comments moved into Mishka Blog, against
  what the seeded WordPress answered: what a dry run reports, what an import writes and where, what a second
  run does with it, and a node whose Blog targets are stopped. A post's content is read for what it
  means, with LazyHTML, not as markup. An author becomes the blogger of the site's user with their
  email, the editor `shahryar@mishka.tools` in the seed's story, and under `"create"` of a new user.

  A second run sees an item WordPress changed when the item's hash is no longer the one the first
  run recorded, so a test has WordPress change its items by changing the recorded hashes. The admin
  may change the site's settings, so a post's YouTube or Vimeo player is allowed on the site,
  except where a test takes that away.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0, stub!: 1, recorded: 1]

  alias MishkaBlog.{Blogger, BlogPost, Collection, Comment, Tag}
  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.PlainText
  alias MishkaCmsCore.Runtime.{Languages, Redirect, Redirects, Seo, Setting}
  alias MishkaCmsCore.Settings
  alias MishkaCmsMigration.{Events, MigrationItem}
  alias MishkaCmsMigration.MigrationRun.Options
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Targets.{BlogTag, PostRedirect}
  alias MishkaCmsMigration.Test.Plugins.ContentConverter

  @connection %{"url" => "http://localhost:8089", "user" => "admin"}
  @admin ["admin:dashboard:migration", "admin:dashboard:blog:post", "admin:dashboard:setting"]
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
    |> Map.take(MishkaCmsMigration.Report.outcomes())
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

  defp decide!(site, admin, items, choice) do
    for item <- Ash.read!(MigrationItem, tenant: site.id, authorize?: false),
        {item.source_kind, item.source_id} in items,
        do: MishkaCmsMigration.decide_item!(item, choice, actor: admin, tenant: site.id)
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
    test "reports every category and tag as one to create, and writes nothing in the CMS", %{
      site: site,
      admin: admin
    } do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      assert counts(run, "category") ==
               %{
                 created: length(recorded("categories")),
                 updated: 0,
                 skipped: 0,
                 failed: 0,
                 undecided: 0
               }

      assert counts(run, "tag") ==
               %{
                 created: length(recorded("tags")),
                 updated: 0,
                 skipped: 0,
                 failed: 0,
                 undecided: 0
               }

      assert blog(Collection, site) == %{}
      assert blog(Tag, site) == %{}
      assert imported_items(site) == []
    end
  end

  describe "a node without the Blog" do
    setup do: without_blog!()

    test "leaves every item the Blog would write waiting for it, in the dry run and the import, and writes none",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      for kind <- ["user", "category", "tag", "post", "post_redirect"],
          do:
            assert(
              run |> outcomes(kind) |> Map.values() |> Enum.uniq() == [
                {:undecided, "blog_missing"}
              ]
            )

      run = import!(run, admin)

      assert counts(run, "category").undecided == length(recorded("categories"))

      assert run |> outcomes("post") |> Map.values() |> Enum.uniq() == [
               {:undecided, "blog_missing"}
             ]

      assert blog(Collection, site) == %{}
      assert blog(Tag, site) == %{}
      assert posts(site) == %{}
    end

    test "skips by the run's choices what they leave out anyway: comments while they are off, redirects for posts without them",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      assert run |> outcomes("comment") |> Map.values() |> Enum.uniq() ==
               [{:skipped, "not_chosen"}]

      assert run |> outcomes("post_redirect") |> Map.values() |> Enum.uniq() ==
               [{:undecided, "blog_missing"}]

      run =
        site
        |> wordpress_run!(admin, %{post_address: "blog_without_redirects", comments: true})
        |> dry_run!(admin)
        |> import!(admin)

      assert run |> outcomes("post_redirect") |> Map.values() |> Enum.uniq() ==
               [{:skipped, "not_chosen"}]

      assert run |> outcomes("comment") |> Map.values() |> Enum.uniq() ==
               [{:undecided, "blog_missing"}]
    end

    test "Wait for the Blog keeps an item until the Blog is there, and Leave out leaves it out",
         %{
           site: site,
           admin: admin
         } do
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, [{"category", "6"}], "keep")
      decide!(site, admin, [{"tag", "10"}], "leave_out")

      run = imported!(site, admin)

      assert %{"6" => {:skipped, "waits_for_blog"}} = outcomes(run, "category")
      assert %{"10" => {:skipped, "left_out_by_admin"}} = outcomes(run, "tag")

      assert run |> outcomes("tag") |> Map.delete("10") |> Map.values() |> Enum.uniq() ==
               [{:undecided, "blog_missing"}]

      assert blog(Collection, site) == %{}
      assert MigrationItem.conflict(category_item(site)) == "blog_missing"

      with_blog!()
      run = imported!(site, admin)

      assert %{"6" => {:created, nil}} = outcomes(run, "category")
      assert %{"10" => {:skipped, "left_out_by_admin"}} = outcomes(run, "tag")
      assert is_map_key(blog(Collection, site), "Elixir")
      refute is_map_key(blog(Tag, site), "Elixir")
      assert MigrationItem.conflict(category_item(site)) == nil
    end

    defp category_item(site),
      do:
        MigrationItem
        |> Ash.read!(tenant: site.id, authorize?: false)
        |> Enum.find(&(&1.source_kind == "category" and &1.source_id == "6"))
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
    test "a dry run and an import leave the tag and the category of the same slug for an admin's decision, and write no second copy",
         %{site: site, admin: admin} do
      own_terms!(site, admin)
      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      assert %{"10" => {:undecided, "slug_taken"}} = outcomes(run, "tag")
      assert %{"6" => {:undecided, "slug_taken"}} = outcomes(run, "category")
      assert counts(run, "tag").created == length(recorded("tags")) - 1
      assert counts(run, "category").created == length(recorded("categories")) - 1
      assert map_size(blog(Tag, site)) == 1
      assert map_size(blog(Collection, site)) == 1

      run = import!(run, admin)

      assert %{"10" => {:undecided, "slug_taken"}} = outcomes(run, "tag")
      assert {counts(run, "tag").undecided, counts(run, "category").undecided} == {1, 1}
      assert slugs(Tag, site)["elixir"] == 1
      assert slugs(Collection, site)["elixir"] == 1
    end

    test "Connect to the existing record writes no second copy, keeps the site's own as it is, and links the posts to it",
         %{site: site, admin: admin} do
      {tag, collection} = own_terms!(site, admin)
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, [{"tag", "10"}, {"category", "6"}], "keep")

      run = imported!(site, admin)

      for {kind, recording} <- [{"tag", "tags"}, {"category", "categories"}] do
        assert counts(run, kind) ==
                 %{
                   created: length(recorded(recording)) - 1,
                   updated: 0,
                   skipped: 1,
                   failed: 0,
                   undecided: 0
                 }
      end

      assert %{"10" => {:skipped, "connected"}} = outcomes(run, "tag")
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
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, [{"tag", "10"}, {"category", "6"}], "keep")
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

    test "Import as new writes a tag and a category of their own beside the site's, with another slug, and links the posts to them",
         %{site: site, admin: admin} do
      {tag, collection} = own_terms!(site, admin)
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, [{"tag", "10"}, {"category", "6"}], "import")

      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      assert %{"10" => {:created, "another_slug"}} = outcomes(run, "tag")

      run = import!(run, admin)

      assert %{"10" => {:created, "another_slug"}} = outcomes(run, "tag")
      assert %{"6" => {:created, "another_slug"}} = outcomes(run, "category")

      assert {blog(Tag, site)["Elixir"].slug, blog(Tag, site)["Elixir"].id != tag.id} ==
               {"elixir-10", true}

      assert blog(Collection, site)["Elixir"].slug == "elixir-6"
      assert blog(Collection, site)["Elixir, as the site has it"].id == collection.id

      post = posts(site)["Phoenix LiveView tips"]
      assert blog(Tag, site)["Elixir"].id in Enum.map(post.tenant_tags, & &1.id)
      refute tag.id in Enum.map(post.tenant_tags, & &1.id)

      change_in_wordpress!("tag")
      again = imported!(site, admin)
      assert %{"10" => {:updated, "another_slug"}} = outcomes(again, "tag")
      assert blog(Tag, site)["Elixir"].slug == "elixir-10"
    end

    test "Import as new stays once an import wrote it: switching to Connect is refused, and the record is kept and written again",
         %{site: site, admin: admin} do
      {tag, _collection} = own_terms!(site, admin)
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, [{"tag", "10"}], "import")
      imported!(site, admin)
      written = blog(Tag, site)["Elixir"]

      item =
        Enum.find(
          Ash.read!(MigrationItem, tenant: site.id, authorize?: false),
          &(&1.source_kind == "tag" and &1.source_id == "10")
        )

      assert {:error, %Ash.Error.Invalid{errors: [%{field: :decision}]}} =
               MishkaCmsMigration.decide_item(item, "keep", actor: admin, tenant: site.id)

      assert Ash.get!(MigrationItem, item.id, tenant: site.id, authorize?: false).decisions ==
               %{"slug_taken" => "import"}

      change_in_wordpress!("tag")
      again = imported!(site, admin)

      assert %{"10" => {:updated, "another_slug"}} = outcomes(again, "tag")

      assert {blog(Tag, site)["Elixir"].id, blog(Tag, site)["Elixir"].slug} ==
               {written.id, "elixir-10"}

      assert blog(Tag, site)["Elixir, as the site has it"].id == tag.id
    end

    test "a slug WordPress keeps percent-encoded is matched, and made anew, as the Blog stores it",
         %{site: site, admin: admin} do
      tag = tag!(site, admin, %{name: "WordPress, in Persian", slug: "wrdprs"})
      collection!(site, admin, %{name: "Tutorials, in Persian", slug: "amwzsh"})

      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      assert %{"20" => {:undecided, "slug_taken"}} = outcomes(run, "tag")
      assert %{"9" => {:undecided, "slug_taken"}} = outcomes(run, "category")

      decide!(site, admin, [{"tag", "20"}], "keep")
      decide!(site, admin, [{"category", "9"}], "import")
      run = imported!(site, admin)

      assert %{"20" => {:skipped, "connected"}} = outcomes(run, "tag")
      assert blog(Collection, site)["آموزش‌ها"].slug == "amwzsh-9"

      post = posts(site)["نصب وردپرس روی سرور"]
      assert Enum.map(post.tenant_tags, & &1.id) == [tag.id]
      assert Enum.map(post.tenant_collections, & &1.id) == [blog(Collection, site)["آموزش‌ها"].id]
    end

    test "a category that sat under a connected one is written under the site's own", %{
      site: site,
      admin: admin
    } do
      own = collection!(site, admin, %{name: "Guides, as the site has it", slug: "tutorials"})
      site |> wordpress_run!(admin) |> dry_run!(admin)

      [tutorials] =
        for %{source_kind: "category", source_slug: "tutorials"} = item <-
              Ash.read!(MigrationItem, tenant: site.id, authorize?: false),
            do: item

      decide!(site, admin, [{"category", tutorials.source_id}], "keep")

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
               %{
                 created: 0,
                 updated: length(recorded("tags")) - 1,
                 skipped: 1,
                 failed: 0,
                 undecided: 0
               }

      assert %{"15" => {:skipped, "edited_in_cms"}} = outcomes(again, "tag")

      tags = blog(Tag, site)
      assert tags["Search engines"].id == seo.id
      refute is_map_key(tags, "SEO")
    end
  end

  describe "authors" do
    setup %{site: site}, do: %{admin: migration_admin!(site, @people)}

    test "a dry run plans a blogger for the author whose email is a user of the site, skips the others as having no user, and writes nothing in the CMS",
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

      assert counts(run, "user") == %{created: 1, updated: 0, skipped: 4, failed: 0, undecided: 0}
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
               %{created: map_size(wordpress), updated: 0, skipped: 0, failed: 0, undecided: 0}

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
    test "a dry run reports every post as one to create, says which become drafts and what is left as text, and writes nothing in the CMS",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      outcomes = outcomes(run, "post")

      assert counts(run, "post") ==
               %{
                 created: length(recorded("posts")),
                 updated: 0,
                 skipped: 0,
                 failed: 0,
                 undecided: 0
               }

      assert %{
               "32" => {:created, nil},
               "40" => {:created, "draft_from_pending"},
               "41" => {:created, "draft_from_private"},
               "42" => {:created, "draft_from_password"},
               "53" => {:created, "unconverted: acme/callout, core/latest-posts"},
               "34" =>
                 {:created,
                  "frames_allowed: https://www.youtube-nocookie.com, https://player.vimeo.com; " <>
                    "unconverted: unknown_plugin_shortcode, pullbox"}
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

    test "an import points a post's links to a page imported as new beside the site's own at the path it was written at",
         %{site: site} do
      admin = migration_admin!(site, @admin ++ ["admin:dashboard:runtime:page"])
      create_page!(site_id: site.id, path: "/about/team", title: "Our own team")
      site |> wordpress_run!(admin) |> dry_run!(admin)
      decide!(site, admin, [{"page", "25"}], "import")

      imported!(site, admin)

      hrefs =
        posts(site)["Linking between posts and media"]
        |> content()
        |> LazyHTML.query("a")
        |> LazyHTML.attribute("href")

      assert Enum.frequencies(hrefs)["/about/team-25"] == 2
      refute "/about/team" in hrefs
    end

    test "an import points a post's links to the run's posts at their Blog addresses and to its pages at their CMS paths, and keeps every other link",
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
      assert Enum.frequencies(hrefs)["/about/team"] == 2

      assert for(
               link <- LazyHTML.query(html, "a"),
               Enum.any?(LazyHTML.query(link, "img")),
               do: LazyHTML.attribute(link, "href")
             ) == [["/blog/welcome-to-the-mishka-test-blog"]]

      for page_link <- ["http://localhost:8089/?page_id=25", "/about/team/"],
          do: refute(page_link in hrefs)

      for kept <- [
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
               %{
                 created: 0,
                 updated: length(recorded("posts")) - 1,
                 skipped: 1,
                 failed: 0,
                 undecided: 0
               }

      assert %{"39" => {:skipped, "edited_in_cms"}} = outcomes(third, "post")
      posts = posts(site)
      assert posts["Roadmap, edited"].id == draft.id
      refute is_map_key(posts, "Draft roadmap")
    end
  end

  describe "a post's pictures and files" do
    @pictures @admin ++ ["admin:dashboard:runtime:media"]
    @uploads "http://localhost:8089/wp-content/uploads/2026/11/"

    setup %{site: site}, do: %{admin: migration_admin!(site, @pictures)}

    defp reasons({_outcome, reason}), do: String.split(reason || "", "; ")

    defp files(site),
      do:
        MishkaCmsCore.Runtime.Media
        |> Ash.read!(tenant: site.id, authorize?: false)
        |> Map.new(&{&1.name, &1.relative_path})

    test "an import makes the file WordPress featured each post the post's featured image", %{
      site: site,
      admin: admin
    } do
      imported!(site, admin)
      posts = posts(site)
      files = files(site)

      featured =
        for row <- recorded("posts"), into: %{}, do: {row["title"]["raw"], row["featured_media"]}

      assert posts["Welcome to the Mishka Test Blog"].featured_image_url == files["hero"]
      assert posts["Every core block in one post"].featured_image_url == files["cover"]

      for {title, post} <- posts do
        case featured[title] do
          0 -> assert is_nil(post.featured_image_url)
          _id -> assert String.starts_with?(post.featured_image_url, "/uploads/#{site.id}/media/")
        end
      end
    end

    test "an import points a post's images and links to the site's files at their Media files, a size of a file too, and keeps its other links",
         %{site: site, admin: admin} do
      imported!(site, admin)
      posts = posts(site)
      files = files(site)
      linking = content(posts["Linking between posts and media"])
      hrefs = linking |> LazyHTML.query("a") |> LazyHTML.attribute("href")
      classic = content(posts["A classic editor post with shortcodes"])

      assert files["guide"] in hrefs
      assert Enum.frequencies(hrefs)[files["hero"]] == 1
      assert "http://localhost:8089/2026/01/welcome-to-the-mishka-test-blog/hero/" in hrefs
      assert linking |> LazyHTML.query("img") |> LazyHTML.attribute("src") == [files["diagram"]]

      assert classic |> LazyHTML.query("img") |> LazyHTML.attribute("src") |> Enum.take(4) ==
               [files["hero"], files["gallery-1"], files["gallery-2"], files["gallery-3"]]

      assert classic |> LazyHTML.query("video") |> LazyHTML.attribute("src") == [files["sample"]]

      video = posts["A post with a gallery and a video"] |> content() |> LazyHTML.query("video")

      assert {LazyHTML.attribute(video, "src"), LazyHTML.attribute(video, "poster")} ==
               {[files["sample"]], [files["gallery-2"]]}

      located =
        posts
        |> Map.values()
        |> Enum.flat_map(
          &(&1
            |> content()
            |> LazyHTML.query("img[src]")
            |> LazyHTML.attribute("src"))
        )

      assert Enum.all?(located, &String.starts_with?(&1, "/uploads/#{site.id}/media/"))
    end

    test "a post whose featured file was not imported is written with none, and the import says so",
         %{site: site, admin: admin} do
      stub!(%{
        "/wp-content/uploads/2026/11/og-image.jpg" => {"image/jpeg", "<html></html>"},
        "/wp-content/uploads/2026/11/hero.jpg" => :no_site
      })

      run = imported!(site, admin)
      posts = posts(site)
      outcomes = outcomes(run, "post")

      assert is_nil(posts["SEO checklist for a migration"].featured_image_url)
      assert is_nil(posts["Welcome to the Mishka Test Blog"].featured_image_url)
      for id <- ["46", "32"], do: assert("featured_image_missing" in reasons(outcomes[id]))
      refute "featured_image_missing" in reasons(outcomes["33"])

      assert content(posts["A classic editor post with shortcodes"])
             |> LazyHTML.query("a")
             |> LazyHTML.attribute("href")
             |> Enum.member?(@uploads <> "hero.jpg")
    end
  end

  describe "a post's SEO" do
    setup %{site: site},
      do: %{admin: migration_admin!(site, @admin ++ ["admin:dashboard:runtime:media"])}

    defp seo(post), do: Seo.stored_tags(post.seo_tags)

    test "an import keeps what Yoast SEO kept for a post as its SEO tags, its share image at its Media file",
         %{site: site, admin: admin} do
      imported!(site, admin)
      posts = posts(site)

      files =
        MishkaCmsCore.Runtime.Media
        |> Ash.read!(tenant: site.id, authorize?: false)
        |> Map.new(&{&1.name, &1.relative_path})

      checklist = seo(posts["SEO checklist for a migration"])
      blocks = seo(posts["Every core block in one post"])
      tips = seo(posts["Phoenix LiveView tips"])

      assert Seo.tag_value(checklist, "title") == "An SEO checklist for moving a site"
      assert Seo.tag_value(checklist, "description") =~ "Keep addresses"
      assert Seo.tag_value(checklist, "robots") == "noindex, nofollow"
      assert Seo.tag_value(blocks, "og:image") == files["diagram"]

      assert Seo.tag_value(checklist, "og:title") == "SEO checklist (social title)"
      assert Seo.tag_value(checklist, "og:description") =~ "social description"
      assert Seo.tag_value(checklist, "twitter:title") == "SEO checklist (Twitter title)"
      assert Seo.tag_value(checklist, "twitter:description") == "The Twitter description."
      refute Seo.tag_value(blocks, "og:title"), "Yoast's default social title is the page's title"
      refute Seo.tag_value(blocks, "twitter:card"), "the head draws the large card by itself"
      refute Seo.tag_value(blocks, "twitter:image"), "the head repeats the og:image for Twitter"

      assert Seo.tag_value(tips, "canonical") ==
               "https://syndicated.example.test/phoenix-liveview-tips/"

      refute Seo.tag_value(checklist, "og:image"),
             "a share image that is the post's featured image is left to the featured image"

      refute Seo.tag_value(blocks, "canonical"), "a canonical on the old host is dropped"
      assert posts["A minimal post"].seo_tags == []
    end
  end

  describe "a post's videos" do
    @players [
      "https://www.youtube-nocookie.com",
      "https://player.vimeo.com",
      "https://www.youtube.com"
    ]

    setup %{site: site},
      do: %{admin: migration_admin!(site, @admin)}

    defp frame_origins(site) do
      Setting
      |> Ash.read!(tenant: site.id, authorize?: false)
      |> Enum.filter(&(&1.site_id == site.id and &1.key == "security.frame_origins"))
    end

    defp framed(run),
      do:
        for(
          {id, outcome} <- outcomes(run, "post"),
          origins = Enum.find_value(reasons(outcome), &allowed_origins/1),
          into: %{},
          do: {id, origins}
        )

    defp allowed_origins("frames_allowed: " <> origins), do: String.split(origins, ", ")
    defp allowed_origins(_reason), do: nil

    test "a dry run says which posts bring a player the site does not allow, and allows none", %{
      site: site,
      admin: admin
    } do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      assert framed(run) == %{
               "33" => ["https://www.youtube-nocookie.com"],
               "34" => ["https://www.youtube-nocookie.com", "https://player.vimeo.com"],
               "49" => ["https://player.vimeo.com", "https://www.youtube.com"]
             }

      assert frame_origins(site) == []
    end

    test "an import keeps the players and allows their origins on the run's site once, after the ones it allowed",
         %{site: site, admin: admin} do
      other = create_site!()
      maps = "https://www.google.com"

      {:ok, _origins} =
        Settings.put("security.frame_origins", [maps, "https://player.vimeo.com"],
          site_id: site.id
        )

      run = imported!(site, admin)
      [origins] = frame_origins(site)

      assert [^maps | allowed] = origins.value["value"]
      assert Enum.sort(allowed) == Enum.sort(@players)

      assert framed(run) == %{
               "49" => ["https://www.youtube.com"],
               "33" => ["https://www.youtube-nocookie.com"]
             },
             "WordPress lists 49 first, which adds YouTube's origin, then 33 the nocookie one, and 34 adds none"

      assert frame_origins(other) == []

      assert posts(site)["A post with a gallery and a video"]
             |> content()
             |> LazyHTML.query("iframe")
             |> LazyHTML.attribute("src") ==
               [
                 "https://player.vimeo.com/video/76979871",
                 "https://www.youtube.com/embed/jNQXAC9IVRw"
               ]
    end

    test "an admin who may not change the site's settings leaves the posts with a player for a decision, which the next runs follow",
         %{site: site, admin: allowed} do
      admin = migration_admin!(site, List.delete(@admin, "admin:dashboard:setting"))
      outcomes = site |> imported!(admin) |> outcomes("post")

      for id <- ["33", "34", "49"],
          do: assert(outcomes[id] == {:undecided, "player_not_allowed"})

      decide!(site, admin, [{"post", "33"}], "keep")
      decide!(site, admin, [{"post", "49"}], "import")
      outcomes = site |> imported!(admin) |> outcomes("post")

      assert outcomes["33"] == {:skipped, "waits_for_admin"}
      assert outcomes["34"] == {:undecided, "player_not_allowed"}
      assert "player_left_out" in reasons(outcomes["49"])
      assert frame_origins(site) == []

      for post <- Map.values(posts(site)),
          src <- post |> content() |> LazyHTML.query("iframe") |> LazyHTML.attribute("src"),
          do: refute(src =~ ~r{youtube|vimeo})

      run = imported!(site, allowed)

      assert {:created, _reason} = outcomes(run, "post")["33"]
      assert framed(run)["33"] == ["https://www.youtube-nocookie.com"]
      assert [_origins] = frame_origins(site)
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
               %{
                 created: length(published()),
                 updated: 0,
                 skipped: unpublished,
                 failed: 0,
                 undecided: 0
               }

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

  describe "comments" do
    @commenters @people ++ ["admin:dashboard:blog:comment"]
    # The commenters the site has a user for: the editor, who is a WordPress user, and visitors
    # and WordPress users whose comments carry the email of one of its users.
    @members [
      @editor,
      "reza@example.test",
      "mina@example.test",
      "kaveh@example.test",
      "pending@example.test",
      "nadia.karimi@example.test",
      "omid.rahimi@example.test"
    ]
    @on %{comments: true}

    setup %{site: site}, do: %{admin: migration_admin!(site, @commenters)}

    defp members!(site, emails \\ @members),
      do: Map.new(emails, &{&1, create_user!(email: &1, site_id: site.id)})

    defp comments(site),
      do:
        Comment
        |> Ash.read!(tenant: site.id, authorize?: false, load: [:post])
        |> Map.new(&{&1.content, &1})

    defp text(id),
      do:
        "comments"
        |> recorded()
        |> Enum.find(&(&1["id"] == id))
        |> get_in(["content", "raw"])
        |> PlainText.from_html()

    defp written(comments, id), do: comments[text(id)]

    defp parent_text(comments, comment),
      do:
        Enum.find_value(comments, fn {text, %{id: id}} ->
          id == comment.parent_comment_id && text
        end)

    defp stub_comments!(rows),
      do: stub!(%{"/wp-json/wp/v2/comments" => {"application/json", Jason.encode!(rows)}})

    test "with the choice off, a dry run and an import write none, and say the run's choices left them out",
         %{site: site, admin: admin} do
      members!(site)
      dry = site |> wordpress_run!(admin) |> dry_run!(admin)
      run = imported!(site, admin)

      for run <- [dry, run] do
        assert counts(run, "comment") ==
                 %{
                   created: 0,
                   updated: 0,
                   skipped: length(recorded("comments")),
                   failed: 0,
                   undecided: 0
                 }

        assert run |> outcomes("comment") |> Map.values() |> Enum.uniq() ==
                 [{:skipped, "not_chosen"}]
      end

      assert comments(site) == %{}
    end

    test "a dry run plans the comments of the site's users, leaves out a guest's and a page's, and writes nothing in the CMS",
         %{site: site, admin: admin} do
      members!(site)
      run = site |> wordpress_run!(admin, @on) |> dry_run!(admin)

      assert outcomes(run, "comment") ==
               Map.new(~w(2 3 4 5 6 7 9 12 13), &{&1, {:created, nil}})
               |> Map.merge(Map.new(~w(8 14 16), &{&1, {:skipped, "guest_comment"}}))
               |> Map.put("15", {:skipped, "page_comment"})

      assert comments(site) == %{}
      assert imported_items(site) == []
    end

    test "a dry run under create plans a source user's comment too, since the import makes the user",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin, %{comments: true, authors: "create"}) |> dry_run!(admin)
      outcomes = outcomes(run, "comment")

      for id <- ~w(3 5 7 13), do: assert(outcomes[id] == {:created, nil})
      for id <- ~w(2 4 6 8 9 12 14 16), do: assert(outcomes[id] == {:skipped, "guest_comment"})
    end

    test "an import writes each comment on its post, under its parent whichever WordPress lists first, with its status and its text",
         %{site: site, admin: admin} do
      members!(site)
      other = create_site!()

      run = imported!(site, admin, @on)
      comments = comments(site)

      assert counts(run, "comment") == %{
               created: 9,
               updated: 0,
               skipped: 4,
               failed: 0,
               undecided: 0
             }

      assert map_size(comments) == 9

      for id <- [2, 3, 4, 5, 6, 7, 9],
          do: assert(written(comments, id).post.title == "A post with many comments")

      for id <- [12, 13],
          do: assert(written(comments, id).post.title == "Welcome to the Mishka Test Blog")

      for {id, parent} <- %{3 => 2, 4 => 3, 5 => 4, 7 => 6, 13 => 12},
          do: assert(parent_text(comments, written(comments, id)) == text(parent))

      for id <- [2, 6, 9, 12], do: assert(is_nil(written(comments, id).parent_comment_id))

      assert written(comments, 9).status == :pending
      for id <- [2, 3, 4, 5, 6, 7, 12, 13], do: assert(written(comments, id).status == :approved)
      assert written(comments, 6).content == "Bold and a link in a comment."
      assert Comment |> Ash.read!(tenant: other.id, authorize?: false) == []
    end

    test "a comment's author is the user it was written for, not the admin who imported it", %{
      site: site,
      admin: admin
    } do
      users = members!(site)
      imported!(site, admin, @on)
      comments = comments(site)

      for {id, email} <- [
            {2, "reza@example.test"},
            {3, @editor},
            {4, "reza@example.test"},
            {5, "nadia.karimi@example.test"},
            {6, "mina@example.test"},
            {7, "omid.rahimi@example.test"},
            {9, "pending@example.test"},
            {12, "kaveh@example.test"},
            {13, @editor}
          ],
          do: assert(written(comments, id).author_id == users[email].id)

      refute Enum.any?(Map.values(comments), &(&1.author_id == admin.id))
    end

    test "a source user's comment belongs to the user the run made for them, whatever email it carries, and its text is read as text",
         %{site: site, admin: admin} do
      create_user!(email: "reza@example.test", site_id: site.id)

      rows =
        for row <- recorded("comments") do
          case row["id"] do
            2 -> put_in(row, ["content", "raw"], "Tom &amp; Jerry say <b>hi</b>")
            3 -> %{row | "author_email" => "elsewhere@example.test"}
            _other -> row
          end
        end

      stub_comments!(rows)
      imported!(site, admin, %{comments: true, authors: "create"})

      users = accounts(site)
      comments = comments(site)

      assert Map.keys(comments) |> Enum.sort() ==
               Enum.sort(["Tom & Jerry say hi" | Enum.map([3, 4, 5], &text/1)])

      assert comments["Tom & Jerry say hi"].author_id == users["reza@example.test"].id
      assert written(comments, 3).author_id == users[@editor].id
      assert written(comments, 5).author_id == users["nadia.karimi@example.test"].id
    end

    test "a guest's comment is left out as one the Blog cannot keep yet, and so is every reply under it",
         %{site: site, admin: admin} do
      run = imported!(site, admin, %{comments: true, authors: "create"})
      outcomes = outcomes(run, "comment")

      for id <- ~w(2 4 6 8 9 12 14 16),
          do: assert(outcomes[id] == {:skipped, "guest_comment"})

      assert outcomes["15"] == {:skipped, "page_comment"}
      for id <- ~w(3 5 7 13), do: assert(outcomes[id] == {:skipped, "parent_missing"})
      assert comments(site) == %{}
    end

    test "a spam comment and a pingback are left out, whoever sent them", %{
      site: site,
      admin: admin
    } do
      members!(site, ["spam@example.test", "pingback@example.test"])

      for {recording, id, reason} <- [
            {"comments-spam", "10", "spam_or_trash"},
            {"comments-pingback", "11", "not_a_comment"}
          ] do
        stub!(%{"/wp-json/wp/v2/comments" => recording})
        run = imported!(site, admin, @on)

        assert outcomes(run, "comment") == %{id => {:skipped, reason}}
      end

      assert comments(site) == %{}
    end

    test "a comment on a post that was not imported is left out, and the others are written", %{
      site: site,
      admin: admin
    } do
      members!(site)

      stub!(%{
        "/wp-json/wp/v2/posts" =>
          {"application/json",
           recorded("posts") |> Enum.reject(&(&1["id"] == 50)) |> Jason.encode!()}
      })

      run = imported!(site, admin, @on)
      outcomes = outcomes(run, "comment")

      for id <- ~w(2 3 4 5 6 7 9), do: assert(outcomes[id] == {:skipped, "post_missing"})

      assert comments(site) |> Map.values() |> Enum.map(& &1.content) |> Enum.sort() ==
               Enum.sort([text(12), text(13)])
    end

    test "a second run writes no second comment, writes over one WordPress changed, and keeps one an admin moderated",
         %{site: site, admin: admin} do
      members!(site)
      imported!(site, admin, @on)
      before = comments(site)

      again = imported!(site, admin, @on)

      assert again |> outcomes("comment") |> Map.values() |> Enum.frequencies() ==
               %{
                 {:skipped, "unchanged"} => 9,
                 {:skipped, "guest_comment"} => 3,
                 {:skipped, "page_comment"} => 1
               }

      assert comments(site) == before

      written(before, 9)
      |> Ash.Changeset.for_update(:approve, %{}, actor: admin, tenant: site.id)
      |> Ash.update!()

      rows =
        for row <- recorded("comments") do
          if row["id"] in [2, 9],
            do: update_in(row, ["content", "raw"], &(&1 <> " (edited)")),
            else: row
        end

      stub_comments!(rows)
      third = imported!(site, admin, @on)
      outcomes = outcomes(third, "comment")
      comments = comments(site)

      assert outcomes["2"] == {:updated, nil}
      assert outcomes["9"] == {:skipped, "edited_in_cms"}
      assert map_size(comments) == 9
      assert comments[text(2) <> " (edited)"].id == written(before, 2).id
      assert comments[text(9)].status == :approved
      refute is_map_key(comments, text(9) <> " (edited)")
    end

    test "a comment skipped for having no user is written once the site has the user", %{
      site: site,
      admin: admin
    } do
      imported!(site, admin, @on)
      assert comments(site) == %{}

      create_user!(email: "reza@example.test", site_id: site.id)
      run = imported!(site, admin, @on)

      assert %{"2" => {:created, nil}, "4" => {:skipped, "parent_missing"}} =
               outcomes(run, "comment")

      assert comments(site) |> Map.keys() == [text(2)]
    end

    test "an admin the Blog does not let write comments has them fail, and nothing is written", %{
      site: site
    } do
      admin = migration_admin!(site, @people)
      members!(site)

      run = imported!(site, admin, @on)

      assert outcomes(run, "comment")["2"] == {:failed, "forbidden"}
      assert comments(site) == %{}
    end
  end

  describe "what an admin left out" do
    @leavers @people ++ ["admin:dashboard:runtime:redirect", "admin:dashboard:blog:comment"]

    setup %{site: site}, do: %{admin: migration_admin!(site, @leavers)}

    defp leave_out!(site, admin, kind, title),
      do:
        MigrationItem
        |> Ash.read!(tenant: site.id, authorize?: false)
        |> Enum.find(&(&1.source_kind == kind and &1.title == title))
        |> MishkaCmsMigration.leave_out_item!(actor: admin, tenant: site.id)

    defp categories_of(post), do: post.tenant_collections |> Enum.map(& &1.name) |> Enum.sort()

    test "a category takes the categories under it, and its posts are written without them", %{
      site: site,
      admin: admin
    } do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      leave_out!(site, admin, "category", "News")
      run = import!(run, admin)

      assert %{
               "2" => {:skipped, "left_out_by_admin"},
               "3" => {:skipped, "parent_left_out"},
               "4" => {:skipped, "parent_left_out"},
               "5" => {:created, nil}
             } = outcomes(run, "category")

      collections = blog(Collection, site)
      refute Enum.any?(["News", "Releases", "Announcements"], &Map.has_key?(collections, &1))

      welcome = posts(site)["Welcome to the Mishka Test Blog"]
      assert categories_of(welcome) == []
      assert {:created, _note} = outcomes(run, "post")["32"]
    end

    test "a post is not written, its redirect and comments are left out for it, and links to it keep their old address",
         %{site: site, admin: admin} do
      members!(site)

      run = site |> wordpress_run!(admin, %{comments: true}) |> dry_run!(admin)
      leave_out!(site, admin, "post", "Welcome to the Mishka Test Blog")
      run = import!(run, admin)
      posts = posts(site)

      refute Map.has_key?(posts, "Welcome to the Mishka Test Blog")
      assert outcomes(run, "post")["32"] == {:skipped, "left_out_by_admin"}
      assert outcomes(run, "post_redirect")["32"] == {:skipped, "post_missing"}
      assert outcomes(run, "comment")["13"] == {:skipped, "post_missing"}

      hrefs =
        posts["Linking between posts and media"]
        |> content()
        |> LazyHTML.query("a")
        |> LazyHTML.attribute("href")

      refute "/blog/welcome-to-the-mishka-test-blog" in hrefs
      assert "http://localhost:8089/2026/01/welcome-to-the-mishka-test-blog/" in hrefs
      assert Enum.frequencies(hrefs)["/blog/gutenberg-all-core-blocks"] == 2
    end
  end
end
