# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Test.Plugins.FinishedProbe do
  @moduledoc """
  A plugin on `migration:import:finished` for the suite. It sends every payload it is handed, and
  its `meta`, as `{:import_finished, payload, meta}` to the process registered as
  `:__migration_probe__`, when there is one.
  """

  use MishkaInstaller.Event.Hook, event: "migration:import:finished"

  @impl true
  def call(payload, meta) do
    if probe = Process.whereis(:__migration_probe__),
      do: send(probe, {:import_finished, payload, meta})

    {:reply, payload}
  end
end
