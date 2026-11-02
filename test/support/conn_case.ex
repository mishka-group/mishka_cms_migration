# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.ConnCase do
  @moduledoc """
  Test case for the extension's admin page, pointed at this extension's own
  `MishkaCmsMigration.TestEndpoint`.

  The sandbox is the core's (`MishkaCmsCore.DataCase.setup_sandbox/1`), and so are the sites, users
  and permissions a request needs (`MishkaCmsCore.Test.Factory`); the migration's own runs and
  admins are `MishkaCmsMigration.Test.Factory`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint MishkaCmsMigration.TestEndpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import MishkaCmsCore.Test.Factory
      import MishkaCmsMigration.ConnCase
      import MishkaCmsMigration.Test.Factory
    end
  end

  setup tags do
    MishkaCmsCore.DataCase.setup_sandbox(tags)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "A conn to `host`, as a browser addressing that site sends it."
  @spec on_host(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def on_host(conn, host) do
    conn
    |> Map.put(:host, host)
    |> Map.update!(:req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])
  end

  @doc """
  A conn signed in as `user` through the session, the way the admin pages are reached: the token
  AshAuthentication issues, stored where `load_from_session` reads it.
  """
  @spec signed_in(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def signed_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user, %{}, tenant: user.site_id)
    user = Map.update!(user, :__metadata__, &Map.put(&1, :token, token))

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
