# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Test.Plugins.ItemGate do
  @moduledoc """
  A plugin on `migration:item:before_import` for the suite. It decides by the item's `"gate"`
  attribute: `"skip"` leaves the item out with the reason `"held back"`, `"take"` skips it with the
  reason `"taken by the gate"`, as a plugin that wrote the item itself does, `"rename"` sends the
  redirect to `"/renamed"`, `"raise"` raises, `"nope"` answers `:nope` instead of the payload, and
  `"cancel"` cancels the item's run as the admin importing it and lets the item go on; any other
  item goes on as it is.

  Every payload it is handed, and its `meta`, is sent as `{:before_import, payload, meta}` to the
  process registered as `:__migration_probe__`, when there is one
  (`MishkaCmsMigration.Test.Plugins.Probe`).
  """

  use MishkaInstaller.Event.Hook, event: "migration:item:before_import"

  alias MishkaCmsMigration.Test.Plugins.Probe

  @impl true
  def call(payload, meta) do
    Probe.call({:before_import, payload, meta})
    {:reply, decide(payload, meta)}
  end

  defp decide(%{item: %{attrs: %{"gate" => "skip"}}} = payload, _meta),
    do: %{payload | outcome: :skipped, reason: "held back"}

  defp decide(%{item: %{attrs: %{"gate" => "take"}}} = payload, _meta),
    do: %{payload | outcome: :skipped, reason: "taken by the gate"}

  defp decide(%{item: %{attrs: %{"gate" => "raise"}}}, _meta), do: raise("the gate broke")
  defp decide(%{item: %{attrs: %{"gate" => "nope"}}}, _meta), do: :nope

  defp decide(%{item: %{attrs: %{"gate" => "rename"} = attrs} = item} = payload, _meta),
    do: %{payload | item: %{item | attrs: Map.put(attrs, "to", "/renamed")}}

  defp decide(%{item: %{attrs: %{"gate" => "cancel"}}} = payload, meta) do
    payload.run_id
    |> MishkaCmsMigration.get_run!(actor: meta.actor, tenant: payload.site_id)
    |> MishkaCmsMigration.cancel_run!(actor: meta.actor, tenant: payload.site_id)

    payload
  end

  defp decide(payload, _meta), do: payload
end
