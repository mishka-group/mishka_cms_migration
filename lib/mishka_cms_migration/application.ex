# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Application do
  @moduledoc """
  The migration extension's OTP application. It supervises every mishka_installer plugin the
  extension ships (`plugins/0`). A plugin registers on the event it listens on once it is supervised
  here.
  """

  use Application

  @doc """
  Every mishka_installer plugin this extension ships, all of which `start/2` supervises. A plugin
  left out of it never registers, so the event it listens on never reaches it.
  """
  @spec plugins() :: [module()]
  def plugins, do: []

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: MishkaCmsMigration.Supervisor]
    Supervisor.start_link(plugins(), opts)
  end
end
