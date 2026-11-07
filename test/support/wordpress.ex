# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Test.WordPress do
  @moduledoc """
  Has `MishkaCmsMigration.Sources.WordPress` answered by what the seeded WordPress really answered
  (`test/fixtures/wordpress/rest`, recorded by `dev/wordpress/record.sh`), through `Req.Test`.

  `stub!/1` answers each request by its path, without the site's own folder, and its `page`: by
  default the REST index (`"/wp-json/"`), the signed-in user (`"/wp-json/wp/v2/users/me"`), the
  first page of users, categories, tags, pages, posts, comments, menus, menu items and block menus, the
  site's settings (`/wp-json/wp/v2/settings`), and the
  reusable blocks and media the posts' content names (`site/0`), from their recordings, with the status and headers WordPress sent
  (`X-WP-TotalPages` among them). A path answers a request with no `page` or with page 1;
  `{path, page}` answers that page. A test overrides either with another recording's name, with
  `:no_site` (an HTML 404, what a site with no REST API answers), with `:unreachable` (the
  connection is refused) or with `{content_type, body}`, a `200` of its own. A file of the site's
  uploads (`/wp-content/uploads/…`) is answered from the seed's own files (`dev/wordpress/media`),
  by its name, with the content type of its extension. Any other request is a `:no_site` answer.
  The other query parameters, `per_page`, `include` and `slug` among them, do not choose the
  answer: the blocks and the media are answered whole, whichever ids or slugs a request names.

      stub!(%{"/wp-json/wp/v2/users/me" => "unauthorized-users-me-wrong-password"})
      stub!(%{{"/wp-json/wp/v2/posts", 2} => "posts-page-2"})
      stub!(%{"/wp-content/uploads/2026/11/hero.jpg" => {"image/jpeg", "<html></html>"}})

  Every request it answers is sent to the test process as `{:wordpress_request, conn}`, with its
  `query_params` fetched. `recorded/1` reads a recording's body, for a test that compares what the
  source made of it with what WordPress sent.
  """

  import Plug.Conn

  @source MishkaCmsMigration.Sources.WordPress
  @fixtures Path.expand("../fixtures/wordpress/rest", __DIR__)
  @uploads Path.expand("../../dev/wordpress/media", __DIR__)
  @site %{
    "/wp-json/" => "index",
    "/wp-json/wp/v2/users/me" => "users-me",
    "/wp-json/wp/v2/users" => "users",
    "/wp-json/wp/v2/categories" => "categories",
    "/wp-json/wp/v2/tags" => "tags",
    "/wp-json/wp/v2/pages" => "pages",
    "/wp-json/wp/v2/posts" => "posts",
    "/wp-json/wp/v2/comments" => "comments",
    "/wp-json/wp/v2/blocks" => "blocks",
    "/wp-json/wp/v2/media" => "media",
    "/wp-json/wp/v2/menus" => "menus",
    "/wp-json/wp/v2/menu-items" => "menu-items",
    "/wp-json/wp/v2/navigation" => "navigation",
    "/wp-json/wp/v2/settings" => "settings"
  }

  @transport ["content-length", "transfer-encoding", "connection"]

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

  @doc "Stubs the WordPress source for the calling test, overriding `answers` by path or page."
  @spec stub!(map()) :: :ok
  def stub!(answers \\ %{}) do
    test = self()
    answers = Map.merge(@site, answers)

    Req.Test.stub(@source, fn conn ->
      conn = fetch_query_params(conn)
      send(test, {:wordpress_request, conn})
      answer(conn, found(answers, path(conn), page(conn.query_params)))
    end)
  end

  @doc "The answers the recorded site gives by default, by path."
  @spec site() :: map()
  def site, do: @site

  @doc "The body of `recording`, decoded: the rows of a list, as WordPress sent them."
  @spec recorded(String.t()) :: term()
  def recorded(recording),
    do: @fixtures |> Path.join(recording <> ".json") |> File.read!() |> Jason.decode!()

  defp found(answers, path, page),
    do: Map.get_lazy(answers, {path, page}, fn -> first_page(answers, path, page) end)

  defp first_page(answers, path, 1), do: Map.get_lazy(answers, path, fn -> uploaded(path) end)
  defp first_page(_answers, _path, _page), do: :no_site

  defp uploaded("/wp-content/uploads/" <> _ = path) do
    file = Path.join(@uploads, Path.basename(path))
    served(File.regular?(file), file)
  end

  defp uploaded(_path), do: :no_site

  defp served(true, file), do: {MIME.from_path(file), File.read!(file)}
  defp served(false, _file), do: :no_site

  defp page(%{"page" => page}), do: String.to_integer(page)
  defp page(_params), do: 1

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

  defp answer(conn, {type, body}) when is_binary(type) and is_binary(body) do
    conn
    |> put_resp_content_type(type, nil)
    |> send_resp(200, body)
  end

  defp answer(conn, recording) when is_binary(recording) do
    conn
    |> merge_resp_headers(headers(recording))
    |> send_resp(
      Map.fetch!(@statuses, recording),
      File.read!(Path.join(@fixtures, recording <> ".json"))
    )
  end

  defp headers(recording) do
    @fixtures
    |> Path.join(recording <> ".headers.txt")
    |> File.read!()
    |> String.split("\r\n", trim: true)
    |> Enum.drop(1)
    |> Enum.map(&header/1)
    |> Enum.reject(fn {name, _value} -> name in @transport end)
  end

  defp header(line) do
    [name, value] = String.split(line, ":", parts: 2)
    {String.downcase(name), String.trim(value)}
  end
end
