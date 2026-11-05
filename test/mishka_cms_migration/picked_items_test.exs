# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.PickedItemsTest do
  @moduledoc """
  Dry run this item and Import this item, against what the seeded WordPress answered: a job of
  picked items writes those items alone and leaves every other one as it was, finds what they need
  among what earlier imports wrote and waits, in words, for what they did not, reads only their rows
  from WordPress, puts its run back where it was with the items counted in its report, and is
  refused, as Run again is, while another run of the site is running.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0]

  alias MishkaBlog.{BlogPost, Comment, Tag}
  alias MishkaCmsMigration.{MigrationItem, MigrationRun}

  @connection %{"url" => "http://localhost:8089", "user" => "admin"}
  @admin [
    "admin:dashboard:migration",
    "admin:dashboard:blog:post",
    "admin:dashboard:blog:comment",
    "admin:dashboard:setting"
  ]

  setup do
    stub!()
    site = create_site!()
    %{site: site, admin: migration_admin!(site, @admin)}
  end

  defp wordpress_run!(site, admin, options \\ %{}) do
    %{source: "wordpress", connection: @connection, secret: "app password", options: options}
    |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)
  end

  defp items(%{id: site_id}), do: items(site_id)

  defp items(site_id),
    do:
      MigrationItem
      |> Ash.read!(tenant: site_id, authorize?: false)
      |> Map.new(&{{&1.source_kind, &1.source_id}, &1})

  defp item(site, kind, source_id), do: Map.fetch!(items(site), {kind, source_id})

  defp ids(site, picks), do: for({kind, id} <- picks, do: item(site, kind, id).id)

  defp dry_run_items!(run, admin, picks),
    do:
      run
      |> MishkaCmsMigration.dry_run_items!(ids(run.site_id, picks),
        actor: admin,
        tenant: run.site_id
      )
      |> drained()

  defp import_items!(run, admin, picks),
    do:
      run
      |> MishkaCmsMigration.import_items!(ids(run.site_id, picks),
        actor: admin,
        tenant: run.site_id
      )
      |> drained()

  defp drained(run) do
    %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)

    MishkaCmsMigration.get_run!(run.id,
      tenant: run.site_id,
      authorize?: false,
      load: [:created_count, :skipped_count]
    )
  end

  defp requests do
    receive do
      {:wordpress_request, conn} -> [{conn.request_path, conn.query_params} | requests()]
    after
      0 -> []
    end
  end

  defp touching(queries, table), do: Enum.count(queries, &(&1 =~ ~s("#{table}")))

  defp entry(run, kind, source_id),
    do: Enum.filter(run.report.entries, &({&1.kind, &1.source_id} == {kind, source_id}))

  describe "Import this item" do
    test "writes the item alone, leaves every other item as it was, and puts the run back",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      before = items(site)

      after_import = import_items!(run, admin, [{"tag", "13"}])
      tag = item(site, "tag", "13")

      assert {after_import.id, after_import.status} == {run.id, :dry_run}
      assert {tag.outcome, tag.run_id} == {:created, run.id}
      assert [%{id: id}] = Ash.read!(Tag, tenant: site.id, authorize?: false)
      assert tag.target_id == id
      assert Map.delete(items(site), {"tag", "13"}) == Map.delete(before, {"tag", "13"})
      assert [%{outcome: :created}] = entry(after_import, "tag", "13")
      assert after_import.report.counts == run.report.counts
      assert after_import.created_count == 1
    end

    test "waits for a category it points at that was never imported, and writes the post once it is",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      run = import_items!(run, admin, [{"user", "1"}])

      run = dry_run_items!(run, admin, [{"post", "52"}])
      assert %{plan: :skipped, plan_reason: "waits_for: category"} = item(site, "post", "52")

      run = import_items!(run, admin, [{"post", "52"}])

      assert %{outcome: :skipped, reason: "waits_for: category", target_id: nil} =
               item(site, "post", "52")

      assert MigrationRun.reason_label("waits_for: category") ==
               "Waits until its categories are imported"

      assert Ash.read!(BlogPost, tenant: site.id, authorize?: false) == []
      assert %{outcome: nil, target_id: nil} = item(site, "category", "1")

      run = import_items!(run, admin, [{"category", "1"}])
      run = import_items!(run, admin, [{"post", "52"}])

      assert %{outcome: :created, target_id: post_id} = item(site, "post", "52")
      assert %{target_id: category_id} = item(site, "category", "1")

      post =
        Ash.get!(BlogPost, post_id,
          tenant: site.id,
          authorize?: false,
          load: [:tenant_collections]
        )

      assert Enum.map(post.tenant_collections, & &1.id) == [category_id]

      assert run.status == :dry_run
      assert [%{outcome: :created}] = entry(run, "post", "52")
    end
  end

  describe "the rows it settles" do
    test "are broadcast, where a whole run's job broadcasts none of its items",
         %{site: site, admin: admin} do
      topic = "migration_item:#{site.id}:updated"
      :ok = MishkaCmsMigration.TestEndpoint.subscribe(topic)

      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      refute_received %Phoenix.Socket.Broadcast{topic: ^topic}

      dry_run_items!(run, admin, [{"tag", "13"}])

      assert_received %Phoenix.Socket.Broadcast{
        topic: ^topic,
        payload: %{data: %{source_kind: "tag", source_id: "13", plan: :created}}
      }

      refute_received %Phoenix.Socket.Broadcast{topic: ^topic}
    end
  end

  describe "a comment alone" do
    test "waits for its post, and is written on the post an import of picked items wrote",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin, %{comments: true}) |> dry_run!(admin)

      run = dry_run_items!(run, admin, [{"comment", "2"}])
      assert %{plan: :skipped, plan_reason: "post_missing"} = item(site, "comment", "2")

      run = import_items!(run, admin, [{"comment", "2"}])
      assert %{outcome: :skipped, reason: "post_missing"} = item(site, "comment", "2")

      run =
        import_items!(run, admin, [
          {"user", "2"},
          {"category", "2"},
          {"tag", "13"},
          {"post", "50"}
        ])

      assert %{outcome: :created, target_id: post_id} = item(site, "post", "50")

      import_items!(run, admin, [{"comment", "2"}])

      assert %{outcome: :created, target_id: comment_id} = item(site, "comment", "2")

      assert %{post_id: ^post_id} =
               Ash.get!(Comment, comment_id, tenant: site.id, authorize?: false)

      assert %{outcome: nil} = item(site, "comment", "3")
    end
  end

  describe "what one item costs" do
    test "an import of one tag asks WordPress for that tag alone, and reads and writes its item once",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      requests()

      [id] = ids(site, [{"tag", "13"}])

      started =
        queries_while(fn ->
          MishkaCmsMigration.import_items!(run, [id], actor: admin, tenant: site.id)
        end)

      job = queries_while(fn -> %{success: 1} = Oban.drain_queue(queue: :migration) end)

      assert [
               {"/wp-json/", _index},
               {"/wp-json/wp/v2/users/me", _me},
               {"/wp-json/wp/v2/tags", %{"include" => "13"}}
             ] = requests()

      assert {touching(started, "mishka_cms_migration_items"), length(started)} == {1, 8}
      assert touching(job, "mishka_cms_migration_items") == 2
      assert touching(job, "mishka_cms_migration_runs") == 2
      assert length(job) <= 25
    end
  end

  describe "while another run of the site is running" do
    test "Run again, Dry run this item and Import this item are refused, and nothing changes",
         %{site: site, admin: admin} do
      done = site |> wordpress_run!(admin) |> dry_run!(admin) |> import!(admin)
      [id] = ids(site, [{"tag", "13"}])

      site
      |> wordpress_run!(admin)
      |> MishkaCmsMigration.start_dry_run!(actor: admin, tenant: site.id)

      for step <- [
            &MishkaCmsMigration.start_dry_run(done, actor: admin, tenant: &1),
            &MishkaCmsMigration.dry_run_items(done, [id], actor: admin, tenant: &1),
            &MishkaCmsMigration.import_items(done, [id], actor: admin, tenant: &1)
          ] do
        assert {:error, error} = step.(site.id)
        assert Exception.message(error) =~ "still waiting or running"
      end

      assert MishkaCmsMigration.get_run!(done.id, actor: admin, tenant: site.id).status == :done
      assert [_other_run_only] = all_enqueued(queue: :migration)
    end
  end
end
