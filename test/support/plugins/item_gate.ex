# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Test.Plugins.ItemGate do
  @moduledoc """
  A plugin on `migration:item:before_import` for the suite. It decides by the item's `"gate"`
  attribute: `"skip"` leaves the item out with the reason `"held back"`, `"take"` takes it, and
  `"rename"` sends the redirect to `"/renamed"` and `"raise"` raises; any other item goes on as it
  is.

  Every payload it is handed, and its `meta`, is sent as `{:before_import, payload, meta}` to the
  process registered as `:__migration_probe__`, when there is one.
  """

  use MishkaInstaller.Event.Hook, event: "migration:item:before_import"

  @impl true
  def call(payload, meta) do
    if probe = Process.whereis(:__migration_probe__),
      do: send(probe, {:before_import, payload, meta})

    {:reply, decide(payload)}
  end

  defp decide(%{item: %{attrs: %{"gate" => "skip"}}} = payload),
    do: %{payload | decision: :skip, reason: "held back"}

  defp decide(%{item: %{attrs: %{"gate" => "take"}}} = payload), do: %{payload | decision: :take}
  defp decide(%{item: %{attrs: %{"gate" => "raise"}}}), do: raise("the gate broke")

  defp decide(%{item: %{attrs: %{"gate" => "rename"} = attrs} = item} = payload),
    do: %{payload | item: %{item | attrs: Map.put(attrs, "to", "/renamed")}}

  defp decide(payload), do: payload
end
