# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.ProvisionTest do
  @moduledoc """
  The migration installs on a site through the CMS's installer, as the blog does: installing it
  creates the permission names its runs are gated by, so a site's admin can be granted the
  migration area and run a migration with it.
  """
  use MishkaCmsMigration.DataCase, async: false

  require Ash.Query

  alias MishkaCmsCore.Accounts.Permission
  alias MishkaCmsCore.Install.Extensions

  defp stored(name),
    do: Permission |> Ash.Query.filter(name == ^name) |> Ash.read!(authorize?: false) |> length()

  defp setter(site),
    do:
      create_user_with_permissions!(["admin:dashboard:runtime:site", "admin:dashboard:setting"],
        site_id: site.id
      )

  test "the installer offers the migration, which adds no tab to the Settings page" do
    assert Enum.any?(Extensions.offered(), &(&1.key == "mishka_cms_migration"))

    %{definitions: definitions} =
      MishkaInstaller.Event.Hook.call("settings:register", %{definitions: []})

    refute Enum.any?(definitions, &String.starts_with?(&1.key, "mishka_cms_migration."))
  end

  test "installing it creates the migration area, which a site's admin is then granted and uses" do
    for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)
    site = create_site!()
    assert stored("admin:dashboard:migration") == 0

    assert {:ok, %{permissions: created}} =
             Extensions.install(site.id, :mishka_cms_migration, %{}, setter(site))

    assert Enum.sort(created) == ["admin:api:migration", "admin:dashboard:migration"]
    assert Extensions.installed?(site.id, :mishka_cms_migration)

    admin = migration_admin!(site, ["admin:dashboard:migration"])
    assert stored("admin:dashboard:migration") == 1

    assert {:ok, _run} =
             MishkaCmsMigration.create_run(
               %{source: "fake", source_host: "old.example.com", secret: "letmein"},
               actor: admin,
               tenant: site.id
             )
  end

  test "installing it again on another site creates nothing new" do
    site = create_site!()
    other = create_site!()
    {:ok, _first} = Extensions.install(site.id, :mishka_cms_migration, %{}, setter(site))

    assert {:ok, %{permissions: []}} =
             Extensions.install(other.id, :mishka_cms_migration, %{}, setter(other))

    assert stored("admin:dashboard:migration") == 1
  end

  test "a user without the site area, or another site's admin, is refused and nothing is created" do
    site = create_site!()
    other = create_site!()
    plain = create_user_with_permissions!(["admin:dashboard:setting"], site_id: site.id)

    assert {:error, {:extension_failed, _message}} =
             Extensions.install(site.id, :mishka_cms_migration, %{}, plain)

    assert {:error, {:extension_failed, _message}} =
             Extensions.install(site.id, :mishka_cms_migration, %{}, setter(other))

    assert stored("admin:dashboard:migration") == 0
    refute Extensions.installed?(site.id, :mishka_cms_migration)
  end
end
