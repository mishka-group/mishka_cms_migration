# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Secret do
  @moduledoc """
  Seals the secret a source signs in with (such as a WordPress application password) the way
  `MishkaCmsCore.Settings` seals a `:secret` setting: `Phoenix.Token.encrypt/4` with the endpoint's
  `secret_key_base`, under a salt of this extension's own. A run keeps only the sealed text
  (`MishkaCmsMigration.MigrationRun`'s `connection_secret`) from the moment it is created until it
  ends — done, failed or cancelled — when it is cleared; the walk opens it each time a job connects
  to the source (`MishkaCmsMigration.Walker`).

  A run with no secret hands the source `nil`. A secret that is stored but cannot be opened —
  `secret_key_base` was rotated since it was sealed — is an error, `:unreadable_secret`, which fails
  the run: the admin starts a new run with the secret typed again.
  """

  @salt "mishka migration source secret"

  @doc "`value` sealed; `nil` for a blank or missing secret."
  @spec seal(String.t() | nil) :: String.t() | nil
  def seal(value) when is_binary(value) and value != "",
    do: Phoenix.Token.encrypt(endpoint(), @salt, value)

  def seal(_blank), do: nil

  @doc """
  The secret `sealed` holds: `{:ok, secret}`, `{:ok, nil}` when none is stored, or
  `{:error, :unreadable_secret}` when it was sealed under another key.
  """
  @spec open(String.t() | nil) :: {:ok, String.t() | nil} | {:error, :unreadable_secret}
  def open(sealed) when is_binary(sealed) and sealed != "" do
    case Phoenix.Token.decrypt(endpoint(), @salt, sealed, max_age: :infinity) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _unreadable -> {:error, :unreadable_secret}
    end
  end

  def open(_none), do: {:ok, nil}

  defp endpoint, do: Application.fetch_env!(:mishka_cms_core, :endpoint)
end
