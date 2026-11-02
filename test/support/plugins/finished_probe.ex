# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Test.Plugins.FinishedProbe do
  @moduledoc """
  A plugin on `migration:import:finished` for the suite. It sends every payload it is handed, and
  its `meta`, as `{:import_finished, payload, meta}` to the process registered as
  `:__migration_probe__`, when there is one (`MishkaCmsMigration.Test.Plugins.Probe`).
  """

  use MishkaInstaller.Event.Hook, event: "migration:import:finished"

  alias MishkaCmsMigration.Test.Plugins.Probe

  @impl true
  def call(payload, meta) do
    Probe.call({:import_finished, payload, meta})
    {:reply, payload}
  end
end
