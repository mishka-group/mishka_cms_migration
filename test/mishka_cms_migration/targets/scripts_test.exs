# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.ScriptsTest do
  @moduledoc """
  A page or a post whose content holds a `<script>` or an inline event handler (`onclick`,
  `onerror`, ...) waits for an admin's decision, in the dry run too, until the admin removes them or
  keeps them, trusting the content. A page comes from the fake source, a post from what the seeded
  WordPress answered, with a handler written into its content.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 1, recorded: 1]

  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsMigration.{MigrationItem, MigrationRun}

  @admin ["admin:dashboard:migration", "admin:dashboard:runtime:page"]
  @blog [
    "admin:dashboard:migration",
    "admin:dashboard:blog:post",
    "admin:dashboard:runtime:media",
    "admin:dashboard:setting"
  ]
  @html ~s|<p>Hello <a href="/about" onclick="track()">about</a></p><script>track()</script>|
  @conflict "scripts: onclick on a, script"

  setup do
    site = create_site!()
    for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)
    %{site: site, admin: migration_admin!(site, @admin)}
  end

  defp rows,
    do: [
      %{
        "id" => 1,
        "title" => "Page 1",
        "slug" => "page-1",
        "permalink_template" => "http://old.example.com/%pagename%/",
        "content" => [%{"html" => @html}]
      }
    ]

  defp outcomes(run, kind),
    do:
      for(
        %{kind: ^kind} = entry <- run.report.entries,
        into: %{},
        do: {entry.source_id, {entry.outcome, entry.reason}}
      )

  defp pages(site), do: Page |> Ash.read!(tenant: site.id, authorize?: false)

  defp item(site, kind, id),
    do:
      MigrationItem
      |> Ash.read!(tenant: site.id, authorize?: false)
      |> Enum.find(&(&1.source_kind == kind and &1.source_id == id))

  defp decide!(site, admin, kind, id, choice),
    do:
      site
      |> item(kind, id)
      |> MishkaCmsMigration.decide_item!(choice, actor: admin, tenant: site.id)

  describe "a page with scripts or inline event handlers" do
    test "waits for a decision that names them, in the dry run too, and is not written", %{
      site: site,
      admin: admin
    } do
      run = site |> create_run!(admin, %{"page" => rows()}) |> dry_run!(admin)

      assert outcomes(run, "page")["1"] == {:undecided, @conflict}
      assert item(site, "page", "1").plan_reason == @conflict

      assert MigrationRun.reason_label(@conflict) ==
               "Contains scripts or inline event handlers: onclick on a, script"

      assert outcomes(import!(run, admin), "page")["1"] == {:undecided, @conflict}
      assert pages(site) == []

      assert MigrationItem.decision_options(%{
               form: %Phoenix.HTML.Form{data: item(site, "page", "1")}
             }) == [{"Remove them", "import"}, {"Keep them (I trust this content)", "trust"}]
    end

    test "Remove them writes the page without them, and says so", %{site: site, admin: admin} do
      migrate!(site, admin, %{"page" => rows()})
      decide!(site, admin, "page", "1", "import")

      assert outcomes(migrate!(site, admin, %{"page" => rows()}), "page")["1"] ==
               {:created, "scripts_removed: onclick on a, script"}

      assert [page] = pages(site)
      html = LazyHTML.from_fragment(page.template)
      assert html |> LazyHTML.query("script, [onclick]") |> Enum.empty?()
      assert html |> LazyHTML.query("a[href='/about']") |> Enum.count() == 1
    end

    test "Keep them writes the page with them, as the admin trusts it", %{
      site: site,
      admin: admin
    } do
      migrate!(site, admin, %{"page" => rows()})
      decide!(site, admin, "page", "1", "trust")

      assert outcomes(migrate!(site, admin, %{"page" => rows()}), "page")["1"] ==
               {:created, "scripts_kept: onclick on a, script"}

      assert [page] = pages(site)
      html = LazyHTML.from_fragment(page.template)
      assert html |> LazyHTML.query("script") |> Enum.count() == 1
      assert html |> LazyHTML.query("a[onclick]") |> Enum.count() == 1
    end

    test "Keep the site as it is, for picked rows, never trusts them" do
      assert MigrationItem.choices("scripts") == ["import", "trust"]
      refute "keep" in MigrationItem.choices("scripts")
    end
  end

  describe "a post with an inline event handler" do
    test "waits for a decision in the dry run", %{site: site} do
      admin = migration_admin!(site, @blog)
      [post | _] = recorded("posts")
      handled = put_in(post, ["content", "raw"], ~s|<p><img src="/x.png" onerror="steal()"></p>|)
      stub!(%{"/wp-json/wp/v2/posts" => {"application/json", Jason.encode!([handled])}})

      run =
        %{
          source: "wordpress",
          connection: %{"url" => "http://localhost:8089", "user" => "admin"},
          secret: "app password",
          options: %{}
        }
        |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)
        |> dry_run!(admin)

      assert outcomes(run, "post")[to_string(post["id"])] ==
               {:undecided, "scripts: onerror on img"}
    end
  end
end
