# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.CmsSettingTest do
  @moduledoc """
  A WordPress site's name, tagline, logo and icon (as the favicon and the app icon) moved into the
  run's site's settings, against what the
  seeded WordPress answered: what a dry run plans, what an import writes and where, that a setting
  the site has its own value for waits for an admin's decision and follows it, that a logo whose
  file was not imported is left out, and what a second run does after an admin changed a setting.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0, stub!: 1, recorded: 1]

  alias MishkaCmsCore.Runtime.{Media, Setting}
  alias MishkaCmsCore.Settings

  @connection %{"url" => "http://localhost:8089", "user" => "admin"}
  @admin ["admin:dashboard:migration", "admin:dashboard:runtime:media", "admin:dashboard:setting"]
  @keys ["site.title", "site.tagline", "site.logo", "site.favicon", "site.app_icon"]

  setup do
    stub!()
    site = create_site!()
    %{site: site, admin: migration_admin!(site, @admin)}
  end

  defp wordpress_run!(site, admin, options \\ %{}) do
    %{source: "wordpress", connection: @connection, secret: "app password", options: options}
    |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)
  end

  defp imported!(site, admin),
    do: site |> wordpress_run!(admin) |> dry_run!(admin) |> import!(admin)

  defp outcomes(run) do
    for %{kind: "setting"} = entry <- run.report.entries,
        into: %{},
        do: {entry.source_id, {entry.outcome, entry.reason}}
  end

  defp settings(site) do
    for key <- @keys,
        [setting] <- [site_rows(site, key)],
        into: %{},
        do: {key, setting.value["value"]}
  end

  defp site_rows(site, key) do
    Setting
    |> Ash.read!(tenant: site.id, authorize?: false)
    |> Enum.filter(&(&1.site_id == site.id and &1.key == key))
  end

  defp item(site, source_id) do
    MishkaCmsMigration.MigrationItem
    |> Ash.read!(tenant: site.id, authorize?: false)
    |> Enum.find(&(&1.source_kind == "setting" and &1.source_id == source_id))
  end

  defp decide!(site, admin, source_id, choice),
    do:
      site
      |> item(source_id)
      |> MishkaCmsMigration.decide_item!(choice, actor: admin, tenant: site.id)

  defp media(site, name) do
    Media
    |> Ash.read!(tenant: site.id, authorize?: false)
    |> Enum.find(&(&1.name == name))
  end

  defp index_with(fields),
    do: %{
      "/wp-json/" =>
        {"application/json", "index" |> recorded() |> Map.merge(fields) |> Jason.encode!()}
    }

  describe "a dry run" do
    test "plans the site's name, tagline, logo and icon as the favicon and the app icon, and writes nothing",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      assert outcomes(run) == %{
               "title" => {:created, nil},
               "tagline" => {:created, nil},
               "logo" => {:created, nil},
               "icon" => {:created, nil},
               "app_icon" => {:created, nil}
             }

      assert settings(site) == %{}
    end
  end

  describe "an import" do
    test "writes the name and tagline, and the logo and icon as their imported files, the icon as the favicon and the app icon, to the run's site only",
         %{site: site, admin: admin} do
      other = create_site!()
      run = imported!(site, admin)

      assert outcomes(run)["tagline"] == {:created, nil}
      icon = media(site, "site-icon").relative_path

      assert settings(site) == %{
               "site.title" => "Mishka Test Blog",
               "site.tagline" =>
                 "A WordPress site filled with realistic content for testing the Mishka CMS migration",
               "site.logo" => media(site, "site-logo").relative_path,
               "site.favicon" => icon,
               "site.app_icon" => icon
             }

      assert Settings.get("site.tagline", nil, site.id) ==
               "A WordPress site filled with realistic content for testing the Mishka CMS migration"

      assert settings(other) == %{}
    end

    test "leaves a setting the site already has for an admin's decision, in the dry run and the import",
         %{site: site, admin: admin} do
      {:ok, _title} = Settings.put("site.title", "The site's own", site_id: site.id)

      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      assert outcomes(run)["title"] == {:undecided, "site_has_own"}

      assert Enum.count(run.report.entries, &(&1.kind == "setting" and &1.outcome == :undecided)) ==
               1

      run = import!(run, admin)

      assert outcomes(run)["title"] == {:undecided, "site_has_own"}
      assert settings(site)["site.title"] == "The site's own"
      assert settings(site)["site.logo"] == media(site, "site-logo").relative_path

      assert %{plan: :undecided, outcome: :undecided, reason: "site_has_own", decisions: %{}} =
               item(site, "title")
    end

    test "keeps the site's own once an admin decides so, on every later run", %{
      site: site,
      admin: admin
    } do
      {:ok, _title} = Settings.put("site.title", "The site's own", site_id: site.id)
      imported!(site, admin)

      decide!(site, admin, "title", "keep")

      for _run <- 1..2 do
        run = site |> wordpress_run!(admin) |> dry_run!(admin)
        assert outcomes(run)["title"] == {:skipped, "site_own_kept"}
        assert outcomes(import!(run, admin))["title"] == {:skipped, "site_own_kept"}
      end

      assert settings(site)["site.title"] == "The site's own"
    end

    test "writes the WordPress one over the site's own setting once an admin decides so, and says so",
         %{site: site, admin: admin} do
      {:ok, _title} = Settings.put("site.title", "The site's own", site_id: site.id)
      [own] = site_rows(site, "site.title")
      site |> wordpress_run!(admin) |> dry_run!(admin)

      decide!(site, admin, "title", "import")

      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      assert outcomes(run)["title"] == {:created, "site_own_replaced"}
      assert settings(site)["site.title"] == "The site's own"

      run = import!(run, admin)

      assert outcomes(run)["title"] == {:created, "site_own_replaced"}
      assert settings(site)["site.title"] == "Mishka Test Blog"
      assert [%{id: id}] = site_rows(site, "site.title")
      assert id == own.id
      assert outcomes(imported!(site, admin))["title"] == {:skipped, "unchanged"}
    end

    test "refuses a choice the conflict does not offer, and a decision where nothing waits", %{
      site: site,
      admin: admin
    } do
      {:ok, _title} = Settings.put("site.title", "The site's own", site_id: site.id)
      site |> wordpress_run!(admin) |> dry_run!(admin)

      for {source_id, choice} <- [{"title", "leave_out"}, {"title", "drop"}, {"icon", "keep"}] do
        assert {:error, %Ash.Error.Invalid{errors: [%{field: :decision}]}} =
                 site
                 |> item(source_id)
                 |> MishkaCmsMigration.decide_item(choice, actor: admin, tenant: site.id)
      end

      assert item(site, "title").decisions == %{}
    end

    test "leaves out a logo whose file was not imported", %{site: site, admin: admin} do
      svg = Enum.find(recorded("media"), &(&1["mime_type"] == "image/svg+xml"))
      stub!(index_with(%{"site_logo" => svg["id"]}))

      run = imported!(site, admin)

      assert outcomes(run)["logo"] == {:skipped, "file_missing"}
      refute is_map_key(settings(site), "site.logo")
      assert is_map_key(settings(site), "site.favicon")
    end

    test "fails each setting for an admin who may not change the site's settings", %{site: site} do
      admin = migration_admin!(site, List.delete(@admin, "admin:dashboard:setting"))

      run = imported!(site, admin)

      assert %{
               "title" => {:failed, "forbidden: setting"},
               "logo" => {:failed, "forbidden: setting"}
             } =
               outcomes(run)

      assert settings(site) == %{}
    end
  end

  describe "a second run" do
    test "leaves alone what WordPress did not change", %{site: site, admin: admin} do
      imported!(site, admin)

      run = imported!(site, admin)

      assert %{
               "title" => {:skipped, "unchanged"},
               "tagline" => {:skipped, "unchanged"},
               "logo" => {:skipped, "unchanged"},
               "icon" => {:skipped, "unchanged"},
               "app_icon" => {:skipped, "unchanged"}
             } = outcomes(run)
    end

    test "writes over a name WordPress changed, in the same setting, unless an admin changed it since",
         %{site: site, admin: admin} do
      imported!(site, admin)
      [before] = site_rows(site, "site.title")
      stub!(index_with(%{"name" => "Mishka &amp; Friends"}))

      run = imported!(site, admin)

      assert outcomes(run)["title"] == {:updated, nil}
      assert settings(site)["site.title"] == "Mishka & Friends"
      assert [%{id: id}] = site_rows(site, "site.title")
      assert id == before.id

      {:ok, _title} = Settings.put("site.title", "Renamed in the CMS", site_id: site.id)
      stub!(index_with(%{"name" => "Mishka and Friends"}))

      run = imported!(site, admin)

      assert outcomes(run)["title"] == {:skipped, "edited_in_cms"}
      assert settings(site)["site.title"] == "Renamed in the CMS"
    end
  end

  describe "a run with a site setting switched off in the New import window" do
    test "leaves that setting out, as the admin's own leave-out, in the list and in the import",
         %{site: site, admin: admin} do
      run =
        site |> wordpress_run!(admin, %{site_icon: false, site_logo: false}) |> dry_run!(admin)

      assert %{
               "title" => {:created, nil},
               "logo" => {:skipped, "left_out_by_admin"},
               "icon" => {:skipped, "left_out_by_admin"},
               "app_icon" => {:skipped, "left_out_by_admin"}
             } = Map.take(outcomes(run), ["title", "logo", "icon", "app_icon"])

      assert %{left_out: true, plan: :skipped, plan_reason: "left_out_by_admin"} =
               item(site, "icon")

      assert MishkaCmsMigration.MigrationItem.standing(item(site, "icon")) == :left_out
      refute item(site, "title").left_out

      import!(run, admin)

      assert Map.keys(settings(site)) |> Enum.sort() == ["site.tagline", "site.title"]
    end

    test "can be brought back on the Items page, and a later dry run does not leave it out again",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin, %{site_icon: false}) |> dry_run!(admin)
      assert item(site, "icon").left_out

      MishkaCmsMigration.bring_back_item!(item(site, "icon"), actor: admin, tenant: site.id)
      run = dry_run!(run, admin)

      assert outcomes(run)["icon"] == {:created, nil}
      refute item(site, "icon").left_out

      run = import!(run, admin)
      assert outcomes(run)["icon"] == {:created, nil}
      assert settings(site)["site.favicon"] == media(site, "site-icon").relative_path
    end

    test "lists the site's settings like any item, each with Leave out and Bring back",
         %{site: site, admin: admin} do
      site |> wordpress_run!(admin) |> dry_run!(admin)

      for id <- ["title", "logo", "icon"] do
        refute item(site, id).left_out

        left = MishkaCmsMigration.leave_out_item!(item(site, id), actor: admin, tenant: site.id)
        assert left.left_out
        assert MishkaCmsMigration.MigrationItem.standing(left) == :left_out

        back = MishkaCmsMigration.bring_back_item!(left, actor: admin, tenant: site.id)
        refute back.left_out
      end
    end
  end
end
