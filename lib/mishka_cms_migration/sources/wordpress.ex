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

  `kinds/0` is `["user", "category", "tag", "media", "setting", "page", "post", "comment",
  "post_redirect"]`: authors, terms and files before the site's settings, pages and posts that point
  at them, the comments after the posts they are on, and each post's old address after its post.
  `"setting"` is read from the REST index `connect/2` already read, with no request of its own: the
  site's name, tagline (`description`), logo (`site_logo`) and icon (`site_icon`), each one a row
  when the site has it. `list/3` reads each other kind from its REST route (`/wp/v2/users`,
  `/wp/v2/categories`, `/wp/v2/tags`, `/wp/v2/media`, `/wp/v2/pages`, `/wp/v2/posts`,
  `/wp/v2/comments`) as the signed-in user, with `context=edit`, so WordPress answers the raw fields
  an editor sees, 100 rows a page. Pages and posts are asked for with
  `status=any`: published, scheduled, draft, pending and private, but not the trash. Comments are
  asked for with `status=all` and `type=all`: approved and held for moderation, of every type
  (WordPress answers only plain comments unless asked), but not spam and not the trash.
  `"post_redirect"` reads the posts again, only their `id`, `title`, `status`, `link` and
  `modified_gmt` (`_fields`). The cursor is the next page number while `X-WP-TotalPages` says there
  is one, and `nil` after the last. A list WordPress refuses fails the walk:
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
      category, a file, an attachment page or a post the site no longer has is left out, and so is
      every link when the connection is not at hand. Its `pages` are the links of its content that
      are left, to a page of the site, each `href` as written to the page's `link`: `/?page_id=<id>`
      is asked for by its id and any other by the last segment of its path, the same way, from
      `/wp/v2/pages`, and it is the page whose `link` has its path, or whose id it names. Its
      `media` are the addresses of
      its converted content (`src`, `href` and a video's `poster`) that are a file of the site's
      media library, each
      as written to the id of the file it is: the original or one of the sizes WordPress made of it
      (`hero-300x169.jpg` is the file `hero.jpg`). The files are asked for from `/wp/v2/media`,
      with only `id`, `source_url` and `media_details`, by the ids of its `wp-image-<id>` images
      (`include`) and by slugs made of the file names, without a size (`slug`), and an address is
      a file's when its path is the path of the file or of one of its sizes. A file whose slug is
      not its name and that no `wp-image-<id>` names is left out, and so is every address when the
      connection is not at hand. Its `seo` is what Yoast SEO or Rank Math kept for it, each key only
      when it has one: `"title"`, `"description"`, `"robots"` (of `noindex`, `nofollow`,
      `noarchive`, `nosnippet` and `noimageindex`, joined by `", "`), `"image"`, the share image's
      address, with `"image_id"`, the file of the media library it is, found with the content's
      files in the same request, and `"canonical"`, only when it is on another host than the
      source's (every entry's own address is its canonical by default). Each is read from Rank
      Math's `rank_math_*` fields in `meta`, then Yoast's `_yoast_wpseo_*`, then the head Yoast
      answers (`yoast_head_json`), which is what the site served. An export carries every one of
      these fields; the REST API answers only a post's Yoast title and description among them, and
      none of Rank Math's, so the rest is read from Yoast's head: its title only when it is not the
      entry's own title, alone or followed by the site's name (Yoast's default, which the CMS's
      layout draws itself), and its robots only when they say `noindex` or `nofollow`. A variable
      in a title or description is the CMS's own where it has one (`%%title%%` and `%title%` as
      `{{page.title}}`, `sitename` as `{{site.name}}`, `excerpt` as `{{page.description}}`, `sep`
      as `-` and `page` as nothing), and a value with any other variable is left out.
    * media — `title` is `title.raw` and `modified_at` is `modified_gmt` as UTC; `attrs` keeps
      `slug`, `source_url` (where the file is), `filename` (the last segment of its path),
      `mime_type`, `media_type`, `filesize` (the file's bytes, `media_details.filesize` on a
      WordPress that answers none of its own), `alt_text`, `caption` and `description` (their raw
      text), `post` (the post it was uploaded to, `0` for none) and `date_gmt`.
    * category and tag — `title` is `name`; `attrs` keeps `slug`, `description`, `count`, `link`,
      and `parent` for a category. A term has no `modified_at`.
    * user — `title` is `name`; `attrs` keeps `username`, `email`, `slug`, `name`, `first_name`,
      `last_name`, `nickname`, `description`, `roles`, `url`, `link` and `avatar_urls`. A user has
      no `modified_at`.
    * comment — `title` is the author's name, `parent` the id of the comment it replies to (`nil`
      at the top), and `content` the comment as its author typed it (`content.raw`); `attrs` keeps
      `post` (the id of the post or page it is on), `post_type` (that entry's type, `"post"` or
      `"page"`, from the row's `up` link), `author` (the id of the WordPress user, `0` for a
      visitor), `author_name`, `author_email`, `status` (`"approved"` or `"hold"`; a spam or
      trashed comment, which a list never answers, reads as it is), `type` (`"comment"`,
      `"pingback"` or `"trackback"`) and `date_gmt`. A comment has no `modified_at`. Its
      address, website, user agent and the rest are kept in `extra`.
    * setting — one of the site's own: its `source_id` is `"title"`, `"tagline"`, `"logo"` or
      `"icon"`, `title` WordPress's name for it (`"Site Title"`, ...), and `attrs`'s `"value"` the
      text of the name and the tagline, its HTML entities decoded (WordPress keeps `&` as
      `&amp;`), and the media id of the logo and the icon.
    * post_redirect — the post's old address: its `source_id` is the post's id, `title` its title,
      and `attrs`'s `"from"` the path of its `link`, such as `/2025/12/hello/`, for a published post
      with an address of its own; `nil` for any other, such as a draft, whose `link` is
      `/?p=39`, an address no redirect can answer.

  Each of these reads goes through the connection's `read`, a function of a REST route and its
  query answering the rows by id: `connect/2` answers one that asks the site, and the export file
  source (`MishkaCmsMigration.Sources.WordPressFile`) one that answers from the file, which hands
  `normalize/3` rows of the same shape, so both make the same items.

  `extra` is every other field of the row: `meta` (Yoast's `_yoast_wpseo_*` fields and every other
  registered meta), `guid`, `password`, `comment_status`, `class_list`, a user's `capabilities`
  and `registered_date`, a term's `taxonomy`, a file's `media_details` (its sizes among them), and
  what a plugin adds. It leaves out what WordPress works out afresh for each answer rather than
  keeps: `_links`, the `rendered` halves of the fields above, and Yoast's `yoast_head` and
  `yoast_head_json`; and the local `modified`, which `modified_at` already says. Yoast's head
  carries the modified time too, so keeping either would make an item that was only saved again
  look changed to `MishkaCmsMigration.Source.Item.hash/1`. A row without the fields its kind needs,
  such as one read with `_fields`, is refused as `:unreadable`.

  Files are written to the CMS's media library (`MishkaCmsMigration.Targets.CmsMedia`), the site's
  name and pictures to its settings (`MishkaCmsMigration.Targets.CmsSetting`), pages as the CMS's
  own pages (`MishkaCmsMigration.Targets.CmsPage`), and users,
  categories, tags and posts into Mishka Blog where it runs: users as bloggers of the site's
  users, matched by email (`MishkaCmsMigration.Targets.BlogBlogger`), and
  `MishkaCmsMigration.Targets.BlogCollection`, `MishkaCmsMigration.Targets.BlogTag`,
  `MishkaCmsMigration.Targets.BlogPost`, their comments
  (`MishkaCmsMigration.Targets.BlogComment`), and each post's old address as a 301 to the post
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
  alias MishkaCmsMigration.Source
  alias MishkaCmsMigration.Sources.WordPress.{Content, Export}

  @kinds [
    "user",
    "category",
    "tag",
    "media",
    "setting",
    "page",
    "post",
    "comment",
    "post_redirect"
  ]

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
    "media" => {"/wp/v2/media", []},
    "page" => {"/wp/v2/pages", [status: "any"]},
    "post" => {"/wp/v2/posts", [status: "any"]},
    "comment" => {"/wp/v2/comments", [status: "all", type: "all"]},
    "post_redirect" =>
      {"/wp/v2/posts", [status: "any", _fields: "id,title,status,link,modified_gmt"]}
  }

  @per_page 100

  @linked_fields [status: "any", _fields: "id,slug,link"]
  @media_fields [_fields: "id,source_url,media_details"]
  @addressed ["src", "href", "poster"]
  @sized ~r/(?:-(?:\d+x\d+|scaled))+$/

  @rendered ~w(_links yoast_head yoast_head_json)

  @entries ["page", "post"]
  @entry_attrs ~w(slug status link parent author categories tags featured_media date_gmt
                  menu_order sticky format template)
  @entry_read ~w(id title content excerpt modified modified_gmt) ++ @entry_attrs ++ @rendered

  @media_attrs ~w(slug source_url mime_type media_type alt_text post date_gmt)
  @media_read ~w(id title caption description filesize modified modified_gmt) ++
                @media_attrs ++ @rendered

  @term_attrs ~w(slug description parent count link)
  @user_attrs ~w(username email slug name first_name last_name nickname description roles url
                 link avatar_urls)
  @named %{"category" => @term_attrs, "tag" => @term_attrs, "user" => @user_attrs}

  @settings [
    {"title", "name", "Site Title"},
    {"tagline", "description", "Tagline"},
    {"logo", "site_logo", "Site Logo"},
    {"icon", "site_icon", "Site Icon"}
  ]
  @texts ["title", "tagline"]

  @seo_titles ["rank_math_title", "_yoast_wpseo_title"]
  @seo_descriptions ["rank_math_description", "_yoast_wpseo_metadesc"]
  @seo_images ["rank_math_facebook_image", "_yoast_wpseo_opengraph-image"]
  @seo_canonicals ["rank_math_canonical_url", "_yoast_wpseo_canonical"]
  @seo_robots ~w(noindex nofollow noarchive nosnippet noimageindex)
  @seo_variable ~r/%%(\w+)%%|%(\w+)%/
  @seo_unknown ~r/%%?[a-z_][^%]*%/i
  @seo_variables %{
    "title" => "{{page.title}}",
    "sitename" => "{{site.name}}",
    "sep" => "-",
    "page" => "",
    "excerpt" => "{{page.description}}"
  }

  @comment_attrs ~w(post author author_name author_email status type date_gmt)
  @comment_read ~w(id content) ++ @comment_attrs ++ @rendered

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
      {:ok, %{req: req, index: index, user: user, read: &read(req, &1, &2)}}
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

  def list(%{index: index}, "setting", _cursor),
    do:
      {:ok,
       for(
         {id, field, label} <- @settings,
         value = setting(id, index[field]),
         do: %{"id" => id, "label" => label, "value" => value}
       ), nil}

  def list(_conn, kind, _cursor), do: {:error, {:unknown_kind, kind}}

  @impl MishkaCmsMigration.Source
  def normalize(
        %{"id" => id, "title" => %{"raw" => title}, "content" => %{"raw" => html}} = row,
        kind,
        context
      )
      when kind in @entries do
    content = Content.call(html, fetch(context))
    {media, seo} = media(html, content, seo(row, context), context)

    {:ok,
     %{
       source_id: id,
       title: title,
       parent: parent(row),
       modified_at: Map.get(row, "modified_gmt"),
       attrs:
         row
         |> entry_attrs()
         |> decoded_slug()
         |> Map.merge(%{"seo" => seo, "media" => media})
         |> Map.merge(links(html, context)),
       extra: Map.drop(row, @entry_read),
       content: content
     }}
  end

  def normalize(
        %{"id" => id, "title" => %{"raw" => title}, "source_url" => url} = row,
        "media",
        _context
      )
      when is_binary(url) do
    {:ok,
     %{
       source_id: id,
       title: title,
       modified_at: Map.get(row, "modified_gmt"),
       attrs:
         row
         |> Map.take(@media_attrs)
         |> decoded_slug()
         |> Map.merge(%{
           "filename" => url |> URI.parse() |> file_name(),
           "filesize" => filesize(row),
           "caption" => raw(row["caption"]),
           "description" => raw(row["description"])
         }),
       extra: Map.drop(row, @media_read)
     }}
  end

  def normalize(%{"id" => id, "content" => %{"raw" => raw}} = row, "comment", _context)
      when is_binary(raw) do
    {:ok,
     %{
       source_id: id,
       title: row["author_name"],
       parent: parent(row),
       attrs: row |> Map.take(@comment_attrs) |> Map.put("post_type", post_type(row)),
       extra: Map.drop(row, @comment_read),
       content: [%{html: raw}]
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

  def normalize(%{"id" => id, "label" => label, "value" => value}, "setting", _context),
    do: {:ok, %{source_id: id, title: label, attrs: %{"value" => value}}}

  def normalize(_row, kind, _context) when kind in @kinds, do: {:error, :unreadable}
  def normalize(_row, kind, _context), do: {:error, {:unknown_kind, kind}}

  defp setting(id, value) when id in @texts and is_binary(value),
    do: value |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim() |> filled()

  defp setting(_file, id) when is_integer(id) and id > 0, do: id
  defp setting(_id, _none), do: nil

  defp filled(""), do: nil
  defp filled(text), do: text

  defp fetch(%{conn: %{read: read}}), do: &read.(&1, include: Enum.join(&2, ","))
  defp fetch(_context), do: fn _route, _ids -> %{} end

  defp read(req, route, params),
    do:
      req
      |> Req.get(url: route, params: [context: "edit", per_page: @per_page] ++ params)
      |> by_id()

  defp links(html, %{conn: %{read: read, index: %{"home" => home}}}) when is_binary(home) do
    asked =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("a[href]")
      |> LazyHTML.attribute("href")
      |> Enum.uniq()
      |> Enum.flat_map(&asked(&1, URI.parse(home)))

    posts = linked(read, "/wp/v2/posts", asked)
    pages = linked(read, "/wp/v2/pages", Enum.reject(asked, &is_map_key(posts, elem(&1, 0))))

    %{
      "links" =>
        for({href, %{"slug" => slug}} <- posts, slug != "", into: %{}, do: {href, decoded(slug)}),
      "pages" =>
        for({href, %{"link" => link}} <- pages, is_binary(link), into: %{}, do: {href, link})
    }
  end

  defp links(_html, _context), do: %{"links" => %{}, "pages" => %{}}

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

  defp query_id(query) when is_binary(query) do
    params = URI.decode_query(query)
    Integer.parse(params["p"] || params["page_id"] || "")
  end

  defp query_id(_no_query), do: :error

  defp by_id_or_path({id, ""}, _href) when id > 0, do: {:include, id}
  defp by_id_or_path(_no_id, href), do: href |> Redirects.normalize_path() |> by_path()

  defp by_path({:ok, "/" <> rest = path}) when rest != "", do: {:slug, path}
  defp by_path(_root_or_not_a_path), do: nil

  defp linked(read, route, asked) do
    rows =
      Enum.flat_map([:include, :slug], fn by ->
        asked_rows(
          read,
          {route, @linked_fields},
          {by, for({_href, {^by, value}} <- asked, do: asked_value(by, value))}
        )
      end)

    for {href, reference} <- asked,
        row = Enum.find(rows, &links_to?(&1, reference)),
        into: %{},
        do: {href, row}
  end

  defp asked_rows(_read, _route, {_by, []}), do: []

  defp asked_rows(read, {route, fields}, {by, values}),
    do: route |> read.([{by, values |> Enum.uniq() |> Enum.join(",")} | fields]) |> Map.values()

  defp media(html, content, seo, %{conn: %{read: read, index: %{"home" => home}}})
       when is_binary(home) do
    home = URI.parse(home)
    files = content |> addresses() |> Enum.filter(&file?(&1, home))
    image = seo |> Map.get("image") |> List.wrap() |> Enum.filter(&file?(&1, home))

    rows =
      Enum.flat_map(
        [
          include: image_ids(html),
          slug: files |> Enum.concat(image) |> Enum.flat_map(&file_slugs/1)
        ],
        &asked_rows(read, {"/wp/v2/media", @media_fields}, &1)
      )

    {for(href <- files, id = file_of(rows, href), into: %{}, do: {href, id}),
     image_id(seo, Enum.find_value(image, &file_of(rows, &1)))}
  end

  defp media(_html, _content, seo, _context), do: {%{}, seo}

  defp image_id(seo, nil), do: seo
  defp image_id(seo, id), do: Map.put(seo, "image_id", id)

  defp seo(row, context) do
    meta = with_map(row["meta"])
    head = with_map(row["yoast_head_json"])

    %{
      "title" => typed(meta, @seo_titles) || served_title(head, row),
      "description" => typed(meta, @seo_descriptions) || said(head["description"]),
      "robots" => robots(meta) || served_robots(head["robots"]),
      "image" => said(meta, @seo_images) || served_image(head["og_image"]),
      "canonical" =>
        (said(meta, @seo_canonicals) || said(head["canonical"])) |> elsewhere(context)
    }
    |> Map.reject(fn {_field, value} -> is_nil(value) end)
  end

  defp with_map(%{} = map), do: map
  defp with_map(_none), do: %{}

  defp typed(meta, keys), do: meta |> said(keys) |> variables()

  defp said(meta, keys), do: Enum.find_value(keys, &said(meta[&1]))

  defp said(text) when is_binary(text), do: text |> String.trim() |> filled()
  defp said(_none), do: nil

  defp variables(nil), do: nil

  defp variables(text),
    do:
      @seo_variable
      |> Regex.replace(text, fn whole, yoast, rank_math ->
        Map.get(@seo_variables, yoast <> rank_math, whole)
      end)
      |> String.split()
      |> Enum.join(" ")
      |> resolved()

  defp resolved(text), do: resolved(Regex.match?(@seo_unknown, text), text)
  defp resolved(true, _text), do: nil
  defp resolved(false, text), do: filled(text)

  defp served_title(%{"title" => title, "og_site_name" => site}, %{"title" => %{"raw" => own}})
       when is_binary(title) and is_binary(site) and is_binary(own),
       do: title |> said() |> own_title(own, site)

  defp served_title(head, _row), do: said(head["title"])

  defp own_title(nil, _own, _site), do: nil
  defp own_title(own, own, _site), do: nil

  defp own_title(title, own, site),
    do:
      own_title(
        title,
        Regex.match?(
          ~r/\A#{Regex.escape(own)} [^\p{L}\p{N}\s]{1,3} #{Regex.escape(site)}\z/u,
          title
        )
      )

  defp own_title(_title, true), do: nil
  defp own_title(title, false), do: title

  defp robots(meta) do
    [
      meta["rank_math_robots"] |> php_list() |> List.wrap(),
      [yoast_robot(meta["_yoast_wpseo_meta-robots-noindex"], "noindex")],
      [yoast_robot(meta["_yoast_wpseo_meta-robots-nofollow"], "nofollow")],
      String.split(meta["_yoast_wpseo_meta-robots-adv"] || "", ",", trim: true)
    ]
    |> List.flatten()
    |> robots_value()
  end

  defp php_list(value) when is_binary(value), do: Export.php(value)
  defp php_list(value), do: value

  defp yoast_robot("1", robot), do: robot
  defp yoast_robot(_default, _robot), do: nil

  defp served_robots(%{} = robots),
    do: robots_value([robots["index"], robots["follow"]])

  defp served_robots(_none), do: nil

  defp robots_value(robots),
    do:
      for(
        robot when is_binary(robot) <- robots,
        robot = String.trim(robot),
        robot in @seo_robots,
        uniq: true,
        do: robot
      )
      |> joined_robots()

  defp joined_robots([]), do: nil
  defp joined_robots(robots), do: Enum.join(robots, ", ")

  defp served_image([%{"url" => url} | _]), do: said(url)
  defp served_image(_none), do: nil

  defp elsewhere(nil, _context), do: nil

  defp elsewhere(url, %{source_host: host}),
    do: url |> URI.parse() |> elsewhere(url, Source.url_host(%{"url" => url}) != host)

  defp elsewhere(%URI{scheme: scheme, host: host}, url, true)
       when scheme in ["http", "https"] and is_binary(host),
       do: url

  defp elsewhere(_uri, _url, _on_source), do: nil

  defp addresses(content) do
    tree =
      LazyHTML.from_fragment(
        for %{html: html} when is_binary(html) <- content, into: "", do: html
      )

    for attribute <- @addressed,
        address <- tree |> LazyHTML.query("[#{attribute}]") |> LazyHTML.attribute(attribute),
        uniq: true,
        do: address
  end

  defp file?(href, home), do: href |> String.trim() |> URI.parse() |> file_on?(home)

  defp file_on?(%URI{path: "/" <> _ = path} = uri, home),
    do: on_site?(uri, home) and Path.extname(path) != ""

  defp file_on?(_uri, _home), do: false

  defp image_ids(html),
    do:
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("img[class]")
      |> LazyHTML.attribute("class")
      |> Enum.flat_map(&String.split/1)
      |> Enum.flat_map(&image_id/1)

  defp image_id("wp-image-" <> id), do: id |> Integer.parse() |> whole_id()
  defp image_id(_class), do: []

  defp whole_id({id, ""}) when id > 0, do: [id]
  defp whole_id(_not_an_id), do: []

  defp file_slugs(href) do
    name =
      href |> String.trim() |> URI.parse() |> file_name() |> Path.rootname() |> String.downcase()

    Enum.uniq([name, String.replace(name, @sized, "")])
  end

  defp file_of(rows, href) do
    path = href |> String.trim() |> URI.parse() |> Map.get(:path)
    Enum.find_value(rows, &(path in file_paths(&1) and &1["id"]))
  end

  defp file_paths(row),
    do:
      for(
        url <- [row["source_url"] | Enum.map(sizes(row), & &1["source_url"])],
        is_binary(url),
        do: URI.parse(url).path
      )

  defp sizes(%{"media_details" => %{"sizes" => %{} = sizes}}), do: Map.values(sizes)
  defp sizes(_row), do: []

  defp file_name(%URI{path: path}) when is_binary(path), do: Path.basename(path)
  defp file_name(_uri), do: ""

  defp filesize(%{"filesize" => size}) when is_integer(size), do: size
  defp filesize(%{"media_details" => %{"filesize" => size}}) when is_integer(size), do: size
  defp filesize(_row), do: nil

  defp raw(%{"raw" => raw}) when is_binary(raw), do: raw
  defp raw(_none), do: nil

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

  defp post_type(%{"_links" => %{"up" => [%{"post_type" => type} | _]}}), do: type
  defp post_type(_row), do: nil

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
