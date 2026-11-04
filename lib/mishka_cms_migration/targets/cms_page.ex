# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.CmsPage do
  @moduledoc """
  The `"page"` items of a source written as the CMS's own pages (`MishkaCmsCore.Runtime.Page`),
  through the `:create` and `:update` an admin's own page form runs, on the run's site and as the
  admin who pressed Import: the admin needs the core's `admin:dashboard:runtime:page`, and the
  core's own rules decide the rest, such as that a path is unique within a site and that a page's
  template must compile.

  An item's title is the page's title, its content pieces, converted, the page's template (below),
  and the page is in the language the site leads with
  (`MishkaCmsCore.Runtime.Languages.primary/1`): a WordPress page has no language of its own. It is
  drawn in the site's `site-main` layout (`MishkaCmsCore.Runtime.SiteLayout.layout_id/1`), between
  the header and the footer every page of the site shares, as the pages an extension provisions are.
  The core names the page after its title, as it does for a page typed in the form.

  ## Its path

  The page's path is the path of its address at the source, without the host and the trailing `/`:
  `http://old.example/about/team/` is `/about/team`, so a page under its parent keeps the nested
  path and needs nothing from the parent's record. A page that has no address of its own yet, such
  as a draft whose `"link"` is `/?page_id=30`, takes the one WordPress would give it, from the
  `"permalink_template"` it answers (`MishkaCmsMigration.Sources.WordPress` keeps it in `extra`)
  with the page's slug in it. The core serves only ASCII paths, so a segment that is not made of
  letters, digits and `- _ .` (a slug written in another script, which WordPress keeps
  percent-encoded) is decoded and transliterated the way the core slugs a name, `/وردپرس` being
  `/wrdprs`, and the report says so (`"path_made_ascii"`). The old address is not redirected.

  The source's front page is the page whose address is `/`, and its posts page the page at the
  address of the posts: neither is told apart, since the address says it. A page whose path the
  site already has, such as the site's home at `/`, also when the site's page is not live, waits
  for an admin's decision (`"slug_taken"`, `MishkaCmsMigration.MigrationItem`'s Decide…); nothing
  is ever written over a page an admin made. Connect to the existing record makes the item that
  page, kept as it is, and the pages under it are written as the walk writes any child. Import as
  new with another slug writes the item as a page of its own, its path's last part followed by its
  source id, `/contact-29` for `/contact` and `/home-2` for a front page whose slug is `home`, and
  the report says so (`"another_slug"`). A page under one that waits is skipped, as the walk does
  for any item whose parent was not imported (`"parent_missing"`).

  A live page is also refused where the site already answers its address by a pattern, such as
  `/blog` where the Blog's `/:lang/blog` answers: the core says which page does, and the item fails
  with its sentence. The same page is written as a draft, which answers nothing.

  ## Status

  By the run's `pages` choice (`MishkaCmsMigration.MigrationRun`'s options):

    * `"publish"` — a page WordPress has published is live at its path (`active`); a draft, and any
      other, is a page that is not live;
    * `"draft"` (the default) — every page is a page that is not live, at the path it would have,
      so nothing goes live until an admin publishes it.

  The core has no page pending review, private, behind a password or scheduled, so `"pending"`,
  `"private"`, a page with a `"password"` (in its `extra`) and `"future"` are never live, and the
  report says so for each (`note/2`: `"draft_from_pending"`, `"draft_from_private"`,
  `"draft_from_password"`, `"draft_from_future"`), in the dry run too.

  ## Its template

  A page is compiled as HEEx, in which `{...}` and `<%= ... %>` are Elixir the page runs, so the
  content, which is only text and markup, is written so that it cannot be either:

    * it is read and written back with an HTML parser (`LazyHTML`), so its tags are balanced and
      the `<` of every text and attribute value is `&lt;`;
    * the `<%` that is left, in a script, a style or a comment, whose text is not escaped, is
      written `&lt;%`, so no EEx tag opens;
    * all of it sits inside one `<div phx-no-curly-interpolation>`, which makes HEEx read every `{`
      under it as text, however deep. A `{` in a paragraph, in a code block, or in the raw text of
      a block nobody converted is shown as it was.

  The builder opens the page with that `div` as its root. An element WordPress had, with an
  attribute name HEEx reads as code (`:if`, or one in braces), is refused by the core's compile
  check with its own sentence, and the item fails with it. A deployment that turned hand-written
  templates off (`config :mishka_cms_core, :page_code, :off`) refuses every page the same way.

  ## Its pictures and files

  Its `"media"` name the addresses of its content that are files of the source, and each `src`,
  `href` and video `poster` of them points at the Media address of the file the same run, or an earlier one,
  wrote for it (`MishkaCmsMigration.Targets.CmsMedia.relinked/3`), a size WordPress made of a file
  too. The address of a file that was not written is kept as it is, and so is every other link.

  ## Its links to pages

  Its `"pages"` name the links of its content that point at a page of the source, each by its
  `href` as written and the address WordPress gives that page (the WordPress source finds them,
  `MishkaCmsMigration.Sources.WordPress`). Each such link points at the path that page is written
  at instead (`relinked/2`), however the link was written, and keeps its `?query` and `#fragment`:
  `http://old.example/about/team/#staff` becomes `/about/team#staff`. It is the path the run
  writes the page at, so a page that links to one listed after it points at it too. A page with no
  address of its own yet, such as a draft, and any other link, such as a category's or a feed's,
  is kept as it is. The same links in a post point at the same paths
  (`MishkaCmsMigration.Targets.BlogPost`).

  ## Its SEO

  Its `"seo"`, what Yoast SEO or Rank Math kept for it (the WordPress source reads it), is the
  page's `seo_tags` (`MishkaCmsMigration.Targets.Helpers.SeoTags`): its title, description, robots,
  share image, as the Media file it was imported as, and a canonical address on another site.

  ## Its videos

  A YouTube or Vimeo player its content frames (the WordPress source makes one of each embed) is
  allowed on the site before the page is written, in an import only, as the admin
  (`MishkaCmsMigration.Targets.Helpers.Frames`), and the report names them
  (`"frames_allowed: <origins>"`), in the dry run too. For an admin who may not change the site's
  settings the page waits for an admin's decision (`"player_not_allowed"`), once its path does not,
  in the dry run too (`waiting/2`), also a page an earlier import wrote: Wait for an admin keeps it
  for a run by one who may, and Import without the player writes it with that player left out
  (`"player_left_out"`).
  """

  use MishkaCmsMigration.Target,
    kind: "page",
    resource: MishkaCmsCore.Runtime.Page,
    create: :create,
    update: :update

  require Ash.Query

  alias MishkaCmsCore.Runtime.{Languages, Page, SiteLayout}
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Target
  alias MishkaCmsMigration.Targets.CmsMedia
  alias MishkaCmsMigration.Targets.Helpers.{BySlug, Frames, Read, SeoTags, Status}

  @drafted ["pending", "private", "password", "future"]

  @impl MishkaCmsMigration.Target
  def attrs(item, context) do
    %{
      title: item.title,
      path: item |> path() |> placed(item, Target.decision(context, item, "slug_taken")),
      template: template(item, context),
      active: active?(item, context),
      seo_tags: SeoTags.call(item, context, nil),
      language: Languages.primary(context.site_id),
      layout_id: SiteLayout.layout_id(context.site_id)
    }
  end

  @impl MishkaCmsMigration.Target
  def existing(items, context) do
    taken = items |> Enum.map(&path/1) |> Enum.reject(&is_nil/1) |> taken(context)

    for item <- items,
        page = taken[path(item)],
        found = held(page, Target.decision(context, item, "slug_taken")),
        into: %{},
        do: {item.source_id, found}
  end

  @impl MishkaCmsMigration.Target
  def prepare(item, context, write),
    do: with(:ok <- Frames.call(item, context), do: write.(context))

  @impl MishkaCmsMigration.Target
  def waiting(item, context), do: Frames.waiting(item, context)

  @impl MishkaCmsMigration.Target
  def note(item, context),
    do:
      [
        item |> Status.call() |> drafted(),
        moved(item),
        BySlug.note(item, context),
        Frames.note(item, context)
      ]
      |> Enum.reject(&is_nil/1)
      |> noted()

  @doc """
  `html` with each link that `pages` names, an `href` as the source wrote it to the address the
  source gives the page it is (`MishkaCmsMigration.Sources.WordPress`'s `pages`), pointing at the
  path the CMS serves that page at (`path/1`'s rules: the path of its address, in ASCII), with the
  link's own `?query` and `#fragment`. A link whose page has no address of its own, and every other
  link, is kept as it is.
  """
  @spec relinked(String.t(), map() | nil) :: String.t()
  def relinked(html, pages) when is_map(pages) and map_size(pages) > 0,
    do:
      CmsMedia.moved(
        html,
        for({old, link} <- pages, new = pointed(link, old), into: %{}, do: {old, new})
      )

  def relinked(html, _pages), do: html

  defp pointed(link, old), do: link |> served() |> ascii() |> pointed_at(old)

  defp pointed_at(nil, _old), do: nil

  defp pointed_at(path, old),
    do:
      old
      |> String.trim()
      |> URI.parse()
      |> then(&URI.to_string(%URI{path: path, query: query(&1), fragment: &1.fragment}))

  defp query(%URI{path: path}) when path in [nil, "", "/"], do: nil
  defp query(%URI{query: query}), do: query

  defp taken([], _context), do: %{}

  defp taken(paths, context),
    do:
      Page
      |> Ash.Query.filter(path in ^paths)
      |> Read.call(context)
      |> Map.new(&{&1.path, &1})

  defp held(page, "keep"), do: {:connected, page}
  defp held(_page, "import"), do: nil
  defp held(_page, nil), do: {:undecided, "slug_taken"}

  defp placed("/", item, "import"),
    do: ascii("/" <> (slug(item) || "page") <> "-" <> item.source_id)

  defp placed(path, item, "import") when is_binary(path), do: path <> "-" <> item.source_id
  defp placed(path, _item, _decision), do: path

  defp active?(item, %{options: %{pages: "publish"}}), do: Status.call(item) == "publish"
  defp active?(_item, _context), do: false

  defp drafted(status) when status in @drafted, do: "draft_from_" <> status
  defp drafted(_status), do: nil

  defp moved(item), do: moved(address(item), path(item))
  defp moved(path, path), do: nil
  defp moved(_address, _ascii), do: "path_made_ascii"

  defp noted([]), do: nil
  defp noted(notes), do: Enum.join(notes, "; ")

  defp path(item), do: item |> address() |> ascii()

  defp address(%Item{attrs: attrs} = item),
    do: Enum.find_value([attrs["link"], permalink(item)], &served/1)

  defp permalink(%Item{extra: %{"permalink_template" => url}} = item) when is_binary(url),
    do: item |> slug() |> filled(url)

  defp permalink(_item), do: nil

  defp slug(%Item{attrs: attrs, extra: extra}),
    do: Enum.find([attrs["slug"], extra["generated_slug"]], &(is_binary(&1) and &1 != ""))

  defp filled(nil, _url), do: nil
  defp filled(slug, url), do: String.replace(url, "%pagename%", slug)

  defp served(url) when is_binary(url), do: url |> URI.parse() |> served_path()
  defp served(_no_url), do: nil

  defp served_path(%URI{path: "/" <> _ = path, query: nil}), do: trimmed(path)
  defp served_path(_other), do: nil

  defp trimmed(path), do: path |> String.trim_trailing("/") |> root()

  defp root(""), do: "/"
  defp root(path), do: path

  defp ascii(nil), do: nil
  defp ascii(path), do: path |> String.split("/") |> Enum.map_join("/", &segment/1)

  defp segment(segment), do: segment(segment, String.match?(segment, ~r/\A[A-Za-z0-9_.-]*\z/))

  defp segment(segment, true), do: segment
  defp segment(segment, false), do: segment |> URI.decode() |> Slug.slugify()

  defp template(item, context),
    do:
      ~s(<div phx-no-curly-interpolation>) <>
        (item
         |> Item.html()
         |> Frames.playable(context)
         |> relinked(item.attrs["pages"])
         |> CmsMedia.relinked(item.attrs["media"], context)
         |> LazyHTML.from_fragment()
         |> LazyHTML.to_html()
         |> eex_free()) <>
        "</div>"

  defp eex_free(html), do: String.replace(html, "<%", "&lt;%")
end
