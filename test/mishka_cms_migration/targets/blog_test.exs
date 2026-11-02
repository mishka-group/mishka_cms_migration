# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.BlogTest do
  @moduledoc """
  A WordPress site's categories and tags moved into Mishka Blog, against what the seeded WordPress
  answered: what a dry run reports, what an import writes and where, what a second run does with
  it, and a node whose Blog targets are stopped.

  A second run sees a term WordPress changed when the term's hash is no longer the one the first
  run recorded, so a test has WordPress change its terms by changing the recorded hashes.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0, recorded: 1]

  alias MishkaBlog.{Collection, Tag}
  alias MishkaCmsCore.Settings
  alias MishkaCmsMigration.MigrationItem
  alias MishkaCmsMigration.Targets.{BlogCollection, BlogTag}

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

    test "writes them in the language the site leads with", %{site: site, admin: admin} do
      forget_settings(~w(site.languages), [site.id])
      {:ok, _} = Settings.put("site.languages", ["fa", "en"], site_id: site.id)

      imported!(site, admin)

      for resource <- [Collection, Tag],
          do: assert(resource |> blog(site) |> Map.values() |> Enum.all?(&(&1.language == "fa")))
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
end
