# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.ElementorTest do
  @moduledoc """
  A WordPress site's pages and post laid out with Elementor moved into the CMS, against what the
  seeded WordPress answered for them (`elementor-pages`, `elementor-posts`): a page the page
  builder opens, a post in the Blog, and a page with widgets the CMS has no equivalent for waiting
  for an admin's decision, in the dry run too, until the admin imports it with the fallback HTML
  for those widgets or leaves it out.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 1]

  alias MishkaBlog.BlogPost
  alias MishkaCmsCore.Runtime.Authoring.Tree
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsMigration.{MigrationItem, MigrationRun}
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Targets.Helpers.Widgets

  @connection %{"url" => "http://localhost:8089", "user" => "admin"}
  @admin [
    "admin:dashboard:migration",
    "admin:dashboard:runtime:page",
    "admin:dashboard:runtime:media",
    "admin:dashboard:blog:post",
    "admin:dashboard:setting"
  ]
  @answers %{
    "/wp-json/wp/v2/pages" => "elementor-pages",
    "/wp-json/wp/v2/posts" => "elementor-posts"
  }
  @landing "110"
  @contact "113"
  @post "115"
  @widgets "unsupported_widgets: form, google_maps, image-carousel, slides"

  setup do
    stub!(@answers)
    site = create_site!()
    %{site: site, admin: migration_admin!(site, @admin)}
  end

  defp wordpress_run!(site, admin) do
    %{source: "wordpress", connection: @connection, secret: "app password", options: %{}}
    |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)
  end

  defp imported!(site, admin),
    do: site |> wordpress_run!(admin) |> dry_run!(admin) |> import!(admin)

  defp outcomes(run, kind),
    do:
      for(
        %{kind: ^kind} = entry <- run.report.entries,
        into: %{},
        do: {entry.source_id, {entry.outcome, entry.reason}}
      )

  defp pages(site),
    do: Page |> Ash.read!(tenant: site.id, authorize?: false) |> Map.new(&{&1.path, &1})

  defp item(site, source_id),
    do:
      MigrationItem
      |> Ash.read!(tenant: site.id, authorize?: false)
      |> Enum.find(&(&1.source_kind == "page" and &1.source_id == source_id))

  defp decide!(site, admin, source_id, choice),
    do:
      site
      |> item(source_id)
      |> MishkaCmsMigration.decide_item!(choice, actor: admin, tenant: site.id)

  describe "a dry run" do
    test "plans a page with widgets the CMS has no equivalent for as waiting for a decision that names them, and writes nothing",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      assert %{@landing => {:created, _}, @contact => {:undecided, @widgets}} =
               outcomes(run, "page")

      assert %{@post => {:created, _}} = outcomes(run, "post")
      assert pages(site) == %{}

      contact = item(site, @contact)
      assert MigrationItem.conflict(contact) == "unsupported_widgets"
      assert MigrationRun.reason_label(@widgets) =~ "form, google_maps, image-carousel, slides"

      assert MigrationItem.decision_options(%{form: %Phoenix.HTML.Form{data: contact}}) == [
               {"Import with the fallback HTML for those parts", "import"},
               {"Leave the page out", "leave_out"}
             ]
    end
  end

  describe "an import" do
    test "writes an Elementor page the page builder opens as its own sections, and keeps the one that waits out",
         %{site: site, admin: admin} do
      run = imported!(site, admin)

      assert %{@landing => {:created, _}, @contact => {:undecided, @widgets}} =
               outcomes(run, "page")

      assert [landing] = Map.values(pages(site))
      assert landing.path == "/elementor-landing"
      assert {:ok, %Tree{roots: [_wrapper]}} = Tree.parse(landing.template)

      html = LazyHTML.from_fragment(landing.template)
      assert html |> LazyHTML.query("section") |> Enum.count() == 3

      assert html |> LazyHTML.query("section h1") |> Enum.map(&LazyHTML.text/1) == [
               "Move your WordPress site to Mishka CMS"
             ]

      assert html |> LazyHTML.query("a.inline-block") |> Enum.map(&LazyHTML.text/1) == [
               "Contact us"
             ]
    end

    test "writes an Elementor post to the Blog as its HTML", %{site: site, admin: admin} do
      run = imported!(site, admin)

      assert %{@post => {:created, _}} = outcomes(run, "post")
      assert [post] = BlogPost |> Ash.read!(tenant: site.id, authorize?: false)
      html = LazyHTML.from_fragment(post.content)

      assert html |> LazyHTML.query(".md\\:grid-cols-3 h3") |> Enum.map(&LazyHTML.text/1) == [
               "Faster",
               "Safer",
               "Easier"
             ]

      assert [_, _, _, _, _] = images = html |> LazyHTML.query("img") |> LazyHTML.attribute("src")
      assert Enum.all?(images, &String.starts_with?(&1, "/uploads/"))

      assert html |> LazyHTML.query("iframe[src^='https://player.vimeo.com/']") |> Enum.count() ==
               1
    end
  end

  describe "the decision" do
    test "Import with the fallback HTML writes the page with what Elementor drew for those widgets, and says so",
         %{site: site, admin: admin} do
      imported!(site, admin)
      decide!(site, admin, @contact, "import")

      fallback = "fallback_html: google_maps, image-carousel; no_fallback: form, slides"
      assert outcomes(imported!(site, admin), "page")[@contact] == {:created, fallback}
      assert MigrationRun.reason_label(fallback) =~ "No fallback available for form, slides"

      contact = pages(site)["/elementor-contact"]
      assert {:ok, %Tree{}} = Tree.parse(contact.template)
      assert contact.template =~ "maps.google.com/maps"
    end

    test "Leave the page out leaves it out of every later run, and writes nothing for it", %{
      site: site,
      admin: admin
    } do
      imported!(site, admin)
      decide!(site, admin, @contact, "leave_out")

      assert outcomes(imported!(site, admin), "page")[@contact] == {:skipped, "left_out_by_admin"}
      refute Map.has_key?(pages(site), "/elementor-contact")
      assert item(site, @contact).left_out
    end

    test "holds for the page with every such widget it has, and the report names them all" do
      {:ok, item} =
        Item.build(%{kind: "page", source_id: 1, attrs: %{"unsupported_widgets" => ["form"]}})

      assert Widgets.call(item, %{decisions: %{}}) == {:undecided, "unsupported_widgets: form"}

      decided = %{decisions: %{"1" => %{"unsupported_widgets" => "import"}}}
      more = put_in(item.attrs["unsupported_widgets"], ["form", "slides"])

      assert Widgets.call(more, decided) == :ok
      assert Widgets.waiting(more, decided) == nil
      assert Widgets.note(more, decided) == "fallback_html: form, slides"

      drawn_nothing = put_in(more.attrs["no_fallback_widgets"], ["form", "slides"])
      assert Widgets.note(drawn_nothing, decided) == "no_fallback: form, slides"
    end
  end
end
