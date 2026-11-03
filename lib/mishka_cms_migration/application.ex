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
  `MishkaCmsMigration.Target`) it ships; the one that makes it installable on a site,
  `MishkaCmsMigration.Provision`; the two that open the chains of the events deciding what is
  written, `MishkaCmsMigration.Events.BeforeImportGuard` and
  `MishkaCmsMigration.Events.ConvertGuard`; and the admin page's sidebar entry,
  `MishkaCmsMigrationWeb.SidebarMenu`.

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

  @sources [MishkaCmsMigration.Sources.WordPress]

  @core_targets [MishkaCmsMigration.Targets.CmsMedia, MishkaCmsMigration.Targets.CmsPage]

  @blog_targets [
    MishkaCmsMigration.Targets.BlogBlogger,
    MishkaCmsMigration.Targets.BlogCollection,
    MishkaCmsMigration.Targets.BlogTag,
    MishkaCmsMigration.Targets.BlogPost,
    MishkaCmsMigration.Targets.PostRedirect
  ]

  @sidebar_menus [MishkaCmsMigrationWeb.SidebarMenu]

  @provision_plugins [MishkaCmsMigration.Provision]

  @guard_plugins [
    MishkaCmsMigration.Events.BeforeImportGuard,
    MishkaCmsMigration.Events.ConvertGuard
  ]

  @doc """
  The sources this extension ships, each a plugin on `"migration:sources"`: WordPress
  (`MishkaCmsMigration.Sources.WordPress`).
  """
  @spec sources() :: [module()]
  def sources, do: @sources

  @doc """
  The targets this extension ships, each a plugin on `"migration:targets"` writing one kind of item
  through an existing CMS action: files into the CMS's media library
  (`MishkaCmsMigration.Targets.CmsMedia`), pages into the CMS's pages
  (`MishkaCmsMigration.Targets.CmsPage`),
  authors, categories, tags and posts into Mishka Blog (`MishkaCmsMigration.Targets.BlogBlogger`,
  `MishkaCmsMigration.Targets.BlogCollection`, `MishkaCmsMigration.Targets.BlogTag`,
  `MishkaCmsMigration.Targets.BlogPost`), and each post's old address into a CMS redirect to it
  (`MishkaCmsMigration.Targets.PostRedirect`).

  Mishka Blog is an optional dependency, and each Blog target is defined only where it is loaded,
  so on a node without it they are left out and their kinds are skipped as `"no_target"`.
  """
  @spec targets() :: [module()]
  def targets, do: @core_targets ++ Enum.filter(@blog_targets, &Code.ensure_loaded?/1)

  @doc """
  Every mishka_installer plugin this extension ships, all of which `start/2` supervises. A plugin
  left out of it never registers, so the event it listens on never reaches it.
  """
  @spec plugins() :: [module()]
  def plugins,
    do: sources() ++ targets() ++ @provision_plugins ++ @guard_plugins ++ @sidebar_menus

  @impl true
  def start(_type, _args) do
    MishkaCmsMigration.Workers.attach()
    opts = [strategy: :one_for_one, name: MishkaCmsMigration.Supervisor]
    Supervisor.start_link(plugins(), opts)
  end
end
