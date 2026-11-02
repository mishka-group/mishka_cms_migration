# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Secret do
  @moduledoc """
  Seals the secret a source signs in with (a WordPress application password) the way
  `MishkaCmsCore.Settings` seals a `:secret` setting: `Phoenix.Token.encrypt/4` with the endpoint's
  `secret_key_base`, under a salt of this extension's own. A run keeps only the sealed text
  (`MishkaCmsMigration.MigrationRun`'s `connection_secret`), and the pipeline opens it when it
  connects to the source.

  Rotating `secret_key_base` makes a sealed secret unreadable: `open/1` then answers `nil` and the
  source refuses to connect, so the admin starts a new run with the secret typed again.
  """

  @salt "mishka migration source secret"

  @doc "`value` sealed; `nil` for a blank or missing secret."
  @spec seal(String.t() | nil) :: String.t() | nil
  def seal(value) when is_binary(value) and value != "",
    do: Phoenix.Token.encrypt(endpoint(), @salt, value)

  def seal(_blank), do: nil

  @doc "The secret `sealed` holds; `nil` when there is none or it was sealed under another key."
  @spec open(String.t() | nil) :: String.t() | nil
  def open(sealed) when is_binary(sealed) and sealed != "" do
    case Phoenix.Token.decrypt(endpoint(), @salt, sealed, max_age: :infinity) do
      {:ok, value} when is_binary(value) -> value
      _unreadable -> nil
    end
  end

  def open(_none), do: nil

  defp endpoint, do: Application.fetch_env!(:mishka_cms_core, :endpoint)
end
