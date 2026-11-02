# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Test.Plugins.Probe do
  @moduledoc """
  Where the suite's plugins say what they were handed: the process registered as
  `:__migration_probe__`, when a test registered one.
  """

  @doc "Sends `message` to the probe, when there is one."
  @spec call(term()) :: :ok
  def call(message), do: :__migration_probe__ |> Process.whereis() |> told(message)

  defp told(nil, _message), do: :ok

  defp told(probe, message) do
    send(probe, message)
    :ok
  end
end
