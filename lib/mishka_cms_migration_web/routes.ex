# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Routes do
  @moduledoc """
  The migration's routes: its admin page, `/admin/dashboard/migration`.
  """

  @behaviour MishkaCmsCore.ExtensionRouter

  @impl true
  def routes(:admin),
    do: [{:live, "/migration", MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.Index, :index}]

  def routes(_type), do: []
end
