# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Plugins.Installer do
  @moduledoc """
  Installs the migration on one site when an admin asks for it: a plugin on
  `installer:extension:install` (`MishkaCmsCore.Install.Extensions`), answering the payload whose
  `key` is `"mishka_cms_migration"` with `MishkaCmsMigration.Provision.install/2`'s report,
  appended to `reports`. Subscribing is what makes the extension installable; `:extra` is what the
  installer's picker shows. Every other payload is handed on untouched.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  use MishkaInstaller.Event.Hook,
    event: "installer:extension:install",
    initial: %{
      priority: 60,
      extra: [
        %{
          label: gettext_noop("Migration"),
          summary: gettext_noop("Move a site's content from WordPress and other CMSs"),
          fields: []
        }
      ]
    }

  alias MishkaCmsMigration.Provision

  @key "mishka_cms_migration"

  @impl true
  def call(%{key: @key, site_id: site_id, ask: :install, reports: reports} = payload)
      when is_binary(site_id),
      do:
        {:reply,
         %{payload | reports: reports ++ [Provision.install(site_id, Map.get(payload, :actor))]}}

  def call(payload), do: {:reply, payload}
end
