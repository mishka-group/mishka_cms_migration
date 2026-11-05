# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Live.AdminEntriesTest do
  @moduledoc """
  The migration's other entry point into the admin: the Blog dashboard's Import button, offered only
  to a user who may open the migration page, and the migration page refusing a source that is no
  longer installed.
  """
  use MishkaCmsMigration.ConnCase, async: false

  alias MishkaBlog.Dashboard.Actions
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.Index

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

  describe "the migration page" do
    test "a source that is not installed opens nothing and says so" do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

      assert {:noreply, %{assigns: %{flash: flash}}} =
               Index.handle_event("new_run", %{"source" => "ghost"}, socket)

      assert Phoenix.Flash.get(flash, :error) =~ "no longer installed"
    end
  end
end
