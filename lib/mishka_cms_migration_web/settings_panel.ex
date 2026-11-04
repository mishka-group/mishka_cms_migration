# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.SettingsPanel do
  @moduledoc """
  The Settings page's Migration tab, a `"settings:panels"` plugin
  (`MishkaCmsCoreWeb.Live.Admin.Components.SettingsPanels`). The tab holds the latest runs and a New
  import button for each source (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.SettingsTab`).

  It answers a tab only for a user who may open the migration page, the sidebar entry's own check
  (`MishkaCmsCore.Sidebar.visible_to?/2`), so any other user sees none.

  Registered in `MishkaCmsMigration.Application`.
  """

  use MishkaInstaller.Event.Hook, event: "settings:panels", initial: %{priority: 55}
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Sidebar
  alias MishkaCmsMigrationWeb.Live.Admin.Dashboard.SettingsTab
  alias MishkaCmsMigrationWeb.SidebarMenu

  @impl true
  def call(%{panels: panels, current_user: user} = data),
    do: {:reply, %{data | panels: panels ++ panel(user)}}

  defp panel(user) do
    [entry | _items] = SidebarMenu.items()

    if Sidebar.visible_to?(entry, user),
      do: [
        %{
          id: "migration",
          label: gettext("Migration"),
          icon: "hero-arrows-right-left",
          priority: 30,
          module: SettingsTab
        }
      ],
      else: []
  end
end
