# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.BlogAction do
  @moduledoc """
  The Import button on the Blog dashboard's header, a `"blog:dashboard:actions"` plugin
  (`MishkaBlog.Dashboard.Actions`). It opens the migration page
  (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.Index`), whose New import form offers the
  Blog's choices; the form is not limited to the Blog's kinds.

  It answers a button only for a user who may open the migration page, the sidebar entry's own
  check (`MishkaCmsCore.Sidebar.visible_to?/2`). The event exists only where the Blog is loaded; on
  a node without it the plugin is never called.

  Registered in `MishkaCmsMigration.Application`.
  """

  use MishkaInstaller.Event.Hook, event: "blog:dashboard:actions", initial: %{priority: 55}
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Sidebar
  alias MishkaCmsMigrationWeb.SidebarMenu

  @impl true
  def call(%{actions: actions, current_user: user} = data),
    do: {:reply, %{data | actions: actions ++ action(user)}}

  defp action(user) do
    [%{path: path} = entry | _items] = SidebarMenu.items()

    if Sidebar.visible_to?(entry, user),
      do: [
        %{
          id: "migration-import",
          label: gettext("Import"),
          icon: "hero-arrow-down-tray",
          priority: 50,
          path: path
        }
      ],
      else: []
  end
end
