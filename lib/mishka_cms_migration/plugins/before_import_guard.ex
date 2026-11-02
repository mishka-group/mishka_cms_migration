# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Plugins.BeforeImportGuard do
  @moduledoc """
  The first plugin on `migration:item:before_import`, at priority 1: it marks the payload
  `asked: true`, so an answer that comes back unmarked tells the import that a plugin of the event
  raised and the item is skipped rather than written (`MishkaCmsMigration.Events`).
  """

  use MishkaInstaller.Event.Hook,
    event: "migration:item:before_import",
    initial: %{priority: 1}

  @impl true
  def call(%{asked: false} = payload), do: {:reply, %{payload | asked: true}}
  def call(payload), do: {:reply, payload}
end
