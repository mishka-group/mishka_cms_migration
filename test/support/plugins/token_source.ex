# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Test.Plugins.TokenSource do
  @moduledoc """
  A source for the suite (`"token"`) that asks for other connection keys than WordPress does, so a
  test sees the New import form draw each source's own: an Address (`:url`), a Workspace
  (`:workspace`) and an API token (`:secret`, a password key), and no user.

  It connects only with the token `"t0ken"` to a connection with an address, says the workspace as
  its `extra/1`, and lists nothing.
  """

  use MishkaCmsMigration.Source, id: "token", label: "Token"
  use Gettext, backend: MishkaCmsCore.Gettext

  @impl MishkaCmsMigration.Source
  def form_fields,
    do: [
      [name: :url, label: dgettext_noop("mishka_gervaz", "Address"), required: true],
      [name: :workspace, label: dgettext_noop("mishka_gervaz", "Workspace")],
      [
        name: :secret,
        type: :password,
        label: dgettext_noop("mishka_gervaz", "API token"),
        required: true
      ]
    ]

  @impl MishkaCmsMigration.Source
  def kinds, do: ["note"]

  @impl MishkaCmsMigration.Source
  def connect(%{"url" => url} = connection, "t0ken") when is_binary(url), do: {:ok, connection}
  def connect(_connection, _secret), do: {:error, :unauthorized}

  @impl MishkaCmsMigration.Source
  def extra(connection), do: %{"name" => connection["workspace"]}

  @impl MishkaCmsMigration.Source
  def list(_conn, _kind, _cursor), do: {:ok, [], nil}

  @impl MishkaCmsMigration.Source
  def normalize(_row, _kind, _context), do: {:error, :unreadable}
end
