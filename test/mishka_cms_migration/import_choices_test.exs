# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.ImportChoicesTest do
  @moduledoc """
  What the New import window's switches do to a run, against what the seeded WordPress answered: a
  kind switched off is left out as the admin's own leave-out for the items no run has met, listed
  as Left out by you, and written nowhere; what the admin brings back stays brought back.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0]

  alias MishkaBlog.BlogPost
  alias MishkaCmsMigration.MigrationItem

  @connection %{"url" => "http://localhost:8089", "user" => "admin"}
  @admin [
    "admin:dashboard:migration",
    "admin:dashboard:blog:post",
    "admin:dashboard:blog:category",
    "admin:dashboard:blog:tag",
    "admin:dashboard:runtime:media",
    "admin:dashboard:runtime:page",
    "admin:dashboard:setting"
  ]

  setup do
    stub!()
    site = create_site!()
    %{site: site, admin: migration_admin!(site, @admin)}
  end

  defp wordpress_run!(site, admin, options) do
    %{source: "wordpress", connection: @connection, secret: "app password", options: options}
    |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)
  end

  defp items(site, kind),
    do:
      MigrationItem
      |> Ash.read!(tenant: site.id, authorize?: false)
      |> Enum.filter(&(&1.source_kind == kind))

  test "a kind switched off is left out item by item, and the kinds left on are planned as before",
       %{site: site, admin: admin} do
    run = wordpress_run!(site, admin, %{bring_posts: false, bring_media: false})
    run = dry_run!(run, admin)

    for kind <- ["post", "media"] do
      assert [_ | _] = items = items(site, kind)

      assert Enum.all?(items, fn item ->
               item.left_out and item.plan == :skipped and
                 MigrationItem.standing(item) == :left_out
             end)
    end

    for kind <- ["category", "tag", "page"] do
      assert [_ | _] = items = items(site, kind)
      refute Enum.any?(items, & &1.left_out)
    end

    assert %{counts: %{skipped: skipped}} = run.report
    assert skipped >= length(items(site, "post")) + length(items(site, "media"))

    import!(run, admin)

    assert BlogPost |> Ash.read!(tenant: site.id, authorize?: false) == []
  end

  test "an item the admin brings back is written, and a later dry run keeps it brought back",
       %{site: site, admin: admin} do
    run = site |> wordpress_run!(admin, %{bring_posts: false}) |> dry_run!(admin)
    [back | _] = items(site, "post")

    MishkaCmsMigration.bring_back_item!(back, actor: admin, tenant: site.id)
    run = dry_run!(run, admin)

    for item <- items(site, "post"),
        do: assert(item.left_out == (item.source_id != back.source_id))

    import!(run, admin)

    assert [%{title: title}] = BlogPost |> Ash.read!(tenant: site.id, authorize?: false)
    assert title == back.title
  end
end
