# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(MishkaBlog.BlogPost) do
  defmodule MishkaCmsMigration.Targets.BlogPost do
    @moduledoc """
    The `"post"` items of a source written as the Blog's posts (`MishkaBlog.BlogPost`), through the
    `:create` and `:update` an admin's own post form runs, on the run's site and as the admin who
    pressed Import: the admin needs the Blog's `admin:dashboard:blog:post`, and the Blog's own rules
    decide the rest, such as how a slug is written (its `slugify`), how its content is sanitized and
    its code blocks highlighted.

    An item's title is the post's title, its `"slug"` the post's slug (its title for a draft
    WordPress left without one), its content pieces, converted, the post's content
    (`MishkaCmsMigration.Source.Item.html/1`), its `"excerpt"` the post's excerpt (an empty one is
    none), and `"sticky"` makes it featured. A post is in the language the site leads with
    (`MishkaCmsCore.Runtime.Languages.primary/1`): a WordPress post has no language of its own.

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
    never written is left out, and the post is still written.

    ## Links to other posts

    Its `"links"` name the links of its content that point at a post of the source, each by its
    `href` as written and the source's slug of the post it points at (the WordPress source finds
    them, `MishkaCmsMigration.Sources.WordPress`). Each such link points at that post's Blog
    address instead (`address/3`), its slug made as the Blog's create makes it
    (`MishkaCmsMigration.Targets.Helpers.BySlug.slug/2`) in the language the site leads with, and
    keeps its `#fragment`: `http://old.example/2025/12/hello/#more` becomes `/blog/hello#more`.
    It is the address the run writes the post at, so a post that links to one listed after it
    points at it too. Any other link is kept as it is: a page, a category, a file, an outside
    site, or a post the source no longer has.

    ## Left for later

    Its featured image (`"featured_media"`) and the images in its content keep their WordPress
    addresses until the media are moved (mishka_cms_migration#7).

    Defined only where Mishka Blog is loaded, and supervised by `MishkaCmsMigration.Application`
    only then; on a site without the Blog its kind is skipped as `"no_target"`.
    """

    use MishkaCmsMigration.Target,
      kind: "post",
      resource: MishkaBlog.BlogPost,
      create: :create,
      update: :update

    alias MishkaBlog.Provision
    alias MishkaCmsCore.Runtime.Languages
    alias MishkaCmsMigration.Source.Item
    alias MishkaCmsMigration.Targets.Helpers.BySlug

    @drafted ["pending", "private", "password"]

    @impl MishkaCmsMigration.Target
    def attrs(item, context) do
      item
      |> status()
      |> dated(date(item.attrs["date_gmt"]))
      |> Map.merge(%{
        title: item.title,
        slug: slug(item),
        content: item |> Item.html() |> relinked(item.attrs["links"], context),
        excerpt: excerpt(item.attrs["excerpt"]),
        featured: item.attrs["sticky"] == true,
        language: Languages.primary(context.site_id),
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
    def note(item, context) do
      [item |> status() |> drafted(), authored(item, context)]
      |> Enum.reject(&is_nil/1)
      |> noted()
    end

    defp status(%Item{extra: %{"password" => password}})
         when is_binary(password) and password != "",
         do: "password"

    defp status(%Item{attrs: attrs}), do: attrs["status"]

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

    defp noted([]), do: nil
    defp noted(notes), do: Enum.join(notes, "; ")

    defp date(gmt) when is_binary(gmt),
      do: gmt |> NaiveDateTime.from_iso8601!() |> DateTime.from_naive!("Etc/UTC")

    defp date(_none), do: nil

    defp slug(%Item{attrs: %{"slug" => slug}}) when is_binary(slug) and slug != "", do: slug
    defp slug(%Item{title: title}), do: title

    defp excerpt(""), do: nil
    defp excerpt(excerpt), do: excerpt

    defp relinked(html, links, context) when is_map(links) and map_size(links) > 0,
      do:
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.to_tree()
        |> LazyHTML.Tree.postwalk(&relink(&1, links, context))
        |> LazyHTML.Tree.to_html()

    defp relinked(html, _no_links, _context), do: html

    defp relink({"a", attributes, children}, links, context),
      do: {"a", Enum.map(attributes, &href(&1, links, context)), children}

    defp relink(node, _links, _context), do: node

    defp href({"href", old}, links, context) when is_map_key(links, old),
      do: {"href", links |> Map.fetch!(old) |> slug_address(context) |> anchored(old)}

    defp href(attribute, _links, _context), do: attribute

    defp slug_address(slug, context),
      do:
        __MODULE__
        |> BySlug.slug(slug)
        |> address(Languages.primary(context.site_id), context.site_id)

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

    defp target_id(%{target_id: id}) when is_binary(id), do: [id]
    defp target_id(_never_written), do: []
  end
end
