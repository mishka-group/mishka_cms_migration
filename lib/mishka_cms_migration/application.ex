# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Application do
  @moduledoc """
  The migration extension's OTP application. It supervises every mishka_installer plugin the
  extension ships (`plugins/0`). A plugin registers on the event it listens on once it is supervised
  here.

  The plugins come in two groups, `sources/0` and `targets/0`: each source is a plugin on
  `"migration:sources"` (`MishkaCmsMigration.Source`) and each target on `"migration:targets"`
  (`MishkaCmsMigration.Target`). The jobs that use them run on the host's Oban, on a `migration`
  queue the host declares (`queues: [migration: 1]`).
  """

  use Application

  @sources []

  @targets []

  @doc """
  The sources this extension ships, each a plugin on `"migration:sources"`. WordPress is the first.
  """
  @spec sources() :: [module()]
  def sources, do: @sources

  @doc """
  The targets this extension ships, each a plugin on `"migration:targets"` writing one kind of item
  through an existing CMS action.
  """
  @spec targets() :: [module()]
  def targets, do: @targets

  @doc """
  Every mishka_installer plugin this extension ships, all of which `start/2` supervises. A plugin
  left out of it never registers, so the event it listens on never reaches it.
  """
  @spec plugins() :: [module()]
  def plugins, do: sources() ++ targets()

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: MishkaCmsMigration.Supervisor]
    Supervisor.start_link(plugins(), opts)
  end
end
