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

  The New import form asks for them (`form_fields/0`): the Address (`"url"`), the User (`"user"`)
  and the Application password (`:secret`, masked, which the run keeps only sealed), each required.

  `connect/2` first reads the REST index (`/wp-json/`), which tells it a WordPress answers at the
  address, then signs in (`/wp-json/wp/v2/users/me?context=edit`). It checks in that order, so the
  reason it gives is the first thing that is wrong. It refuses with one of the reasons
  `MishkaCmsMigration.Source` names:

    * `:invalid_address` — the address is not an `http` or `https` address with a host;
    * `:unreachable` — nothing answered at the address;
    * `:no_site` — something answered, but not a WordPress REST API: another kind of site, or a
      WordPress whose REST API a plugin turned off;
    * `:unauthorized` — no user or no password was given, or WordPress did not sign the user in.
      It answers a wrong password, an unknown user and a request whose `Authorization` header the
      host dropped the same way (`rest_not_logged_in`), so these cannot be told apart.

  `extra/1` keeps the site's name, its home address and timezone, and who signed in.

  ## What it reads

  `kinds/0` is `["user", "category", "tag", "page", "post", "post_redirect"]`: authors and terms
  before the pages and posts that point at them, and each post's old address after its post.
  `list/3` reads each from its REST route (`/wp/v2/users`, `/wp/v2/categories`, `/wp/v2/tags`,
  `/wp/v2/pages`, `/wp/v2/posts`) as the signed-in user, with `context=edit`, so WordPress answers
  the raw fields an editor sees, 100 rows a page. Pages and posts are asked for with `status=any`:
  published, scheduled, draft, pending and private, but not the trash. `"post_redirect"` reads the
  posts again, only their `id`, `title`, `status`, `link` and `modified_gmt` (`_fields`). The cursor is the next page number while `X-WP-TotalPages` says there is one, and
  `nil` after the last. A list WordPress refuses fails the walk:
    * `:unauthorized` — WordPress answered 401 or 403: the user may not read this kind in the edit
      context, or the password was revoked since the run was made;
    * `:unreachable` — nothing answered;
    * `:no_site` — something answered that is not the REST API;
    * `"WordPress answered <status>: <message>"` — any other error WordPress put in words, such as
      a page past the last.

  `normalize/3` makes each row an item (`MishkaCmsMigration.Source.Item`). Its `source_id` is the
  WordPress id, and its `parent` the id of a page's parent page or a category's parent category
  (`nil` at the top, where WordPress says `0`); keys are WordPress's own and are never atomized.
  WordPress keeps a slug written in another script percent-encoded (`%d9%88%d8%b1…` for
  `وردپرس`), so the item's `slug` is decoded; one that does not decode to text is kept as it is.

    * page and post — `title` is `title.raw`, `modified_at` is `modified_gmt` as UTC, and
      `content` is `content.raw` converted (`MishkaCmsMigration.Sources.WordPress.Content`): its
      blocks, classic paragraphs and core shortcodes as HTML, and a piece for each block or
      shortcode left to `migration:content:convert`. The reusable blocks and gallery images it names
      are read from `/wp/v2/blocks` and `/wp/v2/media` with the connection the walk hands
      `normalize/3` (its context's `conn`); without one, or when WordPress does not answer, they are
      pieces too. `attrs` keeps `slug`, `status`, `link`, `author`, `featured_media`, `date_gmt`,
      `template`, `excerpt` (its raw text), and `parent` and `menu_order` for a page, `categories`,
      `tags`, `sticky` and `format` for a post. Its `links` are the links of its content to a post
      of the site, each `href` as written to the post's decoded slug. A link on the site's own
      host, or a path alone, is asked for: `/?p=<id>` by its id (`include`), any other by the last
      segment of its path (`slug`), from `/wp/v2/posts` in any status with only `id`, `slug` and
      `link`, and it is the post whose `link` has its path, or whose id it names. A link to a
      page, a category, a file, an attachment page or a post the site no longer has is left out,
      and so is every link when the connection is not at hand.
    * category and tag — `title` is `name`; `attrs` keeps `slug`, `description`, `count`, `link`,
      and `parent` for a category. A term has no `modified_at`.
    * user — `title` is `name`; `attrs` keeps `username`, `email`, `slug`, `name`, `first_name`,
      `last_name`, `nickname`, `description`, `roles`, `url`, `link` and `avatar_urls`. A user has
      no `modified_at`.
    * post_redirect — the post's old address: its `source_id` is the post's id, `title` its title,
      and `attrs`'s `"from"` the path of its `link`, such as `/2025/12/hello/`, for a published post
      with an address of its own; `nil` for any other, such as a draft, whose `link` is
      `/?p=39`, an address no redirect can answer.

  `extra` is every other field of the row: `meta` (Yoast's `_yoast_wpseo_*` fields and every other
  registered meta), `guid`, `password`, `comment_status`, `class_list`, a user's `capabilities`
  and `registered_date`, a term's `taxonomy`, and what a plugin adds. It leaves out what WordPress
  works out afresh for each answer rather than keeps: `_links`, the `rendered` halves of the fields
  above, and Yoast's `yoast_head` and `yoast_head_json`; and the local `modified`, which
  `modified_at` already says. Yoast's head carries the modified time too, so keeping either would
  make an item that was only saved again look changed to `MishkaCmsMigration.Source.Item.hash/1`.
  A row without the fields its kind needs, such as one read with `_fields`, is refused as
  `:unreadable`.

  Pages are written as the CMS's own pages (`MishkaCmsMigration.Targets.CmsPage`), and users,
  categories, tags and posts into Mishka Blog where it runs: users as bloggers of the site's
  users, matched by email (`MishkaCmsMigration.Targets.BlogBlogger`), and
  `MishkaCmsMigration.Targets.BlogCollection`, `MishkaCmsMigration.Targets.BlogTag`,
  `MishkaCmsMigration.Targets.BlogPost`, and each post's old address as a 301 to the post
  (`MishkaCmsMigration.Targets.PostRedirect`).

  Requests go through `Req`. `req_options` in the application environment are merged into every
  request, which is how the suite replays what a real WordPress answered
  (`test/fixtures/wordpress`):

      config :mishka_cms_migration, MishkaCmsMigration.Sources.WordPress,
        req_options: [plug: {Req.Test, MishkaCmsMigration.Sources.WordPress}]
  """

  use MishkaCmsMigration.Source, id: "wordpress", label: "WordPress"
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.Redirects
  alias MishkaCmsMigration.Sources.WordPress.Content

  @kinds ["user", "category", "tag", "page", "post", "post_redirect"]

  @form_fields [
    [
      name: :url,
      type: :text,
      label: dgettext_noop("mishka_gervaz", "Address"),
      placeholder: "https://example.com",
      required: true
    ],
    [
      name: :user,
      type: :text,
      label: dgettext_noop("mishka_gervaz", "User"),
      placeholder: dgettext_noop("mishka_gervaz", "e.g. admin"),
      required: true
    ],
    [
      name: :secret,
      type: :password,
      label: dgettext_noop("mishka_gervaz", "Application password"),
      required: true
    ]
  ]

  @routes %{
    "user" => {"/wp/v2/users", []},
    "category" => {"/wp/v2/categories", []},
    "tag" => {"/wp/v2/tags", []},
    "page" => {"/wp/v2/pages", [status: "any"]},
    "post" => {"/wp/v2/posts", [status: "any"]},
    "post_redirect" =>
      {"/wp/v2/posts", [status: "any", _fields: "id,title,status,link,modified_gmt"]}
  }

  @per_page 100

  @linked_fields [status: "any", _fields: "id,slug,link"]

  @rendered ~w(_links yoast_head yoast_head_json)

  @entries ["page", "post"]
  @entry_attrs ~w(slug status link parent author categories tags featured_media date_gmt
                  menu_order sticky format template)
  @entry_read ~w(id title content excerpt modified modified_gmt) ++ @entry_attrs ++ @rendered

  @term_attrs ~w(slug description parent count link)
  @user_attrs ~w(username email slug name first_name last_name nickname description roles url
                 link avatar_urls)
  @named %{"category" => @term_attrs, "tag" => @term_attrs, "user" => @user_attrs}

  @impl MishkaCmsMigration.Source
  def kinds, do: @kinds

  @impl MishkaCmsMigration.Source
  def form_fields, do: @form_fields

  @impl MishkaCmsMigration.Source
  def connect(connection, secret) do
    with {:ok, base} <- connection |> Map.get("url") |> base_url(),
         req = request(base),
         {:ok, index} <- index(req),
         {:ok, req} <- signed(req, Map.get(connection, "user"), secret),
         {:ok, user} <- signed_in(req) do
      {:ok, %{req: req, index: index, user: user}}
    end
  end

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
  def list(%{req: req}, kind, cursor) when is_map_key(@routes, kind) do
    {route, params} = Map.fetch!(@routes, kind)
    page = cursor || 1

    req
    |> Req.get(url: route, params: [context: "edit", per_page: @per_page, page: page] ++ params)
    |> listed(page)
  end

  def list(_conn, kind, _cursor), do: {:error, {:unknown_kind, kind}}

  @impl MishkaCmsMigration.Source
  def normalize(
        %{"id" => id, "title" => %{"raw" => title}, "content" => %{"raw" => html}} = row,
        kind,
        context
      )
      when kind in @entries do
    {:ok,
     %{
       source_id: id,
       title: title,
       parent: parent(row),
       modified_at: Map.get(row, "modified_gmt"),
       attrs: row |> entry_attrs() |> decoded_slug() |> Map.put("links", links(html, context)),
       extra: Map.drop(row, @entry_read),
       content: Content.call(html, fetch(context))
     }}
  end

  def normalize(%{"id" => id, "title" => %{"raw" => title}} = row, "post_redirect", _context),
    do:
      {:ok,
       %{
         source_id: id,
         title: title,
         modified_at: Map.get(row, "modified_gmt"),
         attrs: %{"from" => old_path(row)}
       }}

  def normalize(%{"id" => id, "name" => name} = row, kind, _context)
      when is_map_key(@named, kind) do
    attrs = Map.fetch!(@named, kind)

    {:ok,
     %{
       source_id: id,
       title: name,
       parent: parent(row),
       attrs: row |> Map.take(attrs) |> decoded_slug(),
       extra: Map.drop(row, ["id", "name" | attrs] ++ @rendered)
     }}
  end

  def normalize(_row, kind, _context) when kind in @kinds, do: {:error, :unreadable}
  def normalize(_row, kind, _context), do: {:error, {:unknown_kind, kind}}

  defp fetch(%{conn: %{req: req}}), do: &fetched(req, &1, &2)
  defp fetch(_context), do: fn _route, _ids -> %{} end

  defp fetched(req, route, ids), do: read(req, route, include: Enum.join(ids, ","))

  defp read(req, route, params),
    do:
      req
      |> Req.get(url: route, params: [context: "edit", per_page: @per_page] ++ params)
      |> by_id()

  defp links(html, %{conn: %{req: req, index: %{"home" => home}}}) when is_binary(home) do
    asked =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("a[href]")
      |> LazyHTML.attribute("href")
      |> Enum.uniq()
      |> Enum.flat_map(&asked(&1, URI.parse(home)))

    posts = linked_posts(req, asked)

    for {href, reference} <- asked,
        %{"slug" => slug} when slug != "" <- [Enum.find(posts, &links_to?(&1, reference))],
        into: %{},
        do: {href, decoded(slug)}
  end

  defp links(_html, _context), do: %{}

  defp asked(href, home) do
    uri = href |> String.trim() |> URI.parse()

    with true <- on_site?(uri, home),
         {_by, _value} = reference <- reference(uri, href) do
      [{href, reference}]
    else
      _not_a_post -> []
    end
  end

  defp on_site?(%URI{scheme: scheme, host: nil, path: "/" <> _}, _home)
       when scheme in [nil, "http", "https"],
       do: true

  defp on_site?(%URI{scheme: scheme, host: host}, %URI{host: home})
       when scheme in [nil, "http", "https"] and is_binary(host) and is_binary(home),
       do: String.downcase(host) == String.downcase(home)

  defp on_site?(_uri, _home), do: false

  defp reference(%URI{query: query}, href), do: query |> query_id() |> by_id_or_path(href)

  defp query_id(query) when is_binary(query),
    do: query |> URI.decode_query() |> Map.get("p", "") |> Integer.parse()

  defp query_id(_no_query), do: :error

  defp by_id_or_path({id, ""}, _href) when id > 0, do: {:include, id}
  defp by_id_or_path(_no_id, href), do: href |> Redirects.normalize_path() |> by_path()

  defp by_path({:ok, "/" <> rest = path}) when rest != "", do: {:slug, path}
  defp by_path(_root_or_not_a_path), do: nil

  defp linked_posts(req, asked) do
    Enum.flat_map([:include, :slug], fn by ->
      asked_posts(req, by, for({_href, {^by, value}} <- asked, do: asked_value(by, value)))
    end)
  end

  defp asked_posts(_req, _by, []), do: []

  defp asked_posts(req, by, values),
    do:
      req
      |> read("/wp/v2/posts", [{by, values |> Enum.uniq() |> Enum.join(",")} | @linked_fields])
      |> Map.values()

  defp asked_value(:include, id), do: id
  defp asked_value(:slug, path), do: path |> String.split("/") |> List.last()

  defp links_to?(%{"id" => id}, {:include, id}), do: true

  defp links_to?(%{"link" => link}, {:slug, path}) when is_binary(link),
    do: Redirects.normalize_path(link) == {:ok, path}

  defp links_to?(_post, _reference), do: false

  defp by_id({:ok, %Req.Response{status: 200, body: rows}}) when is_list(rows),
    do: Map.new(rows, &{&1["id"], &1})

  defp by_id(_unanswered), do: %{}

  defp old_path(%{"status" => "publish", "link" => link}) when is_binary(link),
    do: link |> URI.parse() |> own_path()

  defp old_path(_not_public), do: nil

  defp own_path(%URI{path: "/" <> rest = path}) when rest != "", do: path
  defp own_path(_no_path), do: nil

  defp parent(%{"parent" => parent}) when is_integer(parent) and parent > 0, do: parent
  defp parent(_row), do: nil

  defp decoded_slug(%{"slug" => slug} = attrs) when is_binary(slug),
    do: %{attrs | "slug" => decoded(slug)}

  defp decoded_slug(attrs), do: attrs

  defp decoded(slug), do: slug |> URI.decode() |> text_or(slug)

  defp text_or(decoded, slug), do: text_or(String.valid?(decoded), decoded, slug)

  defp text_or(true, decoded, _slug), do: decoded
  defp text_or(false, _decoded, slug), do: slug

  defp entry_attrs(%{"excerpt" => %{"raw" => excerpt}} = row),
    do: row |> Map.take(@entry_attrs) |> Map.put("excerpt", excerpt)

  defp entry_attrs(row), do: Map.take(row, @entry_attrs)

  defp listed({:ok, %Req.Response{status: 200, body: rows} = response}, page) when is_list(rows),
    do: {:ok, rows, next_page(response, page)}

  defp listed({:ok, %Req.Response{status: status}}, _page) when status in [401, 403],
    do: {:error, :unauthorized}

  defp listed({:ok, %Req.Response{status: status, body: %{"message" => message}}}, _page)
       when is_binary(message),
       do: {:error, "WordPress answered #{status}: #{message}"}

  defp listed({:ok, %Req.Response{}}, _page), do: {:error, :no_site}
  defp listed({:error, _exception}, _page), do: {:error, :unreachable}

  defp next_page(response, page),
    do:
      response
      |> Req.Response.get_header("x-wp-totalpages")
      |> Enum.map(&Integer.parse/1)
      |> page_after(page)

  defp page_after([{total, ""} | _], page) when page < total, do: page + 1
  defp page_after(_total, _page), do: nil

  defp base_url(url) when is_binary(url), do: url |> String.trim() |> URI.parse() |> base()
  defp base_url(_url), do: {:error, :invalid_address}

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

  defp request(base) do
    [base_url: base <> "/wp-json", retry: false]
    |> Req.new()
    |> Req.merge(req_options())
  end

  defp signed(req, user, secret)
       when is_binary(user) and user != "" and is_binary(secret) and secret != "",
       do: {:ok, Req.merge(req, auth: {:basic, "#{user}:#{secret}"})}

  defp signed(_req, _user, _secret), do: {:error, :unauthorized}

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
