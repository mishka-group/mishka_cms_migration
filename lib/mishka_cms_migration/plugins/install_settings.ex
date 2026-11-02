# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Plugins.InstallSettings do
  @moduledoc """
  Registers the two per-site settings every installable extension carries, under the Migration tab
  of the Settings page, through `settings:register`: `mishka_cms_migration.installed`, the version a
  site was set up at, which the installer writes after an install, and
  `mishka_cms_migration.active`, the switch that hides the extension from a site
  (`MishkaCmsCore.Install.Extensions.settings/2`).
  """

  use MishkaInstaller.Event.Hook, event: "settings:register", initial: %{priority: 50}

  alias MishkaCmsCore.Install.Extensions

  @impl true
  def call(%{definitions: definitions} = data),
    do:
      {:reply,
       %{
         data
         | definitions: definitions ++ Extensions.settings(:mishka_cms_migration, "migration")
       }}

  def call(data), do: {:reply, data}
end
