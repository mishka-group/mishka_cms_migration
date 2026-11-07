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

  `extra/1` keeps the site's name, its home address and timezone, who signed in, and the addresses
  it gives its posts and terms as `"permalinks"` (`MishkaCmsMigration.Sources.WordPress.Permalinks`),
  worked out from every published post's `link` (`/wp/v2/posts` with `status=publish` and only
  `id`, `status`, `slug`, `date`, `link` and `categories`, 100 a request), every category's `link`
  and parents (`/wp/v2/categories` with only `id`, `slug`, `parent` and `link`) and the first 100
  tags' `link` (`/wp/v2/tags`). When the user may read the site's settings (`/wp/v2/settings`,
  an administrator), it keeps what the site shows on its front as `"front_page"`:
  `"show_on_front"` (`"page"` or `"posts"`), and for `"page"` the ids of the front page
  (`"page_on_front"`) and the posts page (`"page_for_posts"`), each `nil` when none is set,
  such as `%{"show_on_front" => "page", "page_on_front" => "22", "page_for_posts" => "23"}`.
  A user who may not has no `"front_page"`, and the front page is the page at the home's
  address (`MishkaCmsMigration.Targets.CmsPage`). When the REST
  index lists the REST namespace of a language plugin, Polylang's `pll/v1` or WPML's `wpml/v1`, it
  keeps which one as `"languages"` (`"polylang"` or `"wpml"`): such a site names the language in its
  addresses, as `/fa/about/`, which the links an import writes do not follow
  (`MishkaCmsMigration.Targets.Helpers.LanguageUrls`).

  ## What it reads

  `kinds/0` is `["user", "category", "tag", "media", "setting", "stylesheet", "page", "post",
  "comment", "post_redirect", "menu"]`: authors, terms and files before the site's settings, its
  Elementor colours and fonts, and the pages and posts that point at them, the comments after the
  posts they are on, each post's old address after its post, and the menus after everything their
  links point at.
  `"setting"` is read from the REST index `connect/2` already read, with no request of its own: the
  site's name, tagline (`description`), logo (`site_logo`) and icon (`site_icon`), each one a row
  when the site has it. `"stylesheet"` is the Elementor globals `connect/2` read, with no request of
  its own: when the REST index lists Elementor's `elementor/v1`, `connect/2` asks
  `/elementor/v1/globals` once, and a site that answers none has no row
  (`MishkaCmsMigration.Sources.WordPress.ElementorKit`). `list/3` reads each other kind from its REST route (`/wp/v2/users`,
  `/wp/v2/categories`, `/wp/v2/tags`, `/wp/v2/media`, `/wp/v2/pages`, `/wp/v2/posts`,
  `/wp/v2/comments`) as the signed-in user, with `context=edit`, so WordPress answers the raw fields
  an editor sees, 100 rows a page; `rows/3` asks the same route for the rows of picked items alone,
  by their ids. Pages and posts are asked for with
  `status=any`: published, scheduled, draft, pending and private, but not the trash. Comments are
  asked for with `status=all` and `type=all`: approved and held for moderation, of every type
  (WordPress answers only plain comments unless asked), but not spam and not the trash.
  `"post_redirect"` reads the posts again, only their `id`, `title`, `status`, `link` and
  `modified_gmt` (`_fields`). The cursor is the next page number while `X-WP-TotalPages` says there
  is one, and `nil` after the last. `"menu"` is one page: every menu (`/wp/v2/menus`, WordPress
  5.9+) with its items (`/wp/v2/menu-items`) and every block menu (`/wp/v2/navigation`, asked for
  with `status=any`), each route read to its last page (`menus/4`). A list
  WordPress refuses fails the walk:
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
  WordPress saves a term's, a user's and a commenter's name as HTML, with `&`, `<` and `>` escaped
  (`Tom &amp; Jerry`), so each such name is read once as text (`Tom & Jerry`): the `name` of a
  category, a tag, a menu and a user, a user's `first_name`, `last_name` and `nickname`, and a
  comment's `author_name`, in the item's `title` and `attrs` alike.

    * page and post — `title` is `title.raw`, `modified_at` is `modified_gmt` as UTC, and
      `content` is `content.raw` converted (`MishkaCmsMigration.Sources.WordPress.Content`): its
      blocks, classic paragraphs and core shortcodes as HTML, and a piece for each block or
      shortcode left to `migration:content:convert`. The reusable blocks and gallery images it names
      are read from `/wp/v2/blocks` and `/wp/v2/media` with the connection the walk hands
      `normalize/3` (its context's `conn`); without one, or when WordPress does not answer, they are
      pieces too. An entry laid out with Elementor is its layout instead
      (`MishkaCmsMigration.Sources.WordPress.Elementor`), and its links and files below are read
      from that content; the widgets in it the CMS has no equivalent for are named in its
      `"unsupported_widgets"`, and those of them Elementor drew nothing for in its
      `"no_fallback_widgets"`, which only such an entry has. `attrs` keeps `slug`, `status`, `link`,
      `author`, `featured_media`, `date_gmt`, `template`, `excerpt` (its raw text), and `parent` and
      `menu_order` for a page, `categories`, `tags`, `sticky` and `format` for a post. Its `links`
      are the links of its content to a post
      of the site, each `href` as written to the post's decoded slug. A link on the site's own
      host, or a path alone, is asked for: `/?p=<id>` by its id (`include`), any other by the last
      segment of its path (`slug`), from `/wp/v2/posts` in any status with only `id`, `slug` and
      `link`, and it is the post whose `link` has its path, or whose id it names. A link to a
      category, a file, an attachment page or a post the site no longer has is left out, and so is
      every link when the connection is not at hand. Its `pages` are the links of its content that
      are left, to a page of the site, each `href` as written to the page's `"link"` and `"id"`
      (`%{"link" => "http://old.example/contact/", "id" => "29"}`): `/?page_id=<id>`
      is asked for by its id and any other by the last segment of its path, the same way, from
      `/wp/v2/pages`, and it is the page whose `link` has its path, or whose id it names. Its
      `media` are the addresses of
      its converted content (`src`, `href`, a video's `poster` and every candidate of an `srcset`) that are a file of the site's
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
      source's (every entry's own address is its canonical by default); and the social fields
      `"og_title"`, `"og_description"`, `"twitter_title"`, `"twitter_description"`,
      `"twitter_image"` (with `"twitter_image_id"`, found like `"image_id"`) and `"twitter_card"`
      (only `summary`, as the head draws `summary_large_image` by itself), each only when it says
      something else than the title or the description (or, for the Open Graph description, the
      entry's excerpt), which is what Yoast's head answers when nothing was written. Each is read from Rank
      Math's `rank_math_*` fields in `meta`, then Yoast's `_yoast_wpseo_*`, then the head Yoast
      answers (`yoast_head_json`), which is what the site served. An export carries every one of
      these fields; the REST API answers only a post's Yoast title and description among them, and
      none of Rank Math's, so the rest is read from Yoast's head: its title only when it is not the
      entry's own title, alone or followed by the site's name (Yoast's default, which the CMS's
      layout draws itself), and its robots only when they say `noindex` or `nofollow`. A variable
      in a title or description is the CMS's own where it has one (`%%title%%` and `%title%` as
      `{{page.title}}`, `sitename` as `{{site.name}}`, `excerpt` as `{{page.description}}`, `sep`
      as `-` and `page` as nothing), and a value with any other variable is left out. Each title
      and description is plain text, what the site showed: Yoast's head and a rendered excerpt
      hold HTML entities (`Elementor&#8217;s`), and so may a meta field, and each is read once
      (`Elementor’s`) before it is compared with the title, the description or the excerpt, so
      the CMS's head escapes it once.
    * media — `title` is `title.raw` and `modified_at` is `modified_gmt` as UTC; `attrs` keeps
      `slug`, `source_url` (where the file is), `filename` (the last segment of its path),
      `mime_type`, `media_type`, `filesize` (the file's bytes, `media_details.filesize` on a
      WordPress that answers none of its own), `alt_text`, `caption` and `description` (their raw
      text), `post` (the post it was uploaded to, `0` for none) and `date_gmt`. The files are
      listed oldest first (by id), so of two attachments that are the same file the earlier upload
      is the one the target meets first (`MishkaCmsMigration.Targets.CmsMedia`).
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
    * stylesheet — Elementor's global colours and fonts, one row: its `source_id` is
      `"elementor"`, `title` `"Elementor global colours and fonts"`, and `attrs` the stylesheet of
      theme tokens they become, its `"name"` (`elementor-globals`), `"description"` and `"content"`
      (`MishkaCmsMigration.Sources.WordPress.ElementorKit.stylesheet/2`).
    * post_redirect — the post's old address: its `source_id` is the post's id, `title` its title,
      and `attrs`'s `"from"` the path of its `link`, such as `/2025/12/hello/`, for a published post
      with an address of its own; `nil` for any other, such as a draft, whose `link` is
      `/?p=39`, an address no redirect can answer.
    * menu — one menu: its `source_id` is the menu's id (`navigation-` and the post's id for a
      block menu, whose `attrs` say `"block"` and, when a classic menu has the same links,
      `"same_as"`, that menu's name), `title` its name, and `attrs` keeps its
      `slug`, its theme `locations`, whether it is the site's `main` menu (`menus/4`), and its
      `items`, nested as WordPress nests them, each in menu order. An item is its label as text
      (`"title"`), the address WordPress gives it (`"url"`), what it points at as the kind and
      source id of an item of this source (`"kind"` and `"id"`: a page, a post, a category or a
      tag, `nil` for any other), whether it opens in a new tab (`"new_tab"`) and its own `"items"`.
      A custom link of the main menu on the site's own host that names a post or a page, asked for
      as a post's links to them are, points at that post or page. An item WordPress counts as
      invalid, whose page or term is gone, is left out, and one whose parent is not in the menu
      sits at the top.

  Each of these reads goes through the connection's `read`, a function of a REST route and its
  query answering the rows by id: `connect/2` answers one that asks the site, and the export file
  source (`MishkaCmsMigration.Sources.WordPressFile`) one that answers from the file, which hands
  `normalize/3` rows of the same shape, so both make the same items.

  `extra` is every other field of the row: `meta` (Yoast's `_yoast_wpseo_*` fields and every other
  registered meta), `guid`, `password`, `comment_status`, `class_list`, a user's `capabilities`
  and `registered_date`, a term's `taxonomy`, a file's `media_details` (its sizes among them), and
  what a plugin adds. It leaves out what WordPress works out afresh for each answer rather than
  keeps: `_links`, the `rendered` halves of the fields above, and Yoast's `yoast_head` and
  `yoast_head_json`; and the local `modified`, which `modified_at` already says. It leaves out
  Elementor's own meta too (`_elementor_*`: the layout an entry's content is made of, its version,
  caches and CSS), which Elementor answers, empty, for every entry it could lay out. Yoast's head
  carries the modified time too, so keeping either would make an item that was only saved again
  look changed to `MishkaCmsMigration.Source.Item.hash/1`. A row without the fields its kind needs,
  such as one read with `_fields`, is refused as `:unreadable`.

  ## Languages

  A page, a post, a category and a tag read from a site that runs a language plugin carry the
  language they are in as the item's `"language"`, and the other editions of them as its
  `"translations"`, by language, each the source id of that edition, the item's own left out
  (`%{"en" => "121"}`), read from what the plugin adds to the row:

    * Polylang Pro's `lang`, the language's code, and `translations`, the ids of every edition by
      code, its own among them (https://polylang.pro/doc/rest-api/). The export file source
      (`MishkaCmsMigration.Sources.WordPressFile`) makes the same two fields of what Polylang and
      WPML keep in an export;
    * the WPML REST API plugin's `wpml_current_locale`, the row's locale, such as `fa_IR`, and
      `wpml_translations`, the other editions by locale, each with its `id`
      (https://github.com/shawnhooper/wpml-rest-api). The language is the locale's first part:
      `fa_IR` is `fa`.

  A code is lower-cased, with `-` for `_`. These fields are not kept in `extra`. Polylang's free
  plugin adds no field to the REST API, but it lists its languages, each with the address its
  content is served under, at its public `/pll/v1/languages`, read once when the run connects: a
  row with neither field is in the language whose address its `link` sits under, the longest one
  (`/fa/` before `/`), such as `fa` for `http://site/fa/about/`, with no `"translations"`, which
  only the site's export says. A row whose `link` sits under no language's address, and any row of
  a site without Polylang, names no language and has neither key. WPML's REST API answers its
  default language alone unless a request names another, so a site that runs WPML is read once for
  each language of its `/wpml/v1/languages`, with `?lang=<code>`: its categories, tags, pages and
  posts. A site without WPML is read as before, with no extra request.

  Files are written to the CMS's media library (`MishkaCmsMigration.Targets.CmsMedia`), the site's
  name and pictures to its settings (`MishkaCmsMigration.Targets.CmsSetting`), its Elementor
  colours and fonts to a stylesheet of its own (`MishkaCmsMigration.Targets.CmsStylesheet`), pages
  as the CMS's
  own pages (`MishkaCmsMigration.Targets.CmsPage`), the main menu as the links of the site layout's
  header (`MishkaCmsMigration.Targets.CmsLayout`), and users,
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

  alias MishkaCmsMigration.Sources.WordPress.{
    Content,
    Elementor,
    ElementorKit,
    Export,
    Navigation,
    Permalinks
  }

  @kinds [
    "user",
    "category",
    "tag",
    "media",
    "setting",
    "stylesheet",
    "page",
    "post",
    "comment",
    "post_redirect",
    "menu"
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
    "media" => {"/wp/v2/media", [orderby: "id", order: "asc"]},
    "page" => {"/wp/v2/pages", [status: "any"]},
    "post" => {"/wp/v2/posts", [status: "any"]},
    "comment" => {"/wp/v2/comments", [status: "all", type: "all"]},
    "post_redirect" =>
      {"/wp/v2/posts", [status: "any", _fields: "id,title,status,link,modified_gmt"]}
  }

  @per_page 100
  @translated ~w(category tag page post post_redirect)

  @linked_fields [status: "any", _fields: "id,slug,link"]
  @permalink_posts [status: "publish", _fields: "id,status,slug,date,link,categories"]
  @permalink_categories [_fields: "id,slug,parent,link"]
  @media_fields [_fields: "id,source_url,media_details"]
  @addressed ["src", "href", "poster"]
  @sized ~r/(?:-(?:\d+x\d+|scaled))+$/

  @rendered ~w(_links yoast_head yoast_head_json)
  @edition_fields ~w(lang translations wpml_current_locale wpml_translations)

  @entries ["page", "post"]
  @entry_attrs ~w(slug status link parent author categories tags featured_media date_gmt
                  menu_order sticky format template)
  @entry_read ~w(id title content excerpt modified modified_gmt) ++
                @entry_attrs ++ @rendered ++ @edition_fields

  @media_attrs ~w(slug source_url mime_type media_type alt_text post date_gmt)
  @media_read ~w(id title caption description filesize modified modified_gmt) ++
                @media_attrs ++ @rendered

  @term_attrs ~w(slug description parent count link)
  @user_attrs ~w(username email slug name first_name last_name nickname description roles url
                 link avatar_urls)
  @named %{"category" => @term_attrs, "tag" => @term_attrs, "user" => @user_attrs}
  @escaped_names ~w(name first_name last_name nickname author_name)

  @settings [
    {"title", "name", "Site Title"},
    {"tagline", "description", "Tagline"},
    {"logo", "site_logo", "Site Logo"},
    {"icon", "site_icon", "Site Icon"}
  ]
  @texts ["title", "tagline"]
  @kit "elementor"
  @language_plugins %{"pll/v1" => "polylang", "wpml/v1" => "wpml"}

  @seo_titles ["rank_math_title", "_yoast_wpseo_title"]
  @seo_descriptions ["rank_math_description", "_yoast_wpseo_metadesc"]
  @seo_images ["rank_math_facebook_image", "_yoast_wpseo_opengraph-image"]
  @seo_social_titles ["rank_math_facebook_title", "_yoast_wpseo_opengraph-title"]
  @seo_social_descriptions [
    "rank_math_facebook_description",
    "_yoast_wpseo_opengraph-description"
  ]
  @seo_twitter_titles ["rank_math_twitter_title", "_yoast_wpseo_twitter-title"]
  @seo_twitter_descriptions ["rank_math_twitter_description", "_yoast_wpseo_twitter-description"]
  @seo_twitter_images ["rank_math_twitter_image", "_yoast_wpseo_twitter-image"]
  @seo_twitter_cards ["rank_math_twitter_card_type"]
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

  @menu_attrs ~w(id name slug locations items main)
  @menu_objects %{
    "page" => "page",
    "post" => "post",
    "category" => "category",
    "post_tag" => "tag"
  }
  @menu_typed ["post_type", "taxonomy"]
  @main_location "primary"

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
      {:ok,
       %{
         req: req,
         index: index,
         user: user,
         languages: wpml_languages(req, index["namespaces"]),
         polylang: polylang_homes(req, index["namespaces"]),
         elementor: elementor_globals(req, index["namespaces"]),
         read: &read(req, &1, &2)
       }}
    end
  end

  defp elementor_globals(req, namespaces) when is_list(namespaces),
    do: elementor_asked(req, "elementor/v1" in namespaces)

  defp elementor_globals(_req, _namespaces), do: %{}

  defp elementor_asked(req, true),
    do: req |> Req.get(url: "/elementor/v1/globals") |> elementor_answer()

  defp elementor_asked(_req, false), do: %{}

  defp elementor_answer({:ok, %Req.Response{status: 200, body: %{} = globals}}), do: globals
  defp elementor_answer(_unreadable), do: %{}

  defp wpml_languages(req, namespaces) when is_list(namespaces),
    do: req |> wpml_asked("wpml/v1" in namespaces) |> Enum.uniq()

  defp wpml_languages(_req, _namespaces), do: []

  defp wpml_asked(req, true), do: req |> Req.get(url: "/wpml/v1/languages") |> wpml_codes()
  defp wpml_asked(_req, false), do: []

  defp wpml_codes({:ok, %Req.Response{status: 200, body: [_ | _] = languages}}),
    do: for(%{"code" => code} <- languages, is_binary(code) and code != "", do: code)

  defp wpml_codes(_unreadable), do: []

  defp polylang_homes(req, namespaces) when is_list(namespaces),
    do: polylang_asked(req, "pll/v1" in namespaces)

  defp polylang_homes(_req, _namespaces), do: []

  defp polylang_asked(req, true), do: req |> Req.get(url: "/pll/v1/languages") |> homes()
  defp polylang_asked(_req, false), do: []

  defp homes({:ok, %Req.Response{status: 200, body: [_ | _] = languages}}),
    do:
      for(
        %{"slug" => slug, "home_url" => home} <- languages,
        is_binary(slug) and slug != "" and is_binary(home),
        do: {code(slug), URI.parse(home)}
      )

  defp homes(_unreadable), do: []

  @impl MishkaCmsMigration.Source
  def extra(%{req: req, index: index, user: user} = conn) do
    %{
      "name" => index["name"],
      "home" => index["home"],
      "timezone" => index["timezone_string"],
      "signed_in_as" => user["username"],
      "permalinks" => permalinks(conn)
    }
    |> Map.merge(languages(index["namespaces"]))
    |> Map.merge(req |> Req.get(url: "/wp/v2/settings") |> front_page())
  end

  defp permalinks(%{req: req, index: index} = conn) do
    categories = req |> every("/wp/v2/categories", @permalink_categories, 1, []) |> read_rows()

    Permalinks.call(%{
      posts:
        req
        |> every("/wp/v2/posts", @permalink_posts, 1, [])
        |> read_rows()
        |> Enum.filter(&(&1["status"] == "publish")),
      categories: Map.new(categories, &{&1["id"], {&1["slug"], &1["parent"]}}),
      terms: %{
        "category" => Enum.map(categories, &%{"key" => &1["id"], "link" => &1["link"]}),
        "tag" =>
          req
          |> Req.get(url: "/wp/v2/tags", params: [per_page: @per_page, _fields: "slug,link"])
          |> listed(1)
          |> read_rows()
      },
      home: index["home"],
      languages: Enum.map(conn.polylang, &elem(&1, 0)) ++ conn.languages
    })
  end

  defp read_rows({:ok, rows}), do: rows
  defp read_rows({:ok, rows, _next}), do: rows
  defp read_rows(_refused), do: []

  defp front_page(
         {:ok, %Req.Response{status: 200, body: %{"show_on_front" => "page"} = settings}}
       ),
       do: %{
         "front_page" => %{
           "show_on_front" => "page",
           "page_on_front" => page_id(settings["page_on_front"]),
           "page_for_posts" => page_id(settings["page_for_posts"])
         }
       }

  defp front_page({:ok, %Req.Response{status: 200, body: %{"show_on_front" => "posts"}}}),
    do: %{
      "front_page" => %{
        "show_on_front" => "posts",
        "page_on_front" => nil,
        "page_for_posts" => nil
      }
    }

  defp front_page(_unreadable), do: %{}

  defp page_id(id) when is_integer(id) and id > 0, do: Integer.to_string(id)
  defp page_id(_none), do: nil

  defp languages(namespaces) when is_list(namespaces),
    do: namespaces |> Enum.find_value(&Map.get(@language_plugins, &1)) |> languages()

  defp languages(plugin) when is_binary(plugin), do: %{"languages" => plugin}
  defp languages(_none), do: %{}

  @impl MishkaCmsMigration.Source
  def list(%{req: req, languages: [_ | _] = codes}, kind, cursor) when kind in @translated do
    {route, params} = Map.fetch!(@routes, kind)
    {code, page} = cursor || {hd(codes), 1}

    req
    |> Req.get(
      url: route,
      params: [context: "edit", per_page: @per_page, page: page, lang: code] ++ params
    )
    |> listed(page)
    |> in_language(code, codes)
  end

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

  def list(%{elementor: globals}, "stylesheet", _cursor) when map_size(globals) > 0,
    do: {:ok, [Map.put(globals, "id", @kit)], nil}

  def list(_conn, "stylesheet", _cursor), do: {:ok, [], nil}

  def list(%{req: req, index: index}, "menu", _cursor) do
    with {:ok, menus} <- every(req, "/wp/v2/menus", [], 1, []),
         {:ok, items} <- every(req, "/wp/v2/menu-items", [], 1, []),
         {:ok, blocks} <- every(req, "/wp/v2/navigation", [status: "any"], 1, []) do
      {:ok, menus(menus, items, blocks, index["home"]), nil}
    end
  end

  def list(_conn, kind, _cursor), do: {:error, {:unknown_kind, kind}}

  @doc """
  The rows of `kind` with the WordPress ids `source_ids`, what a job of picked items reads: asked
  for from the kind's REST route as `list/3` asks for a page, by their ids (`include`), 100 ids a
  request. The settings, read from the REST index, and the menus, whose main one and block twins
  are told apart only among them all, are the picked rows of `list/3`'s one page. WordPress refuses
  as `list/3` says.
  """
  @impl MishkaCmsMigration.Source
  def rows(%{req: req} = conn, kind, source_ids) when is_map_key(@routes, kind) do
    {route, params} = Map.fetch!(@routes, kind)
    languages = asked_in(conn, kind)

    for ids <- Enum.chunk_every(source_ids, @per_page), language <- languages do
      {ids, language}
    end
    |> Enum.reduce_while({:ok, []}, fn {ids, language}, {:ok, read} ->
      req
      |> Req.get(
        url: route,
        params:
          [context: "edit", per_page: @per_page, include: Enum.join(ids, ",")] ++
            language ++ params
      )
      |> listed(1)
      |> read_on(read)
    end)
  end

  def rows(conn, kind, source_ids) do
    with {:ok, rows, _next} <- list(conn, kind, nil),
         do: {:ok, Enum.filter(rows, &(to_string(&1["id"]) in source_ids))}
  end

  defp asked_in(%{languages: [_ | _] = codes}, kind) when kind in @translated,
    do: Enum.map(codes, &[lang: &1])

  defp asked_in(_conn, _kind), do: [[]]

  defp read_on({:ok, rows, _next}, read), do: {:cont, {:ok, read ++ rows}}
  defp read_on(refused, _read), do: {:halt, refused}

  @doc """
  The rows `list/3` answers for `"menu"`, of the REST API's `menus` and `menu-items` (or rows of the
  same shape): each menu with its `"items"`, the items whose `menus` is its id but those WordPress
  counts as `invalid`, and `"main"`, whether it is the site's main menu: the one at the theme's
  `primary` location, else the first at any location, else the first made (the lowest id), which
  comes first, so an import writes it before any other menu. Then the block menus, the `wp_navigation` posts of `navigation`
  (`MishkaCmsMigration.Sources.WordPress.Navigation`), with `"same_as"`, the name of the classic
  menu that has the same links, when one has.
  """
  @spec menus([map()], [map()], [map()], String.t() | nil) :: [map()]
  def menus(menus, items, navigation, home) do
    by_menu = items |> Enum.reject(&(&1["invalid"] == true)) |> Enum.group_by(& &1["menus"])
    main = menus |> Enum.min_by(&{located(&1["locations"]), &1["id"]}, fn -> %{} end)

    classic =
      for menu <- Enum.sort_by(menus, &(&1["id"] != main["id"])),
          do:
            Map.merge(menu, %{
              "items" => Map.get(by_menu, menu["id"], []),
              "main" => menu["id"] == main["id"]
            })

    classic ++ blocks(navigation, home, classic)
  end

  defp blocks(navigation, home, classic) do
    twins =
      classic
      |> Enum.sort_by(& &1["id"])
      |> Enum.reduce(%{}, &Map.put_new(&2, classic_targets(&1["items"]), unescaped(&1["name"])))

    for menu <- Navigation.call(navigation, home),
        do: Map.put(menu, "same_as", twins[Navigation.targets(menu["items"])])
  end

  defp classic_targets(items), do: items |> Enum.map(&classic_target/1) |> Enum.sort()

  defp classic_target(item), do: item |> menu_object(%{}) |> target(item)

  defp target({nil, nil}, item), do: {:url, String.trim_trailing(item["url"] || "", "/")}
  defp target({kind, id}, _item), do: {:object, kind, id}

  @impl MishkaCmsMigration.Source
  def normalize(
        %{"id" => id, "title" => %{"raw" => title}, "content" => %{"raw" => html}} = row,
        kind,
        context
      )
      when kind in @entries do
    fetch = fetch(context)

    {content, html, laid_out} =
      row |> Elementor.call(kind, fetch, elementor(context)) |> body(html, fetch)

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
         |> Map.merge(laid_out)
         |> Map.merge(links(html, context))
         |> Map.merge(edition(row, context)),
       extra: row |> Map.drop(@entry_read) |> without_elementor(),
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
       title: unescaped(row["author_name"]),
       parent: parent(row),
       attrs:
         row
         |> Map.take(@comment_attrs)
         |> unescaped_names()
         |> Map.put("post_type", post_type(row)),
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

  def normalize(%{"id" => id, "name" => name} = row, kind, context)
      when is_map_key(@named, kind) do
    attrs = Map.fetch!(@named, kind)

    {:ok,
     %{
       source_id: id,
       title: unescaped(name),
       parent: parent(row),
       attrs:
         row
         |> Map.take(attrs)
         |> unescaped_names()
         |> decoded_slug()
         |> Map.merge(edition(row, context)),
       extra: Map.drop(row, ["id", "name" | attrs] ++ @rendered ++ @edition_fields)
     }}
  end

  def normalize(%{"id" => id, "label" => label, "value" => value}, "setting", _context),
    do: {:ok, %{source_id: id, title: label, attrs: %{"value" => value}}}

  def normalize(%{"id" => @kit} = globals, "stylesheet", context),
    do: globals |> ElementorKit.stylesheet(context[:source_host]) |> stylesheet()

  def normalize(
        %{"id" => id, "name" => name, "block" => true, "items" => items} = row,
        "menu",
        _c
      )
      when is_list(items) do
    {:ok,
     %{
       source_id: id,
       title: name,
       attrs:
         row
         |> Map.take(["slug", "same_as"])
         |> decoded_slug()
         |> Map.merge(%{"locations" => [], "main" => false, "block" => true, "items" => items}),
       extra: Map.drop(row, @menu_attrs ++ ["block", "same_as"] ++ @rendered)
     }}
  end

  def normalize(%{"id" => id, "name" => name, "items" => items} = row, "menu", context)
      when is_list(items) do
    main? = row["main"] == true

    {:ok,
     %{
       source_id: id,
       title: unescaped(name),
       attrs:
         row
         |> Map.take(["slug"])
         |> decoded_slug()
         |> Map.merge(%{
           "locations" => row["locations"] || [],
           "main" => main?,
           "items" => menu_items(items, custom_links(items, main?, context))
         }),
       extra: Map.drop(row, @menu_attrs ++ @rendered)
     }}
  end

  def normalize(_row, kind, _context) when kind in @kinds, do: {:error, :unreadable}
  def normalize(_row, kind, _context), do: {:error, {:unknown_kind, kind}}

  defp edition(%{"lang" => lang} = row) when is_binary(lang) and lang != "",
    do: lang |> code() |> edition(row["translations"], &{code(elem(&1, 0)), elem(&1, 1)})

  defp edition(%{"wpml_current_locale" => locale} = row) when is_binary(locale) and locale != "",
    do: locale |> locale_code() |> edition(row["wpml_translations"], &wpml_edition/1)

  defp edition(_row), do: %{}

  defp edition(row, %{conn: %{polylang: [_ | _] = homes}}),
    do: row |> edition() |> addressed(row["link"], homes)

  defp edition(row, _context), do: edition(row)

  defp addressed(edition, link, homes) when edition == %{} and is_binary(link),
    do: link |> URI.parse() |> home_of(homes) |> in_language()

  defp addressed(edition, _link, _homes), do: edition

  defp home_of(link, homes),
    do:
      homes
      |> Enum.filter(fn {_code, home} -> under?(link, home) end)
      |> Enum.max_by(fn {_code, home} -> String.length(home.path || "") end, fn -> nil end)

  defp under?(link, home),
    do:
      link.host == home.host and link.port == home.port and
        String.starts_with?(link.path || "/", home.path || "/") and
        Enum.all?(asked(home.query), &(&1 in asked(link.query)))

  defp asked(nil), do: []
  defp asked(query), do: query |> URI.decode_query() |> Enum.to_list()

  defp in_language({code, _home}), do: %{"language" => code, "translations" => %{}}
  defp in_language(nil), do: %{}

  defp edition(language, translations, read) do
    %{
      "language" => language,
      "translations" =>
        for(
          entry <- editions(translations),
          {code, id} = read.(entry),
          is_binary(code) and code != language and (is_integer(id) or is_binary(id)),
          into: %{},
          do: {code, to_string(id)}
        )
    }
  end

  defp editions(%{} = translations), do: Enum.to_list(translations)
  defp editions(translations) when is_list(translations), do: translations
  defp editions(_none), do: []

  defp wpml_edition({_locale, edition}), do: wpml_edition(edition)
  defp wpml_edition(%{"locale" => locale, "id" => id}), do: {locale_code(locale), id}
  defp wpml_edition(_edition), do: {nil, nil}

  defp code(code) when is_binary(code),
    do: code |> String.trim() |> String.downcase() |> String.replace("_", "-")

  defp code(_code), do: nil

  defp locale_code(locale) when is_binary(locale),
    do: locale |> String.split("_", parts: 2) |> hd() |> code()

  defp locale_code(_locale), do: nil

  defp setting(id, value) when id in @texts and is_binary(value), do: value |> plain() |> filled()

  defp setting(_file, id) when is_integer(id) and id > 0, do: id
  defp setting(_id, _none), do: nil

  defp filled(""), do: nil
  defp filled(text), do: text

  defp plain(html) when is_binary(html),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()

  defp plain(_none), do: ""

  defp unescaped(text) when is_binary(text), do: plain(text)
  defp unescaped(none), do: none

  defp unescaped_names(attrs),
    do:
      Map.merge(
        attrs,
        for(
          {field, name} <- Map.take(attrs, @escaped_names),
          into: %{},
          do: {field, unescaped(name)}
        )
      )

  defp every(req, route, extra, page, rows) do
    req
    |> Req.get(
      url: route,
      params: [context: "edit", per_page: @per_page, page: page] ++ extra
    )
    |> listed(page)
    |> every_page(req, {route, extra}, rows)
  end

  defp every_page({:ok, rows, nil}, _req, _asked, read), do: {:ok, read ++ rows}

  defp every_page({:ok, rows, next}, req, {route, extra}, read),
    do: every(req, route, extra, next, read ++ rows)

  defp every_page(refused, _req, _asked, _read), do: refused

  defp located(locations) when is_list(locations),
    do: located(@main_location in locations, locations)

  defp located(_none), do: 2

  defp located(true, _locations), do: 0
  defp located(false, [_ | _]), do: 1
  defp located(false, []), do: 2

  defp menu_items(items, found) do
    ids = Map.new(items, &{&1["id"], true})

    items
    |> Enum.sort_by(&{&1["menu_order"] || 0, &1["id"]})
    |> Enum.group_by(&menu_parent(&1["parent"], ids))
    |> branch(0, found)
  end

  defp menu_parent(parent, ids) when is_map_key(ids, parent), do: parent
  defp menu_parent(_parent, _ids), do: 0

  defp branch(children, parent, found),
    do: for(item <- Map.get(children, parent, []), do: menu_item(item, children, found))

  defp menu_item(item, children, found) do
    {kind, id} = menu_object(item, found)

    %{
      "title" => item |> Map.get("title") |> raw() |> plain(),
      "url" => item["url"],
      "kind" => kind,
      "id" => id,
      "new_tab" => item["target"] == "_blank",
      "items" => branch(children, item["id"], found)
    }
  end

  defp menu_object(%{"type" => type, "object" => object, "object_id" => id}, _found)
       when type in @menu_typed and is_map_key(@menu_objects, object),
       do: {Map.fetch!(@menu_objects, object), to_string(id)}

  defp menu_object(%{"url" => url}, found) when is_map_key(found, url), do: Map.fetch!(found, url)
  defp menu_object(_item, _found), do: {nil, nil}

  defp custom_links(items, true, %{conn: %{read: read, index: %{"home" => home}}})
       when is_binary(home) do
    {posts, pages} =
      items
      |> Enum.flat_map(&custom_url/1)
      |> linked_entries(read, home)

    Map.merge(found_as(pages, "page"), found_as(posts, "post"))
  end

  defp custom_links(_items, _main?, _context), do: %{}

  defp custom_url(%{"type" => "custom", "url" => url}) when is_binary(url), do: [url]
  defp custom_url(_item), do: []

  defp found_as(rows, kind),
    do: Map.new(rows, fn {href, row} -> {href, {kind, to_string(row["id"])}} end)

  defp fetch(%{conn: %{read: read}}), do: &read.(&1, include: Enum.join(&2, ","))
  defp fetch(_context), do: fn _route, _ids -> %{} end

  defp elementor(%{conn: %{elementor: globals}}), do: globals
  defp elementor(_context), do: %{}

  defp stylesheet(nil), do: {:error, :unreadable}

  defp stylesheet(attrs),
    do: {:ok, %{source_id: @kit, title: "Elementor global colours and fonts", attrs: attrs}}

  defp body({:ok, content, unsupported, no_fallback}, _raw, _fetch),
    do:
      {content, for(%{html: html} when is_binary(html) <- content, into: "", do: html),
       unsupported_widgets(unsupported, no_fallback)}

  defp body(:none, raw, fetch), do: {Content.call(raw, fetch), raw, %{}}

  defp unsupported_widgets([], _no_fallback), do: %{}
  defp unsupported_widgets(names, []), do: %{"unsupported_widgets" => names}

  defp unsupported_widgets(names, no_fallback),
    do: %{"unsupported_widgets" => names, "no_fallback_widgets" => no_fallback}

  defp without_elementor(%{"meta" => %{} = meta} = extra),
    do: %{extra | "meta" => Map.reject(meta, fn {key, _value} -> elementor?(key) end)}

  defp without_elementor(extra), do: extra

  defp elementor?("_elementor_" <> _key), do: true
  defp elementor?(_key), do: false

  defp read(req, route, params),
    do:
      req
      |> Req.get(url: route, params: [context: "edit", per_page: @per_page] ++ params)
      |> by_id()

  defp links(html, %{conn: %{read: read, index: %{"home" => home}}}) when is_binary(home) do
    {posts, pages} =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("a[href]")
      |> LazyHTML.attribute("href")
      |> linked_entries(read, home)

    %{
      "links" =>
        for({href, %{"slug" => slug}} <- posts, slug != "", into: %{}, do: {href, decoded(slug)}),
      "pages" =>
        for(
          {href, %{"link" => link, "id" => id}} <- pages,
          is_binary(link),
          into: %{},
          do: {href, %{"link" => link, "id" => to_string(id)}}
        )
    }
  end

  defp links(_html, _context), do: %{"links" => %{}, "pages" => %{}}

  defp linked_entries(hrefs, read, home) do
    asked = hrefs |> Enum.uniq() |> Enum.flat_map(&asked(&1, URI.parse(home)))
    posts = linked(read, "/wp/v2/posts", asked)
    {posts, linked(read, "/wp/v2/pages", Enum.reject(asked, &is_map_key(posts, elem(&1, 0))))}
  end

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

    images =
      for field <- ["image", "twitter_image"],
          url <- List.wrap(seo[field]),
          file?(url, home),
          do: {field, url}

    rows =
      Enum.flat_map(
        [
          include: image_ids(html),
          slug:
            files |> Enum.concat(Enum.map(images, &elem(&1, 1))) |> Enum.flat_map(&file_slugs/1)
        ],
        &asked_rows(read, {"/wp/v2/media", @media_fields}, &1)
      )

    {for(href <- files, id = file_of(rows, href), into: %{}, do: {href, id}),
     Enum.reduce(images, seo, fn {field, url}, seo -> image_id(seo, field, file_of(rows, url)) end)}
  end

  defp media(_html, _content, seo, _context), do: {%{}, seo}

  defp image_id(seo, _field, nil), do: seo
  defp image_id(seo, field, id), do: Map.put(seo, field <> "_id", id)

  defp seo(row, context) do
    meta = with_map(row["meta"])
    head = with_map(row["yoast_head_json"])
    title = typed(meta, @seo_titles) || served_title(head, row)
    description = typed(meta, @seo_descriptions) || shown(head["description"])

    %{
      "title" => title,
      "description" => description,
      "robots" => robots(meta) || served_robots(head["robots"]),
      "image" => said(meta, @seo_images) || served_image(head["og_image"]),
      "canonical" =>
        (said(meta, @seo_canonicals) || said(head["canonical"])) |> elsewhere(context)
    }
    |> Map.merge(social(meta, head, row, {title, description}))
    |> Map.reject(fn {_field, value} -> is_nil(value) end)
  end

  defp social(meta, head, row, {title, description}) do
    %{
      "og_title" =>
        (typed(meta, @seo_social_titles) ||
           served_title(Map.put(head, "title", head["og_title"]), row))
        |> differing(title),
      "og_description" =>
        (typed(meta, @seo_social_descriptions) || served_description(head["og_description"], row))
        |> differing(description),
      "twitter_title" =>
        (typed(meta, @seo_twitter_titles) || shown(head["twitter_title"])) |> differing(title),
      "twitter_description" =>
        (typed(meta, @seo_twitter_descriptions) || shown(head["twitter_description"]))
        |> differing(description),
      "twitter_image" => said(meta, @seo_twitter_images) || said(head["twitter_image"]),
      "twitter_card" => meta |> said(@seo_twitter_cards) |> card() || card(head["twitter_card"])
    }
  end

  defp differing(value, value), do: nil
  defp differing(value, _other), do: value

  defp card("summary"), do: "summary"
  defp card(_default_or_other), do: nil

  defp served_description(text, %{"excerpt" => %{"rendered" => excerpt}}) when is_binary(excerpt),
    do: text |> shown() |> own_description(plain(excerpt))

  defp served_description(text, _row), do: shown(text)

  defp own_description(nil, _excerpt), do: nil

  defp own_description(text, excerpt),
    do: text |> differing(excerpt |> String.split() |> Enum.join(" "))

  defp with_map(%{} = map), do: map
  defp with_map(_none), do: %{}

  defp typed(meta, keys), do: keys |> Enum.find_value(&shown(meta[&1])) |> variables()

  defp said(meta, keys), do: Enum.find_value(keys, &said(meta[&1]))

  defp said(text) when is_binary(text), do: text |> String.trim() |> filled()
  defp said(_none), do: nil

  defp shown(text) when is_binary(text), do: text |> plain() |> filled()
  defp shown(_none), do: nil

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
       do: title |> shown() |> own_title(own, plain(site))

  defp served_title(head, _row), do: shown(head["title"])

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

    singles =
      for attribute <- @addressed,
          address <- tree |> LazyHTML.query("[#{attribute}]") |> LazyHTML.attribute(attribute),
          do: address

    candidates =
      for value <- tree |> LazyHTML.query("[srcset]") |> LazyHTML.attribute("srcset"),
          {url, _descriptor} <- Source.srcset(value),
          do: url

    Enum.uniq(singles ++ candidates)
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

  defp in_language({:ok, rows, nil}, code, codes),
    do: {:ok, rows, codes |> Enum.drop_while(&(&1 != code)) |> next_language()}

  defp in_language({:ok, rows, page}, code, _codes), do: {:ok, rows, {code, page}}
  defp in_language(refused, _code, _codes), do: refused

  defp next_language([_current, next | _rest]), do: {next, 1}
  defp next_language(_last), do: nil

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
