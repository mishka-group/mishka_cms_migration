# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.Index do
  @moduledoc """
  The migration's admin page: where an admin moves a site's content here from another CMS.

  Who may open it is the sidebar's declaration (`MishkaCmsMigrationWeb.SidebarMenu`), which
  `MishkaCmsCore.Sidebar.PageGuard` reads on every mount.
  """

  use MishkaCmsCore.ExtensionLiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_new(:current_user, fn -> nil end)
     |> assign(page_title: gettext("Migration"))}
  end
end
