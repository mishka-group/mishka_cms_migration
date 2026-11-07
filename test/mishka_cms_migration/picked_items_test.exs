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

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0, stub!: 1]

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

  describe "a post whose tag an admin archived" do
    test "waits for the admin's decision on the tag, though the tag has a record, and is written once the admin restored it",
         %{site: site} do
      admin = migration_admin!(site, @admin ++ ["admin:dashboard:runtime:media"])
      run = site |> wordpress_run!(admin) |> dry_run!(admin) |> import!(admin)

      gutenberg =
        Tag
        |> Ash.read!(tenant: site.id, authorize?: false)
        |> Enum.find(&(&1.name == "Gutenberg"))

      Ash.destroy!(gutenberg, actor: admin, tenant: site.id)
      run = run |> dry_run!(admin) |> import!(admin)
      assert %{outcome: :undecided, reason: "archived_in_cms"} = item(site, "tag", "18")

      Repo.query!(
        "UPDATE mishka_cms_migration_items SET content_hash = 'changed' WHERE source_id = '33'"
      )

      run = import_items!(run, admin, [{"post", "33"}])
      assert %{outcome: :skipped, reason: "waits_for: tag"} = item(site, "post", "33")

      site
      |> item("tag", "18")
      |> MishkaCmsMigration.decide_item!("import", actor: admin, tenant: site.id)

      import_items!(run, admin, [{"tag", "18"}, {"post", "33"}])

      assert %{outcome: :updated, reason: "restored"} = item(site, "tag", "18")
      assert %{outcome: :updated} = item(site, "post", "33")
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

  describe "an item under a parent an admin's choice left out" do
    test "is skipped as its parent being left out, as a whole run says, not as a missing parent",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)

      site
      |> item("category", "5")
      |> MishkaCmsMigration.leave_out_item!(actor: admin, tenant: site.id)

      run = dry_run!(run, admin)
      assert %{plan: :skipped, plan_reason: "parent_left_out"} = item(site, "category", "7")
      assert %{plan: :skipped, plan_reason: "parent_left_out"} = item(site, "category", "8")

      run = dry_run_items!(run, admin, [{"category", "8"}])
      assert %{plan: :skipped, plan_reason: "parent_left_out"} = item(site, "category", "8")

      import_items!(run, admin, [{"category", "8"}])
      assert %{outcome: :skipped, reason: "parent_left_out"} = item(site, "category", "8")
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

      assert touching(started, "mishka_cms_migration_items") == 1
      assert touching(started, "mishka_cms_migration_runs") == 1
      assert length(started) <= 9
      assert touching(job, "mishka_cms_migration_items") == 2
      assert touching(job, "mishka_cms_migration_runs") == 2
      assert length(job) <= 25
    end
  end

  describe "a source that cannot answer for a picked kind" do
    @tag capture_log: true
    test "fails those items alone with the reason, and the run goes back to where it was",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin) |> dry_run!(admin) |> import!(admin)
      tag = item(site, "tag", "13")
      stub!(%{"/wp-json/wp/v2/tags" => :no_site})

      run = import_items!(run, admin, [{"category", "1"}, {"tag", "13"}])

      assert run.status == :done
      assert %{outcome: :failed, reason: "no_site"} = failed = item(site, "tag", "13")
      assert {failed.target_id, failed.title} == {tag.target_id, tag.title}
      assert %{outcome: :skipped, reason: "unchanged"} = item(site, "category", "1")
      assert [%{outcome: :failed, reason: "no_site"}] = entry(run, "tag", "13")

      stub!(%{"/wp-json/" => :no_site})
      run = dry_run_items!(run, admin, [{"tag", "13"}])

      assert run.status == :done
      assert %{plan: :failed, plan_reason: "no_site"} = planned = item(site, "tag", "13")
      assert {planned.title, planned.source_slug} == {tag.title, tag.source_slug}
    end
  end

  describe "a run read before it moved on" do
    test "queues no second job: the run as the database holds it refuses it, in words",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      [id] = ids(site, [{"tag", "13"}])

      assert {:ok, %{status: :importing}} =
               MishkaCmsMigration.import_items(run, [id], actor: admin, tenant: site.id)

      for step <- [&MishkaCmsMigration.import_items/3, &MishkaCmsMigration.dry_run_items/3] do
        assert {:error, %{errors: [%{field: :status} = error]} = refused} =
                 step.(run, [id], actor: admin, tenant: site.id)

        assert MishkaGervaz.Errors.translate_error(error.message, error.vars) ==
                 "An import of this run is running. Wait until it finishes, then try again."

        refute error.message =~ "%{"
        assert MigrationRun.refused_while_running?(refused)
      end

      assert [%{worker: "MishkaCmsMigration.Workers.ImportWorker"}] =
               all_enqueued(queue: :migration)

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
      assert %{outcome: :created} = item(site, "tag", "13")

      dry_running =
        run.id
        |> MishkaCmsMigration.get_run!(actor: admin, tenant: site.id)
        |> MishkaCmsMigration.start_dry_run!(actor: admin, tenant: site.id)

      assert {:error, %{errors: [%{field: :status} = error]} = refused} =
               MishkaCmsMigration.import_items(dry_running, [id], actor: admin, tenant: site.id)

      assert MishkaGervaz.Errors.translate_error(error.message, error.vars) ==
               "A dry run of this run is running. Wait until it finishes, then try again."

      assert MigrationRun.refused_while_running?(refused)
    end
  end

  describe "an admin the CMS does not let change what the items are written to" do
    test "is refused Import this item up front, in words, and the run stays as it was",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin) |> dry_run!(admin)
      migrator = migration_admin!(site, ["admin:dashboard:migration"])
      [id] = ids(site, [{"tag", "13"}])

      for step <- [&MishkaCmsMigration.import_items/3, &MishkaCmsMigration.dry_run_items/3] do
        assert {:error, %{errors: [%{field: :items} = error]} = refused} =
                 step.(run, [id], actor: migrator, tenant: site.id)

        assert MishkaGervaz.Errors.translate_error(error.message, error.vars) ==
                 "You may not change tags on this site."

        refute MigrationRun.refused_while_running?(refused)
      end

      assert all_enqueued(queue: :migration) == []
      assert MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id).status == :dry_run
    end

    test "fails those items with the reason when it runs the run again, and the run finishes",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin) |> dry_run!(admin) |> import!(admin)
      migrator = migration_admin!(site, ["admin:dashboard:migration"])

      again = MishkaCmsMigration.start_dry_run!(run, actor: migrator, tenant: site.id)
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)

      assert MishkaCmsMigration.get_run!(again.id, actor: admin, tenant: site.id).status ==
               :dry_run

      assert %{plan: :failed, plan_reason: "forbidden: tag"} = item(site, "tag", "13")

      assert MigrationRun.reason_label("forbidden: tag") ==
               "You may not change tags on this site"
    end
  end

  describe "a run whose password an earlier release cleared" do
    test "takes no Run again and no job of picked items, refused in words, and nothing is queued",
         %{site: site, admin: admin} do
      run = site |> wordpress_run!(admin) |> dry_run!(admin) |> import!(admin)

      Repo.query!(
        "UPDATE mishka_cms_migration_runs SET connection_secret = NULL WHERE id = $1",
        [Ecto.UUID.dump!(run.id)]
      )

      run = MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id)
      refute MigrationRun.connectable?(run)
      [id] = ids(site, [{"tag", "13"}])

      for step <- [
            &MishkaCmsMigration.start_dry_run(run, actor: admin, tenant: &1),
            &MishkaCmsMigration.dry_run_items(run, [id], actor: admin, tenant: &1),
            &MishkaCmsMigration.import_items(run, [id], actor: admin, tenant: &1)
          ] do
        assert {:error, %{errors: [error]} = refused} = step.(site.id)

        assert MishkaGervaz.Errors.translate_error(error.message, error.vars) ==
                 "This run no longer holds its WordPress password. Start a New import."

        refute MigrationRun.refused_while_running?(refused)
      end

      assert all_enqueued(queue: :migration) == []
      assert MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id).status == :done
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
        assert MigrationRun.refused_while_running?(error)
      end

      assert MishkaCmsMigration.get_run!(done.id, actor: admin, tenant: site.id).status == :done
      assert [_other_run_only] = all_enqueued(queue: :migration)
    end
  end
end
