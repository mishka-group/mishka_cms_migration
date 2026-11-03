# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.SiteBoundaryTest do
  @moduledoc """
  Who reaches a run and its items. A site user acts only on its own site, even one holding `"*"`;
  a master (a user whose `site_id` is nil) reaches every site; anyone without the migration area is
  refused, nobody but the jobs records an item, and only the site's own admins, or a master, leave
  one out or bring it back.
  """
  use MishkaCmsMigration.DataCase, async: false

  alias MishkaCmsMigration.{MigrationItem, MigrationRun}

  setup do
    for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)

    site_a = create_site!()
    site_b = create_site!()
    admin_a = migration_admin!(site_a)
    run = migrate!(site_a, admin_a, %{"redirect" => [redirect_row(1, "/old", "/new")]})

    %{
      site_a: site_a,
      site_b: site_b,
      admin_a: admin_a,
      admin_b: create_user_with_permissions!(["*"], site_id: site_b.id),
      run: run
    }
  end

  defp read(resource, actor, tenant), do: Ash.read(resource, actor: actor, tenant: tenant)

  test "a site's admin reads its own runs and items, and another site's admin none of them", %{
    site_a: site_a,
    site_b: site_b,
    admin_a: admin_a,
    admin_b: admin_b,
    run: run
  } do
    assert {:ok, [%{id: run_id}]} = read(MigrationRun, admin_a, site_a.id)
    assert run_id == run.id
    assert {:ok, [_item]} = read(MigrationItem, admin_a, site_a.id)

    assert {:ok, []} = read(MigrationRun, admin_b, site_b.id)
    assert {:ok, []} = read(MigrationItem, admin_b, site_b.id)
    assert {:error, %Ash.Error.Forbidden{}} = read(MigrationRun, admin_b, site_a.id)
    assert {:error, %Ash.Error.Forbidden{}} = read(MigrationItem, admin_b, site_a.id)
  end

  test "another site's admin cannot start a run of this site", %{
    site_a: site_a,
    admin_a: admin_a,
    admin_b: admin_b
  } do
    run = create_run!(site_a, admin_a, %{})

    assert {:error, %Ash.Error.Forbidden{}} =
             MishkaCmsMigration.start_dry_run(run, actor: admin_b, tenant: site_a.id)

    assert {:error, %Ash.Error.Forbidden{}} =
             MishkaCmsMigration.create_run(%{source: "fake", source_host: "old.example.com"},
               actor: admin_b,
               tenant: site_a.id
             )
  end

  test "an import writes only to its own site", %{site_b: site_b} do
    assert Ash.read!(MishkaCmsCore.Runtime.Redirect, tenant: site_b.id, authorize?: false) == []
  end

  test "a run's steps and its read are refused to another site's admin and to a user without the area",
       %{site_a: site_a, admin_a: admin_a, admin_b: admin_b} do
    writer =
      create_user_with_permissions!(["admin:dashboard:runtime:redirect"], site_id: site_a.id)

    pending = create_run!(site_a, admin_a, %{"redirect" => [redirect_row(2, "/b", "/c")]})
    reported = site_a |> create_run!(admin_a, %{}) |> dry_run!(admin_a)

    for actor <- [admin_b, writer] do
      assert {:error, %Ash.Error.Forbidden{}} =
               MishkaCmsMigration.get_run(pending.id, actor: actor, tenant: site_a.id)

      assert {:error, %Ash.Error.Forbidden{}} =
               MishkaCmsMigration.start_dry_run(pending, actor: actor, tenant: site_a.id)

      assert {:error, %Ash.Error.Forbidden{}} =
               MishkaCmsMigration.start_import(reported, actor: actor, tenant: site_a.id)

      assert {:error, %Ash.Error.Forbidden{}} =
               MishkaCmsMigration.cancel_run(pending, actor: actor, tenant: site_a.id)
    end

    assert MishkaCmsMigration.get_run!(pending.id, actor: admin_a, tenant: site_a.id).status ==
             :pending
  end

  test "a user without the migration area is refused, on their own site too", %{site_a: site_a} do
    writer =
      create_user_with_permissions!(["admin:dashboard:runtime:redirect"], site_id: site_a.id)

    assert {:error, %Ash.Error.Forbidden{}} = read(MigrationRun, writer, site_a.id)
    assert {:error, %Ash.Error.Forbidden{}} = read(MigrationItem, writer, site_a.id)

    assert {:error, %Ash.Error.Forbidden{}} =
             MishkaCmsMigration.create_run(%{source: "fake", source_host: "old.example.com"},
               actor: writer,
               tenant: site_a.id
             )

    assert {:error, %Ash.Error.Forbidden{}} = read(MigrationRun, nil, site_a.id)
  end

  test "a master reaches any site's runs and starts one there", %{site_a: site_a, site_b: site_b} do
    master = create_user_with_permissions!(["admin:dashboard:migration"])

    assert {:ok, [_run]} = read(MigrationRun, master, site_a.id)

    assert {:ok, %{site_id: site_b_id, user_id: master_id}} =
             MishkaCmsMigration.create_run(
               %{source: "fake", source_host: "old.example.com", secret: "letmein"},
               actor: master,
               tenant: site_b.id
             )

    assert {site_b_id, master_id} == {site_b.id, master.id}
  end

  test "nobody records an item but the jobs", %{site_a: site_a, admin_a: admin_a, run: run} do
    master = create_user_with_permissions!(["*"])
    item = %{source_host: "old.example.com", source_kind: "redirect", source_id: "99"}

    for actor <- [admin_a, master] do
      assert {:error, %Ash.Error.Forbidden{}} =
               MishkaCmsMigration.record_item(
                 Map.merge(item, %{run_id: run.id, outcome: :created}),
                 actor: actor,
                 tenant: site_a.id
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               MishkaCmsMigration.record_item_plan(Map.put(item, :plan, :created),
                 actor: actor,
                 tenant: site_a.id
               )
    end
  end

  describe "an admin's choice on an item" do
    setup %{site_a: site_a} do
      [item] = Ash.read!(MigrationItem, tenant: site_a.id, authorize?: false)
      %{item: item}
    end

    test "is made by the site's admin, and by a master through the master actions", %{
      site_a: site_a,
      admin_a: admin_a,
      item: item
    } do
      assert {:ok, %{left_out: true}} =
               MishkaCmsMigration.leave_out_item(item, actor: admin_a, tenant: site_a.id)

      master = create_user_with_permissions!(["admin:dashboard:migration"])
      {:ok, as_master} = MigrationItem.fetch(item.id, master)

      assert {:ok, %{left_out: false}} =
               Ash.update(as_master, %{}, action: :master_bring_back, actor: master)

      assert {:ok, %{left_out: true}} =
               MishkaCmsMigration.leave_out_item(item, actor: master, tenant: site_a.id)
    end

    test "is refused to another site's admin, to a user without the area and to nobody", %{
      site_a: site_a,
      site_b: site_b,
      admin_b: admin_b,
      item: item
    } do
      writer =
        create_user_with_permissions!(["admin:dashboard:runtime:redirect"], site_id: site_a.id)

      for {actor, tenant} <- [{admin_b, site_a.id}, {admin_b, site_b.id}, {writer, site_a.id}] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 MishkaCmsMigration.leave_out_item(item, actor: actor, tenant: tenant)
      end

      {:ok, as_master} =
        MigrationItem.fetch(item.id, create_user_with_permissions!(["admin:dashboard:migration"]))

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(as_master, %{}, action: :master_leave_out, actor: admin_b)

      assert {:error, %Ash.Error.Forbidden{}} =
               MishkaCmsMigration.leave_out_item(item, tenant: site_a.id)

      assert [%{left_out: false}] = Ash.read!(MigrationItem, tenant: site_a.id, authorize?: false)
    end

    test "is refused while one of the site's runs is dry running or importing, and not after", %{
      site_a: site_a,
      admin_a: admin_a,
      item: item
    } do
      running =
        site_a
        |> create_run!(admin_a, %{"redirect" => [redirect_row(1, "/old", "/new")]})
        |> MishkaCmsMigration.start_dry_run!(actor: admin_a, tenant: site_a.id)

      assert {:error, %Ash.Error.Invalid{errors: [%{message: message}]}} =
               MishkaCmsMigration.leave_out_item(item, actor: admin_a, tenant: site_a.id)

      assert message =~ "is running"

      MishkaCmsMigration.cancel_run!(running, actor: admin_a, tenant: site_a.id)

      assert {:ok, %{left_out: true}} =
               MishkaCmsMigration.leave_out_item(item, actor: admin_a, tenant: site_a.id)
    end

    test "maps only to a record of the item's own kind on its own site", %{
      site_a: site_a,
      site_b: site_b,
      admin_a: admin_a,
      item: item
    } do
      redirect =
        Ash.read_one!(MishkaCmsCore.Runtime.Redirect, tenant: site_a.id, authorize?: false)

      assert {:ok, %{mapped_id: mapped_id, left_out: false}} =
               item
               |> MishkaCmsMigration.leave_out_item!(actor: admin_a, tenant: site_a.id)
               |> MishkaCmsMigration.map_item(redirect.id, actor: admin_a, tenant: site_a.id)

      assert mapped_id == redirect.id

      theirs =
        MishkaCmsCore.Runtime.Redirect
        |> Ash.Changeset.for_create(:create, %{from_path: "/x", to: "/y", status: 301},
          tenant: site_b.id,
          authorize?: false
        )
        |> Ash.create!()

      for id <- [theirs.id, Ecto.UUID.generate(), item.id] do
        assert {:error, %Ash.Error.Invalid{errors: [%{field: :mapped_id}]}} =
                 MishkaCmsMigration.map_item(item, id, actor: admin_a, tenant: site_a.id)
      end

      assert {:error, %Ash.Error.Forbidden{}} =
               MishkaCmsMigration.map_item(item, redirect.id,
                 actor: create_user_with_permissions!(["*"], site_id: site_b.id),
                 tenant: site_a.id
               )
    end

    test "is not held by another site's run", %{
      site_a: site_a,
      site_b: site_b,
      admin_a: admin_a,
      item: item
    } do
      admin = migration_admin!(site_b)

      site_b
      |> create_run!(admin, %{})
      |> MishkaCmsMigration.start_dry_run!(actor: admin, tenant: site_b.id)

      assert {:ok, %{left_out: true}} =
               MishkaCmsMigration.leave_out_item(item, actor: admin_a, tenant: site_a.id)
    end
  end
end
