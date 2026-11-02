# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Sources.WordPress do
  @moduledoc """
  The WordPress source (`"wordpress"`): a site read over its REST API, signed in to with a user
  name and an application password (WordPress 5.6+, Users ▸ Profile ▸ Application Passwords).
  WordPress offers application passwords over HTTPS only, or on a site whose
  `WP_ENVIRONMENT_TYPE` is `local`.

  A run's `connection` names the site and the user; the application password is the run's secret:

      %{"url" => "https://example.com", "user" => "admin"}

  `connect/2` first reads the REST index (`/wp-json/`), which tells it a WordPress answers at the
  address, then signs in (`/wp-json/wp/v2/users/me?context=edit`). It refuses with one of the
  reasons `MishkaCmsMigration.Source` names:

    * `:invalid_address` — the address is not an `http` or `https` address with a host;
    * `:unreachable` — nothing answered at the address;
    * `:no_site` — something answered, but not a WordPress REST API: another kind of site, or a
      WordPress whose REST API a plugin turned off;
    * `:unauthorized` — WordPress did not sign the user in. It answers a wrong password, an
      unknown user and a request whose `Authorization` header the host dropped the same way
      (`rest_not_logged_in`), so these cannot be told apart.

  `extra/1` keeps the site's name, its home address and timezone, and who signed in.

  It reads no content yet: `kinds/0` is empty, so a dry run of it finds nothing. Posts, categories
  and tags come next (mishka_cms_migration#5), then authors (#6).

  Requests go through `Req`. `req_options` in the application environment are merged into every
  request, which is how the suite replays what a real WordPress answered
  (`test/fixtures/wordpress`):

      config :mishka_cms_migration, MishkaCmsMigration.Sources.WordPress,
        req_options: [plug: {Req.Test, MishkaCmsMigration.Sources.WordPress}]
  """

  use MishkaCmsMigration.Source, id: "wordpress", label: "WordPress"

  @impl MishkaCmsMigration.Source
  def kinds, do: []

  @impl MishkaCmsMigration.Source
  def connect(%{"url" => url, "user" => user}, secret)
      when is_binary(url) and is_binary(user) and is_binary(secret) do
    with {:ok, base} <- base_url(url),
         req = request(base, user, secret),
         {:ok, index} <- index(req),
         {:ok, signed_in} <- signed_in(req) do
      {:ok, %{req: req, index: index, user: signed_in}}
    end
  end

  def connect(%{"url" => url}, _secret) when is_binary(url), do: {:error, :unauthorized}
  def connect(_connection, _secret), do: {:error, :invalid_address}

  @impl MishkaCmsMigration.Source
  def extra(%{index: index, user: user}) do
    %{
      "name" => index["name"],
      "home" => index["home"],
      "timezone" => index["timezone_string"],
      "signed_in_as" => user["username"]
    }
  end

  @impl MishkaCmsMigration.Source
  def list(_conn, _kind, _cursor), do: {:ok, [], nil}

  @impl MishkaCmsMigration.Source
  def normalize(_row, kind, _context), do: {:error, {:unknown_kind, kind}}

  defp base_url(url) do
    url |> String.trim() |> URI.parse() |> base()
  end

  defp base(%URI{scheme: scheme, host: host} = uri)
       when scheme in ["http", "https"] and is_binary(host) and host != "",
       do:
         {:ok,
          URI.to_string(%{
            uri
            | path: String.trim_trailing(uri.path || "", "/"),
              query: nil,
              fragment: nil
          })}

  defp base(_uri), do: {:error, :invalid_address}

  defp request(base, user, secret) do
    [base_url: base <> "/wp-json", auth: {:basic, "#{user}:#{secret}"}, retry: false]
    |> Req.new()
    |> Req.merge(req_options())
  end

  defp index(req), do: req |> Req.get(url: "/") |> index_answer()

  defp index_answer({:ok, %Req.Response{status: 200, body: %{"namespaces" => namespaces} = body}})
       when is_list(namespaces),
       do: rest_api("wp/v2" in namespaces, body)

  defp index_answer({:ok, %Req.Response{}}), do: {:error, :no_site}
  defp index_answer({:error, _exception}), do: {:error, :unreachable}

  defp rest_api(true, index), do: {:ok, index}
  defp rest_api(false, _index), do: {:error, :no_site}

  defp signed_in(req),
    do: req |> Req.get(url: "/wp/v2/users/me", params: [context: "edit"]) |> user_answer()

  defp user_answer({:ok, %Req.Response{status: 200, body: %{"id" => _} = user}}), do: {:ok, user}

  defp user_answer({:ok, %Req.Response{status: status}}) when status in [401, 403],
    do: {:error, :unauthorized}

  defp user_answer({:ok, %Req.Response{}}), do: {:error, :no_site}
  defp user_answer({:error, _exception}), do: {:error, :unreachable}

  defp req_options,
    do:
      :mishka_cms_migration
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:req_options, [])
end
