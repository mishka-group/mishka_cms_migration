# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Test.Plugins.ContentConverter do
  @moduledoc """
  A plugin on `migration:content:convert` for the suite. It converts a piece named `"shout"` to
  `<strong>` around its `raw` text, upper-cased, and a WordPress `acme/callout` block to an
  `<aside>` holding its `"title"`, raises on a piece named `"explode"`, and leaves every other piece
  unconverted.

  Every payload it is handed, and its `meta`, is sent as `{:convert, payload, meta}` to the process
  registered as `:__migration_probe__`, when there is one (`MishkaCmsMigration.Test.Plugins.Probe`).
  """

  use MishkaInstaller.Event.Hook, event: "migration:content:convert"

  alias MishkaCmsMigration.Test.Plugins.Probe

  @impl true
  def call(payload, meta) do
    Probe.call({:convert, payload, meta})
    {:reply, convert(payload)}
  end

  defp convert(%{name: "shout", raw: raw} = payload),
    do: %{payload | html: "<strong>#{String.upcase(raw)}</strong>"}

  defp convert(%{name: "acme/callout", attrs: %{"title" => title}} = payload),
    do: %{payload | html: "<aside><strong>#{title}</strong></aside>"}

  defp convert(%{name: "explode"}), do: raise("the converter broke")
  defp convert(payload), do: payload
end
