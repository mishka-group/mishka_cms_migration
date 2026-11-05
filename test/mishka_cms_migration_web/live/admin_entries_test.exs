# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Live.AdminEntriesTest do
  @moduledoc """
  The migration's other entry points into the admin: the Settings page's Migration tab and the Blog
  dashboard's Import button, each offered only to a user who may open the migration page, and the
  migration page opening its New import form when it is reached with `?new_import=<source>`.
  """
  use MishkaCmsMigration.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsMigration.DataCase, only: [register_plugin!: 2]

  alias MishkaBlog.Dashboard.Actions
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCoreWeb.Live.Admin.Components.SettingsPanels
  alias MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.Index
  alias MishkaCmsMigrationWeb.Live.Admin.Dashboard.SettingsTab

  setup %{conn: conn} do
    site = create_site!(name: "localhost", host: "localhost", master: true)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: true,
        master: true
      })

    {:ok, conn: on_host(conn, "localhost"), site: site}
  end

  describe "the Settings tab" do
    test "is offered to a user who may open the migration page", %{site: site} do
      admin = migration_admin!(site, ["admin:dashboard:migration"])

      assert [%{id: "migration", module: SettingsTab, icon: "hero-arrows-right-left"}] =
               SettingsPanels.collect(admin)
    end

    test "is not offered to a user without the migration permission", %{site: site} do
      admin = migration_admin!(site, ["admin:dashboard:runtime:redirect"])

      assert SettingsPanels.collect(admin) == []
    end

    test "holds a New import link for each source and the runs table", %{site: site} do
      admin = migration_admin!(site, ["admin:dashboard:migration"])
      html = render_component(SettingsTab, id: "migration-tab", current_user: admin)

      for source <- ["wordpress", "wordpress_file"],
          do: assert(html =~ ~s|href="/admin/dashboard/migration?new_import=#{source}"|)

      assert html =~ ~s|data-gervaz-loading="migration-settings-runs"|
    end
  end

  describe "the runs table in the Settings tab" do
    @expand ~s|[phx-click="expand_row"]|

    test "has no expand control, which only the migration page can answer", %{
      conn: conn,
      site: site
    } do
      admin = migration_admin!(site, ["admin:dashboard:migration"])
      for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)
      create_run!(site, admin, %{})

      {:ok, view, _html} =
        conn |> signed_in(admin) |> live("/admin/dashboard/settings?tab=migration")

      html = render_async(view)

      assert html =~ "migration-settings-runs"
      assert html =~ ~s|data-role="migration-settings-tab"|

      assert has_element?(
               view,
               "#migration-settings-runs [phx-click=\"dry_run\"], #migration-settings-runs a"
             )

      refute has_element?(view, "#migration-settings-runs #{@expand}")
    end

    test "is still expandable on the migration page", %{conn: conn, site: site} do
      admin = migration_admin!(site, ["admin:dashboard:migration"])
      for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)
      create_run!(site, admin, %{})

      {:ok, view, _html} = conn |> signed_in(admin) |> live("/admin/dashboard/migration")
      render_async(view)

      assert has_element?(view, "#migration-runs-table #{@expand}")
    end
  end

  describe "the Blog button" do
    test "opens the migration page for a user who may open it", %{site: site} do
      admin = migration_admin!(site, ["admin:dashboard:migration"])

      assert [%{id: "migration-import", path: "/admin/dashboard/migration"}] =
               Actions.collect(admin)
    end

    test "is not offered to a user without the migration permission", %{site: site} do
      admin = migration_admin!(site, ["admin:dashboard:runtime:redirect"])

      assert Actions.collect(admin) == []
    end
  end

  describe "the migration page reached from the tab" do
    test "opens the New import form of the source in the address", %{conn: conn, site: site} do
      admin = migration_admin!(site, ["admin:dashboard:migration"])

      {:ok, view, _html} =
        conn |> signed_in(admin) |> live("/admin/dashboard/migration?new_import=wordpress")

      assert render_async(view) =~ "migration-run-form-modal"
      assert_push_event(view, "gervaz:exec-js", %{target: "migration-run-form-modal"})
    end

    test "a source that is not installed opens nothing and says so" do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

      assert {:noreply, %{assigns: %{flash: flash}}} =
               Index.handle_info({:new_run, "ghost"}, socket)

      assert Phoenix.Flash.get(flash, :error) =~ "no longer installed"
    end
  end
end
