# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.CmsMediaTest do
  @moduledoc """
  A WordPress site's media library moved into the CMS's Media, against what the seeded WordPress
  answered and the files it was seeded with (`dev/wordpress/media`), served by the stub: what a dry
  run plans without downloading, what an import stores and where, which files are left out and why,
  and that a second run downloads nothing. A file that lies about itself is a stub answer of the
  test's own.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0, stub!: 1, recorded: 1]

  alias MishkaCmsCore.Runtime.{Media, MediaCategory}
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Targets.CmsMedia

  @connection %{"url" => "http://localhost:8089", "user" => "admin"}
  @admin ["admin:dashboard:migration", "admin:dashboard:runtime:media"]
  @uploads "/wp-content/uploads/2026/11/"
  @seeded Path.expand("../../../dev/wordpress/media", __DIR__)

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

  defp counts(run) do
    run.report.kinds
    |> Enum.find(&(&1.kind == "media"))
    |> Map.take(MishkaCmsMigration.Report.outcomes())
  end

  defp outcomes(run) do
    for %{kind: "media"} = entry <- run.report.entries,
        into: %{},
        do: {entry.source_id, {entry.outcome, entry.reason}}
  end

  defp media(site),
    do: Media |> Ash.read!(tenant: site.id, authorize?: false) |> Map.new(&{&1.name, &1})

  defp stored(media) do
    {:ok, %{active: path}} = Media.storage_paths(media.relative_path, media.site_id)
    File.read!(path)
  end

  defp seeded(name), do: @seeded |> Path.join(name) |> File.read!()

  defp downloads do
    receive do
      {:wordpress_request, %{request_path: "/wp-json" <> _}} -> downloads()
      {:wordpress_request, %{host: host, request_path: path}} -> [host <> path | downloads()]
    after
      0 -> []
    end
  end

  defp listed_media(fun) do
    rows = "media" |> recorded() |> Enum.map(fun)
    %{"/wp-json/wp/v2/media" => {"application/json", Jason.encode!(rows)}}
  end

  defp files, do: length(recorded("media")) - 1

  describe "a dry run" do
    test "plans every file Media can keep, skips the SVG, downloads nothing and writes nothing in the CMS",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      assert counts(run) == %{created: files(), updated: 0, skipped: 1, failed: 0, undecided: 0}
      assert outcomes(run)["21"] == {:skipped, "type_not_allowed"}
      assert downloads() == []
      assert media(site) == %{}
    end
  end

  describe "an import" do
    test "stores each file in Media of the run's site only, in its wordpress folder, with its own bytes and its alt text",
         %{site: site, admin: admin} do
      other = create_site!()
      run = imported!(site, admin)
      media = media(site)

      assert counts(run) == %{created: files(), updated: 0, skipped: 1, failed: 0, undecided: 0}
      assert map_size(media) == files()
      assert media(other) == %{}

      assert [folder] = Ash.read!(MediaCategory, tenant: site.id, authorize?: false)
      assert {folder.name, folder.parent_id} == {"wordpress", nil}
      assert Enum.all?(Map.values(media), &(&1.media_category_id == folder.id))

      hero = media["hero"]

      assert {hero.type, hero.format, hero.size} == {:images, "jpg", 43_354}
      assert hero.description == "A blue gradient hero image with a white circle"
      assert String.starts_with?(hero.relative_path, "/uploads/#{site.id}/media/#{folder.id}/")
      assert stored(hero) == seeded("hero.jpg")

      assert {media["sample"].type, media["guide"].type} == {:videos, :documents}
      assert stored(media["photo"]) == seeded("photo.webp")
      assert media["avatar-parisa"].description == "Portrait placeholder of Parisa"
      refute is_map_key(media, "logo-svg")
    end

    test "leaves out a file WordPress says is too big, or keeps on another host, without asking for it",
         %{site: site, admin: admin} do
      stub!(
        listed_media(fn
          %{"id" => 6} = row -> %{row | "filesize" => 60_000_000}
          %{"id" => 5} = row -> %{row | "source_url" => "https://cdn.example.com/cover.jpg"}
          %{"id" => 12} = row -> %{row | "source_url" => "ftp://localhost:8089/animated.gif"}
          row -> row
        end)
      )

      run = imported!(site, admin)
      asked = downloads()

      assert Map.take(outcomes(run), ["6", "5", "12"]) == %{
               "6" => {:skipped, "too_big"},
               "5" => {:skipped, "not_on_source"},
               "12" => {:skipped, "not_on_source"}
             }

      for file <- ["localhost#{@uploads}gallery-1.jpg", "cdn.example.com/cover.jpg"],
          do: refute(file in asked)

      assert "localhost#{@uploads}hero.jpg" in asked

      assert map_size(media(site)) == files() - 3
    end

    test "leaves out a file sent as another type, one whose bytes are not its type and one bigger than Media takes, and fails one the source does not send",
         %{site: site, admin: admin} do
      stub!(%{
        (@uploads <> "diagram.png") => {"image/png", "<html><script>alert(1)</script></html>"},
        (@uploads <> "photo.webp") => {"text/html", seeded("photo.webp")},
        (@uploads <> "sample.mp4") => {"video/mp4", :binary.copy(<<0>>, 50_000_001)},
        (@uploads <> "guide.pdf") => :no_site
      })

      run = imported!(site, admin)
      media = media(site)

      assert Map.take(outcomes(run), ["10", "11", "14", "13"]) == %{
               "10" => {:skipped, "wrong_bytes"},
               "11" => {:skipped, "wrong_type"},
               "14" => {:skipped, "too_big"},
               "13" => {:failed, "not_downloaded"}
             }

      assert counts(run) == %{
               created: files() - 4,
               updated: 0,
               skipped: 4,
               failed: 1,
               undecided: 0
             }

      for name <- ["diagram", "photo", "sample", "guide"],
          do: refute(is_map_key(media, name))
    end
  end

  describe "a second run" do
    test "downloads nothing and writes no second copy of a file WordPress did not change", %{
      site: site,
      admin: admin
    } do
      imported!(site, admin)
      before = media(site)
      [_ | _] = downloads()

      again = imported!(site, admin)

      assert counts(again) == %{
               created: 0,
               updated: 0,
               skipped: files() + 1,
               failed: 0,
               undecided: 0
             }

      assert again |> outcomes() |> Map.delete("21") |> Map.values() |> Enum.uniq() ==
               [{:skipped, "unchanged"}]

      assert downloads() == []
      assert media(site) == before
    end

    test "writes over the description of a file WordPress changed, and downloads it no more", %{
      site: site,
      admin: admin
    } do
      imported!(site, admin)
      [_ | _] = downloads()
      hero = media(site)["hero"]

      Repo.query!(
        "UPDATE mishka_cms_migration_items SET content_hash = 'changed' WHERE source_kind = 'media'"
      )

      again = imported!(site, admin)

      assert counts(again) == %{created: 0, updated: files(), skipped: 1, failed: 0, undecided: 0}
      assert downloads() == []
      assert media(site)["hero"].relative_path == hero.relative_path
      assert stored(media(site)["hero"]) == seeded("hero.jpg")
    end
  end

  describe "srcset" do
    @site_uploads "http://localhost:8089" <> @uploads

    defp srcset_item(html, media) do
      {:ok, item} =
        Item.build(%{
          kind: "post",
          source_id: "1",
          title: "T",
          content: [%{html: html}],
          attrs: %{"media" => media}
        })

      item
    end

    defp srcsets(html),
      do:
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[srcset]")
        |> LazyHTML.attribute("srcset")

    test "relinking points every candidate of an img's and a picture source's srcset at its Media file, keeping descriptors, sizes and other URLs",
         %{site: site, admin: admin} do
      stub!(%{(@uploads <> "gallery-2.jpg") => :no_site})
      imported!(site, admin)
      media = media(site)
      context = %{source_host: "localhost:8089", actor: admin, site_id: site.id, mode: :import}

      html =
        ~s(<img src="#{@site_uploads}gallery-1.jpg" sizes="100vw, 800px" ) <>
          ~s(srcset="#{@site_uploads}gallery-1.jpg 800w, #{@site_uploads}gallery-1-300x225.jpg 300w, https://cdn.example.test/x.jpg 2x, #{@site_uploads}gallery-2.jpg 100w">) <>
          ~s(<picture><source srcset="#{@site_uploads}hero-300x169.jpg 1x"><img src="/x.png"></picture>)

      moved = %{
        (@site_uploads <> "gallery-1.jpg") => 6,
        (@site_uploads <> "gallery-1-300x225.jpg") => 6,
        (@site_uploads <> "hero-300x169.jpg") => 4,
        (@site_uploads <> "gallery-2.jpg") => 7
      }

      [img, source] = html |> CmsMedia.relinked(moved, context) |> srcsets()
      gallery = media["gallery-1"].relative_path

      assert img ==
               "#{gallery} 800w, #{gallery} 300w, https://cdn.example.test/x.jpg 2x, " <>
                 "#{@site_uploads}gallery-2.jpg 100w"

      assert source == "#{media["hero"].relative_path} 1x"

      relinked = CmsMedia.relinked(html, moved, context)
      assert relinked =~ ~s(sizes="100vw, 800px")

      assert CmsMedia.srcset_note(srcset_item(html, moved), context) == "srcset_file_missing"
    end

    test "no note when every candidate was imported, none is a file of the source, or the run is a dry run",
         %{site: site, admin: admin} do
      stub!()
      imported!(site, admin)
      context = %{source_host: "localhost:8089", actor: admin, site_id: site.id, mode: :import}

      html =
        ~s(<img srcset="#{@site_uploads}gallery-1.jpg 800w, https://cdn.example.test/x.jpg 2x">)

      moved = %{(@site_uploads <> "gallery-1.jpg") => 6}

      refute CmsMedia.srcset_note(srcset_item(html, moved), context)
      refute CmsMedia.srcset_note(srcset_item(html, %{}), context)
      refute CmsMedia.srcset_note(srcset_item(html, %{"/gone.jpg" => 99}), context)
      refute CmsMedia.srcset_note(srcset_item(html, %{"x" => 99}), %{context | mode: :dry_run})
    end
  end
end
