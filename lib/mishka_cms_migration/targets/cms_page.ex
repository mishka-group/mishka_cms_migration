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
  site already has, such as the site's home at `/`, is left as it is and skipped (`"path_taken"`),
  also when the site's page is not live; nothing is ever written over a page an admin made. A page
  under a skipped page is skipped too, as the walk does for any item whose parent was not imported
  (`"parent_missing"`).

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

  Its `"media"` name the addresses of its content that are files of the source, and each `src`
  and `href` of them points at the Media address of the file the same run, or an earlier one,
  wrote for it (`MishkaCmsMigration.Targets.CmsMedia.relinked/3`), a size WordPress made of a file
  too. The address of a file that was not written is kept as it is, and so is every other link: a
  page's links to posts and pages keep the addresses WordPress gave them.
  """

  use MishkaCmsMigration.Target,
    kind: "page",
    resource: MishkaCmsCore.Runtime.Page,
    create: :create,
    update: :update

  require Ash.Query

  alias MishkaCmsCore.Runtime.{Languages, Page, SiteLayout}
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Targets.CmsMedia
  alias MishkaCmsMigration.Targets.Helpers.{Read, Status}

  @drafted ["pending", "private", "password", "future"]

  @impl MishkaCmsMigration.Target
  def attrs(item, context) do
    %{
      title: item.title,
      path: path(item),
      template: template(item, context),
      active: active?(item, context),
      language: Languages.primary(context.site_id),
      layout_id: SiteLayout.layout_id(context.site_id)
    }
  end

  @impl MishkaCmsMigration.Target
  def existing(items, context) do
    paired = for item <- items, path = path(item), do: {item, path}
    taken = paired |> Enum.map(&elem(&1, 1)) |> taken(context)

    for {item, path} <- paired, path in taken, into: %{} do
      {item.source_id, {:skipped, "path_taken"}}
    end
  end

  @impl MishkaCmsMigration.Target
  def note(item, _context),
    do: [item |> Status.call() |> drafted(), moved(item)] |> Enum.reject(&is_nil/1) |> noted()

  defp taken([], _context), do: MapSet.new()

  defp taken(paths, context),
    do:
      Page
      |> Ash.Query.filter(path in ^paths)
      |> Read.call(context)
      |> MapSet.new(& &1.path)

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
         |> CmsMedia.relinked(item.attrs["media"], context)
         |> LazyHTML.from_fragment()
         |> LazyHTML.to_html()
         |> eex_free()) <>
        "</div>"

  defp eex_free(html), do: String.replace(html, "<%", "&lt;%")
end
