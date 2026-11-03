# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.SidebarMenu do
  @moduledoc """
  The migration's admin page and its sidebar entry, a `"sidebar:menus"` plugin
  (`MishkaCmsCore.Sidebar`). It lands in the core's **Plugins** section, and the core never names
  it: removing this extension removes the entry.

  The page is `admin:dashboard:migration`'s, the permission the runs themselves are gated by, and so
  is a run's Items page, declared beside it as a page that is not a link (`nav: false`). They read
  their gate from here:

      MishkaCmsMigrationWeb.SidebarMenu.permissions("migration")

  Registered in `MishkaCmsMigration.Application`.
  """

  use MishkaInstaller.Event.Hook, event: "sidebar:menus", initial: %{priority: 55}
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Sidebar
  alias MishkaCmsCore.Sidebar.Item

  @permissions ["admin:dashboard:migration"]

  @items Enum.map(
           [
             %{
               extension: :mishka_cms_migration,
               key: "migration",
               label: gettext_noop("Migration"),
               icon: "hero-arrows-right-left",
               path: "/admin/dashboard/migration",
               module: MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.Index,
               group: "plugins",
               order: 30,
               permissions: @permissions,
               credit_name: "Mishka CMS",
               credit_url: "https://mishka.tools/cms"
             },
             %{
               extension: :mishka_cms_migration,
               key: "migration.items",
               label: gettext_noop("Items"),
               path: "/admin/dashboard/migration/runs",
               module: MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Index,
               nav: false,
               permissions: @permissions
             }
           ],
           &Item.new!/1
         )

  @doc "This extension's sidebar entry and the admin pages it owns."
  @spec items() :: [Item.t()]
  def items, do: @items

  @doc "The permissions declared for one of this extension's pages. See `MishkaCmsCore.Sidebar.permissions/2`."
  @spec permissions(String.t()) :: [MishkaCmsCore.Accounts.Checks.AccessPermissions.requirement()]
  def permissions(key), do: Sidebar.permissions(@items, key)

  @impl true
  def call(%{items: items} = data), do: {:reply, %{data | items: items ++ @items}}
end
