# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Test.WordPress do
  @moduledoc """
  Has `MishkaCmsMigration.Sources.WordPress` answered by what the seeded WordPress really answered
  (`test/fixtures/wordpress/rest`, recorded by `dev/wordpress/record.sh`), through `Req.Test`.

  `stub!/1` answers each request by its path, without the site's own folder: the REST index
  (`"/wp-json/"`) and the signed-in user (`"/wp-json/wp/v2/users/me"`) by default, from their
  recordings. A test overrides a path with another recording's name, with `:no_site` (an HTML
  404, what a site with no REST API answers) or with `:unreachable` (the connection is refused).
  Any other path is a `:no_site` answer.

      stub!(%{"/wp-json/wp/v2/users/me" => "unauthorized-users-me-wrong-password"})

  Every request it answers is sent to the test process as `{:wordpress_request, conn}`.
  """

  import Plug.Conn

  @source MishkaCmsMigration.Sources.WordPress
  @fixtures Path.expand("../fixtures/wordpress/rest", __DIR__)
  @site %{"/wp-json/" => "index", "/wp-json/wp/v2/users/me" => "users-me"}

  @statuses @fixtures
            |> Path.join("INDEX.txt")
            |> File.read!()
            |> String.split("\n", trim: true)
            |> Enum.drop(1)
            |> Map.new(fn line ->
              [file, _method, _request, status] = String.split(line, "\t")
              {Path.rootname(file), String.to_integer(status)}
            end)

  @external_resource Path.join(@fixtures, "INDEX.txt")

  @doc "Stubs the WordPress source for the calling test, overriding `answers` by path."
  @spec stub!(map()) :: :ok
  def stub!(answers \\ %{}) do
    test = self()
    answers = Map.merge(@site, answers)

    Req.Test.stub(@source, fn conn ->
      send(test, {:wordpress_request, conn})
      answer(conn, Map.get(answers, path(conn), :no_site))
    end)
  end

  @doc "The answers the recorded site gives by default, by path."
  @spec site() :: map()
  def site, do: @site

  defp path(%Plug.Conn{request_path: request_path}) do
    request_path |> String.split("/wp-json", parts: 2) |> rest_path()
  end

  defp rest_path([_folder, rest]), do: "/wp-json" <> rest
  defp rest_path([other]), do: other

  defp answer(conn, :unreachable), do: Req.Test.transport_error(conn, :econnrefused)

  defp answer(conn, :no_site) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(404, "<!doctype html><title>Not Found</title>")
  end

  defp answer(conn, recording) when is_binary(recording) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      Map.fetch!(@statuses, recording),
      File.read!(Path.join(@fixtures, recording <> ".json"))
    )
  end
end
