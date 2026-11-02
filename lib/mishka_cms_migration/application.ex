# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Application do
  @moduledoc """
  The migration extension's OTP application. It supervises every mishka_installer plugin the
  extension ships (`plugins/0`). A plugin registers on the event it listens on once it is supervised
  here.

  The plugins are the sources (`sources/0`, each a plugin on `"migration:sources"`, see
  `MishkaCmsMigration.Source`) and the targets (`targets/0`, each on `"migration:targets"`, see
  `MishkaCmsMigration.Target`) it ships; the two that make it installable on a site,
  `MishkaCmsMigration.Provision` and `MishkaCmsMigration.Provision.Settings`; and the two that open
  the chains of the events deciding what is written, `MishkaCmsMigration.Events.BeforeImportGuard`
  and `MishkaCmsMigration.Events.ConvertGuard`.

  At boot it also attaches the Oban telemetry handler that fails the run of a migration job Oban
  discards (`MishkaCmsMigration.Workers.attach/0`).

  The migration jobs run on the host's Oban, on a `migration` queue the host declares; the host
  starts Oban through `AshOban.config/2` with its `ash_domains`, which refuses to start without the
  queue. Each site has one run dry running or importing at a time
  (`MishkaCmsMigration.MigrationRun`'s `:one_active_per_site`); the queue's limit is how many sites
  migrate at once across the whole installation. With
  `queues: [migration: 1]` one site migrates while the others' jobs wait their turn; a host with
  many sites may raise it, at the cost of that many imports writing at the same time.
  """

  use Application

  @sources []

  @targets []

  @provision_plugins [
    MishkaCmsMigration.Provision,
    MishkaCmsMigration.Provision.Settings
  ]

  @guard_plugins [
    MishkaCmsMigration.Events.BeforeImportGuard,
    MishkaCmsMigration.Events.ConvertGuard
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
  def plugins, do: sources() ++ targets() ++ @provision_plugins ++ @guard_plugins

  @impl true
  def start(_type, _args) do
    MishkaCmsMigration.Workers.attach()
    opts = [strategy: :one_for_one, name: MishkaCmsMigration.Supervisor]
    Supervisor.start_link(plugins(), opts)
  end
end
