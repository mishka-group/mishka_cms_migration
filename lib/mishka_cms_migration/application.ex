# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Application do
  @moduledoc """
  The migration extension's OTP application. It supervises every mishka_installer plugin the
  extension ships (`plugins/0`). A plugin registers on the event it listens on once it is supervised
  here.

  The plugins come in three groups: `sources/0` and `targets/0` — each source is a plugin on
  `"migration:sources"` (`MishkaCmsMigration.Source`) and each target on `"migration:targets"`
  (`MishkaCmsMigration.Target`) — and the two that make the extension installable on a site:
  `MishkaCmsMigration.Plugins.Installer`, which creates the migration's permission names
  (`MishkaCmsMigration.Provision`), and `MishkaCmsMigration.Plugins.InstallSettings`, which
  registers the settings the installer records an install in.

  The migration jobs run on the host's Oban, on a `migration` queue the host declares
  (`queues: [migration: 1]`).
  """

  use Application

  @sources []

  @targets []

  @provision_plugins [
    MishkaCmsMigration.Plugins.Installer,
    MishkaCmsMigration.Plugins.InstallSettings
  ]

  @doc """
  The sources this extension ships, each a plugin on `"migration:sources"`. None yet; WordPress is
  planned as the first.
  """
  @spec sources() :: [module()]
  def sources, do: @sources

  @doc """
  The targets this extension ships, each a plugin on `"migration:targets"` writing one kind of item
  through an existing CMS action. None yet.
  """
  @spec targets() :: [module()]
  def targets, do: @targets

  @doc """
  Every mishka_installer plugin this extension ships, all of which `start/2` supervises. A plugin
  left out of it never registers, so the event it listens on never reaches it.
  """
  @spec plugins() :: [module()]
  def plugins, do: sources() ++ targets() ++ @provision_plugins

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: MishkaCmsMigration.Supervisor]
    Supervisor.start_link(plugins(), opts)
  end
end
