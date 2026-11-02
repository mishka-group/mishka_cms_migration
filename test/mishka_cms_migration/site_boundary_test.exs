# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.SiteBoundaryTest do
  @moduledoc """
  Who reaches a run and its items. A site user acts only on its own site, even one holding `"*"`;
  a master (a user whose `site_id` is nil) reaches every site; anyone without the migration area is
  refused, and nobody but the system records an item.
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
             MishkaCmsMigration.create_run(%{source: "fake", source_host: "old.example.com"},
               actor: master,
               tenant: site_b.id
             )

    assert {site_b_id, master_id} == {site_b.id, master.id}
  end

  test "nobody records an item but the import job", %{site_a: site_a, admin_a: admin_a, run: run} do
    master = create_user_with_permissions!(["*"])

    for actor <- [admin_a, master] do
      assert {:error, %Ash.Error.Forbidden{}} =
               MishkaCmsMigration.record_item(
                 %{
                   source_host: "old.example.com",
                   source_kind: "redirect",
                   source_id: "99",
                   run_id: run.id,
                   outcome: :created
                 },
                 actor: actor,
                 tenant: site_a.id
               )
    end
  end
end
