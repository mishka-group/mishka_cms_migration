# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Live.Admin.Dashboard.SettingsTab.RunsTemplate do
  @moduledoc """
  The Settings tab's runs table template (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.SettingsTab`):
  Gervaz's own `MishkaGervaz.Table.Templates.Table` without its `:expand` feature, so no row draws
  the expand control. Gervaz draws that control for any resource that declares an `:accordion` row
  action, whatever the action's `visible` says, and the details it opens are the migration page's
  to draw, which the Settings page cannot.
  """

  use MishkaGervaz.Table.Behaviours.Template

  alias MishkaGervaz.Table.Templates.Table

  @impl true
  defdelegate name(), to: Table

  @impl true
  defdelegate label(), to: Table

  @impl true
  defdelegate icon(), to: Table

  @impl true
  defdelegate description(), to: Table

  @impl true
  defdelegate default_options(), to: Table

  @impl true
  defdelegate render_item(assigns), to: Table

  @impl true
  def features, do: Table.features() -- [:expand]

  @impl true
  def render(%{static: static} = assigns),
    do: Table.render(%{assigns | static: %{static | features: static.features -- [:expand]}})
end
