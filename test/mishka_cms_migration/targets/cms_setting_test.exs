# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.CmsSettingTest do
  @moduledoc """
  A WordPress site's name, logo and icon moved into the run's site's settings, against what the
  seeded WordPress answered: what a dry run plans, what an import writes and where, that the site's
  own value is kept, that a logo whose file was not imported is left out, and what a second run
  does after an admin changed a setting.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0, stub!: 1, recorded: 1]

  alias MishkaCmsCore.Runtime.{Media, Setting}
  alias MishkaCmsCore.Settings

  @connection %{"url" => "http://localhost:8089", "user" => "admin"}
  @admin ["admin:dashboard:migration", "admin:dashboard:runtime:media", "admin:dashboard:setting"]
  @keys ["site.title", "site.logo", "site.favicon"]

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
    test "plans the site's name, logo and icon, says the CMS has no tagline and writes nothing",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      assert outcomes(run) == %{
               "title" => {:created, nil},
               "tagline" => {:skipped, "no_setting"},
               "logo" => {:created, nil},
               "icon" => {:created, nil}
             }

      assert settings(site) == %{}
    end
  end

  describe "an import" do
    test "writes the name, and the logo and icon as their imported files, to the run's site only",
         %{site: site, admin: admin} do
      other = create_site!()
      run = imported!(site, admin)

      assert outcomes(run)["tagline"] == {:skipped, "no_setting"}

      assert settings(site) == %{
               "site.title" => "Mishka Test Blog",
               "site.logo" => media(site, "site-logo").relative_path,
               "site.favicon" => media(site, "site-icon").relative_path
             }

      assert settings(other) == %{}
    end

    test "keeps a setting the site already has, in the dry run and the import", %{
      site: site,
      admin: admin
    } do
      {:ok, _title} = Settings.put("site.title", "The site's own", site_id: site.id)

      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      assert outcomes(run)["title"] == {:skipped, "site_own_kept"}

      run = import!(run, admin)

      assert outcomes(run)["title"] == {:skipped, "site_own_kept"}
      assert settings(site)["site.title"] == "The site's own"
      assert settings(site)["site.logo"] == media(site, "site-logo").relative_path
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

      assert %{"title" => {:failed, "forbidden"}, "logo" => {:failed, "forbidden"}} =
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
               "logo" => {:skipped, "unchanged"},
               "icon" => {:skipped, "unchanged"}
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
end
