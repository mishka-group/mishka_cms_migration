# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(MishkaBlog.BlogPost) do
  defmodule MishkaCmsMigration.Targets.BlogPost do
    @moduledoc """
    The `"post"` items of a source written as the Blog's posts (`MishkaBlog.BlogPost`), through the
    `:create` and `:update` an admin's own post form runs, on the run's site and as the admin who
    pressed Import: the admin needs the Blog's `admin:dashboard:blog:post`, and the Blog's own rules
    decide the rest, such as how a slug is written (its slug change), how its content is sanitized and
    its code blocks highlighted.

    An item's title is the post's title, its `"slug"` the post's slug (its title for a draft
    WordPress left without one, and a generated one where the site's languages keep nothing of it,
    `MishkaCmsMigration.Targets.Helpers.BySlug.slug/4`), its content pieces, converted, the post's
    content (`MishkaCmsMigration.Source.Item.html/1`), its `"excerpt"` the post's excerpt (an empty
    one is none), and `"sticky"` makes it featured. A post is in the language the item names
    (a site that runs Polylang or WPML names one), joined as one group with the posts that are its
    other editions, whatever order they are imported in, or, for an item that names none, in the
    language the site leads with (`MishkaCmsMigration.Targets.Helpers.Editions`). An item in a
    language the site does not publish in waits for an admin's decision, and so does one whose
    language a source that runs a language plugin does not say, in the dry run too.

    ## Status and dates

    Its `"status"` and `"date_gmt"` (UTC) decide the post's:

      * `"publish"` — published, `published_at` the date;
      * `"future"` — scheduled, `scheduled_publish_at` the date;
      * `"draft"`, and any other — a draft, with neither.

    The Blog has no post pending review, private or behind a password, so `"pending"`, `"private"`
    and a post with a `"password"` (in its `extra`) are drafts, and the report says so for each
    (`note/2`: `"draft_from_pending"`, `"draft_from_private"`, `"draft_from_password"`), in the dry
    run too. When the post is created is when it is imported: the Blog's create sets it.

    ## Its author

    Its `"author"` is the blogger the same run, or an earlier one, wrote or connected for that user
    (`MishkaCmsMigration.Targets.BlogBlogger`), read from the item it was recorded as, and becomes
    the post's one author (its `blogger_ids`). An author with no blogger, one skipped for having no
    user of the site or never listed, leaves the post with none, and the import's report says so
    (`"author_missing"`); a dry run, which writes no blogger, does not.

    ## Categories and tags

    Its `"categories"` and `"tags"` are the Blog categories and tags the same run, or an earlier
    one, wrote for those ids (`MishkaCmsMigration.Targets.BlogCollection`,
    `MishkaCmsMigration.Targets.BlogTag`), read from the items they were recorded as; one that was
    never written is left out, and the post is still written. So is one an admin left out on the
    Items page (`MishkaCmsMigration.MigrationItem`'s `left_out`): the post is written without it,
    and so without an author an admin left out. One whose record an admin archived in the CMS, which
    the Blog would refuse to link, holds the post (`"waits_for: <kinds>"`) until the admin decides
    on it (`"archived_in_cms"`, `MishkaCmsMigration.Workers.Helpers.Decision`): Restore it, and the
    post is written with it, or Leave it archived, and the post is written without it. One whose
    record an admin deleted for good holds it the same way (`"deleted_in_cms"`): Import it again,
    and the post is written with the new record, or Leave it out, and the post is written without
    it, as the last import that met it left it, `"target_missing"`.

    Its author, categories, tags, featured file and the files of its content are what it needs
    (`needs/1`): Import this item writes a post alone only once each of them has a CMS record, or
    was left out or skipped, and it waits otherwise, where a full run, which writes them first,
    writes it without the one that failed.

    ## Links to other posts

    Its `"links"` name the links of its content that point at a post of the source, each by its
    `href` as written and the source's slug of the post it points at (the WordPress source finds
    them, `MishkaCmsMigration.Sources.WordPress`). Each such link points at that post's Blog
    address instead (`address/3`), its slug made as the Blog's create makes it
    (`MishkaCmsMigration.Targets.Helpers.BySlug.slug/4`) in the post's own language, and
    keeps its `#fragment`: `http://old.example/2025/12/hello/#more` becomes `/blog/hello#more`.
    It is the address the run writes the post at, so a post that links to one listed after it
    points at it too. Its `"pages"` name the links of its content that point at a page of the
    source, and each points at the path that page is written at instead, keeping its `?query` and
    `#fragment` (`MishkaCmsMigration.Targets.CmsPage.relinked/3`): `http://old.example/contact/` is
    `/contact`, or `/contact-29` once an admin decided to import that page as new beside the
    site's own. Any other link is kept as it is: a category, a file, an outside site, a post or
    page the source no longer has, or a post an admin left out, found by the slug its item recorded
    (`MishkaCmsMigration.MigrationItem`'s `source_slug`), which keeps its old address.

    ## Its pictures and files

    Its `"featured_media"` is the file the same run, or an earlier one, wrote to the CMS's Media for
    that id (`MishkaCmsMigration.Targets.CmsMedia`), and the file's address becomes the post's
    featured image (its `featured_image_url`). A post whose featured file was never written, such
    as an SVG or one that failed, is written with none, and the import's report says so
    (`"featured_image_missing"`); a dry run, which writes no file, does not.

    Its `"media"` name the addresses of its content that are files of the source, and each `src`,
    `href`, video `poster` and `srcset` candidate of them points at the file's Media address
    instead (`MishkaCmsMigration.Targets.CmsMedia.relinked/3`), a size WordPress made of a file too:
    `.../uploads/2026/11/hero-300x169.jpg` is the address of the stored `hero.jpg`. The address of a
    file that was not written is kept as it is, and an `srcset` candidate of one is named in the
    report (`"srcset_file_missing"`).

    ## Its SEO

    Its `"seo"`, what Yoast SEO or Rank Math kept for it (the WordPress source reads it), is the
    post's `seo_tags` (`MishkaCmsMigration.Targets.Helpers.SeoTags`): its title, description,
    robots, share image, a canonical address on another site, and the social and Twitter title,
    description, image and card when they say something else than the page's own (see the helper).
    A share image that is the post's
    featured image is left out: the post's page then shows the core's share card, which draws the
    featured image with the post's title, where a stored `og:image` would replace the card. The
    WordPress REST API cannot tell Yoast's chosen image from its fallback to the featured image.

    ## Its videos

    A YouTube or Vimeo player its content frames (the WordPress source makes one of each embed) is
    allowed on the site before the post is written, in an import only, as the admin
    (`MishkaCmsMigration.Targets.Helpers.Frames`), and the report names them
    (`"frames_allowed: <origins>"`), in the dry run too. For an admin who may not change the site's
    settings the post waits for an admin's decision (`"player_not_allowed"`), in the dry run too
    (`waiting/2`), also a post an earlier import wrote: Wait for an admin keeps it for a run by one
    who may, and Import without the player writes it with that player left out
    (`"player_left_out"`). The Blog keeps an `<iframe>`'s address, title and size, and
    leaves out its other attributes, such as `allowfullscreen`.

    ## Its scripts

    A post whose content holds a `<script>` or an inline event handler (`onclick`, `onerror`, ...)
    waits for an admin's decision (`"scripts: <found>"`,
    `MishkaCmsMigration.Targets.Helpers.Scripts`), in the dry run too: Remove them writes it
    without them (`"scripts_removed: <found>"`), and Keep them (I trust this content) hands it to
    the Blog as it is (`"scripts_kept: <found>"`), whose own sanitizer still decides what a post
    keeps.

    ## Its Elementor layout

    A post laid out with Elementor arrives as the Blog's HTML
    (`MishkaCmsMigration.Sources.WordPress.Elementor`). One with widgets the CMS has no equivalent
    for, such as a form, a slider or a map, waits for an admin's decision
    (`"unsupported_widgets: <names>"`, `MishkaCmsMigration.Targets.Helpers.Widgets`), in the dry
    run too (`waiting/2`), also a post an earlier import wrote: Import with the fallback HTML for
    those parts writes it with what Elementor drew for them (`"fallback_html: <names>"`, and
    `"no_fallback: <names>"` for those it drew nothing for), and Leave the page out leaves it out.

    Defined only where Mishka Blog is loaded, and supervised by `MishkaCmsMigration.Application`
    only then; on a node without the Blog its items wait for it (`"blog_missing"`).
    """

    use MishkaCmsMigration.Target,
      kind: "post",
      resource: MishkaBlog.BlogPost,
      create: :create,
      update: :update

    alias MishkaBlog.Provision
    alias MishkaCmsCore.Runtime.Languages
    alias MishkaCmsMigration.Source.Item
    alias MishkaCmsMigration.Targets.{CmsMedia, CmsPage}

    alias MishkaCmsMigration.Targets.Helpers.{
      BySlug,
      ContentChecks,
      Editions,
      Frames,
      Scripts,
      SeoTags,
      Status,
      Widgets
    }

    @drafted ["pending", "private", "password"]

    @impl MishkaCmsMigration.Target
    def attrs(item, context) do
      language = Editions.language(item, context)

      item
      |> Status.call()
      |> dated(date(item.attrs["date_gmt"]))
      |> Map.merge(Editions.attrs(item, context, MishkaBlog.BlogPost))
      |> Map.merge(%{
        title: item.title,
        slug: BySlug.slug(__MODULE__, slug(item), language, context),
        content:
          item
          |> Item.html()
          |> Scripts.removed(item, context)
          |> Frames.playable(context)
          |> relinked(item.attrs["links"], {language, context})
          |> CmsPage.relinked(item.attrs["pages"], context)
          |> CmsMedia.relinked(item.attrs["media"], context),
        excerpt: excerpt(item.attrs["excerpt"]),
        featured_image_url: featured_image(item, context),
        seo_tags: SeoTags.call(item, context, item.attrs["featured_media"]),
        featured: item.attrs["sticky"] == true,
        collection_ids: written(context, "category", item.attrs["categories"]),
        tag_ids: written(context, "tag", item.attrs["tags"]),
        blogger_ids: written(context, "user", item.attrs["author"])
      })
    end

    @doc """
    Where the Blog serves a post with `slug` in `language` on the site `site_id`: the path of its
    post page (`MishkaBlog.Provision.item_paths/0`) as the site's own address
    (`MishkaCmsCore.Runtime.Languages.url/3`), `/blog/<slug>` in the language the site leaves
    unprefixed and `/fa/blog/<slug>` in Persian. `nil` for no slug, and for a language the site does
    not publish in.
    """
    @spec address(String.t() | nil, String.t(), String.t()) :: String.t() | nil
    def address(slug, language, site_id),
      do:
        Languages.url(
          Provision.item_paths().post,
          %{Languages.capture() => language, "slug" => slug},
          site_id
        )

    @impl MishkaCmsMigration.Target
    def needs(%Item{attrs: attrs}),
      do: %{
        "user" => ids(attrs["author"]),
        "category" => ids(attrs["categories"]),
        "tag" => ids(attrs["tags"]),
        "media" => ids([attrs["featured_media"] | Map.values(attrs["media"] || %{})])
      }

    defp ids(ids),
      do:
        for(
          id <- List.wrap(ids),
          (is_integer(id) and id > 0) or (is_binary(id) and id not in ["", "0"]),
          uniq: true,
          do: to_string(id)
        )

    @impl MishkaCmsMigration.Target
    def prepare(item, context, write),
      do:
        with(
          :ok <- ContentChecks.call(item, context),
          do: Editions.lead(item, context, __MODULE__, write)
        )

    @impl MishkaCmsMigration.Target
    def waiting(item, context), do: ContentChecks.waiting(item, context)

    @impl MishkaCmsMigration.Target
    def note(item, context) do
      [
        Editions.note(item, context),
        item |> Status.call() |> drafted(),
        BySlug.note(__MODULE__, item, context),
        authored(item, context),
        pictured(item, context),
        Widgets.note(item, context),
        Scripts.note(item, context),
        CmsMedia.srcset_note(item, context),
        Frames.note(item, context)
      ]
      |> Enum.reject(&is_nil/1)
      |> noted()
    end

    defp dated("publish", date),
      do: %{status: :published, published_at: date, scheduled_publish_at: nil}

    defp dated("future", date),
      do: %{status: :scheduled, published_at: nil, scheduled_publish_at: date}

    defp dated(_draft, _date), do: %{status: :draft, published_at: nil, scheduled_publish_at: nil}

    defp drafted(status) when status in @drafted, do: "draft_from_" <> status
    defp drafted(_status), do: nil

    defp authored(_item, %{mode: :dry_run}), do: nil
    defp authored(item, context), do: context |> written("user", item.attrs["author"]) |> author()

    defp author([]), do: "author_missing"
    defp author(_bloggers), do: nil

    defp pictured(_item, %{mode: :dry_run}), do: nil

    defp pictured(%Item{attrs: %{"featured_media" => id}} = item, context)
         when is_integer(id) and id > 0,
         do: item |> featured_image(context) |> picture()

    defp pictured(_item, _context), do: nil

    defp picture(nil), do: "featured_image_missing"
    defp picture(_address), do: nil

    defp featured_image(%Item{attrs: %{"featured_media" => id}}, context)
         when is_integer(id) and id > 0,
         do: [id] |> CmsMedia.addresses(context) |> Map.get(to_string(id))

    defp featured_image(_item, _context), do: nil

    defp noted([]), do: nil
    defp noted(notes), do: Enum.join(notes, "; ")

    defp date(gmt) when is_binary(gmt),
      do: gmt |> NaiveDateTime.from_iso8601!() |> DateTime.from_naive!("Etc/UTC")

    defp date(_none), do: nil

    defp slug(%Item{attrs: %{"slug" => slug}}) when is_binary(slug) and slug != "", do: slug
    defp slug(%Item{title: title}), do: title

    defp excerpt(""), do: nil
    defp excerpt(excerpt), do: excerpt

    defp relinked(html, links, {_language, context} = to)
         when is_map(links) and map_size(links) > 0,
         do: links |> Map.drop(left_out_links(links, context)) |> relinked_to(html, to)

    defp relinked(html, _no_links, _to), do: html

    defp relinked_to(links, html, _to) when map_size(links) == 0, do: html

    defp relinked_to(links, html, to),
      do:
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.to_tree()
        |> LazyHTML.Tree.postwalk(&relink(&1, links, to))
        |> LazyHTML.Tree.to_html()

    defp left_out_links(links, context) do
      left_out =
        context.source_host
        |> MishkaCmsMigration.left_out_items_by_slugs!(
          "post",
          links |> Map.values() |> Enum.uniq(),
          actor: context.actor,
          tenant: context.site_id
        )
        |> MapSet.new(& &1.source_slug)

      for {href, slug} <- links, MapSet.member?(left_out, slug), do: href
    end

    defp relink({"a", attributes, children}, links, to),
      do: {"a", Enum.map(attributes, &href(&1, links, to)), children}

    defp relink(node, _links, _to), do: node

    defp href({"href", old}, links, to) when is_map_key(links, old),
      do: {"href", links |> Map.fetch!(old) |> slug_address(to) |> anchored(old)}

    defp href(attribute, _links, _to), do: attribute

    defp slug_address(slug, {language, context}),
      do: __MODULE__ |> BySlug.slug(slug, language, context) |> address(language, context.site_id)

    defp anchored(nil, old), do: old
    defp anchored(new, old), do: old |> URI.parse() |> fragment(new)

    defp fragment(%URI{fragment: fragment}, new) when is_binary(fragment) and fragment != "",
      do: new <> "#" <> fragment

    defp fragment(_uri, new), do: new

    defp written(context, kind, ids),
      do:
        context.source_host
        |> MishkaCmsMigration.items_by_sources!(kind, Enum.map(List.wrap(ids), &to_string/1),
          actor: context.actor,
          tenant: context.site_id
        )
        |> Enum.flat_map(&target_id/1)

    defp target_id(%{reason: "target_missing"}), do: []
    defp target_id(%{target_id: id, left_out: false}) when is_binary(id), do: [id]
    defp target_id(_never_written_left_out_or_deleted), do: []
  end
end
