# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(MishkaBlog.BlogPost) do
  defmodule MishkaCmsMigration.Targets.PostRedirect do
    @moduledoc """
    The `"post_redirect"` items of a source, each an address a visitor or search engine knows
    (`MishkaCmsMigration.Sources.WordPress.Addresses`), written as the CMS's own redirect rules
    (`MishkaCmsCore.Runtime.Redirect`), through the `:create` and `:update` an admin's own redirect
    form runs, on the run's site and as the admin who pressed Import: the admin needs the core's
    `admin:dashboard:runtime:redirect`, and the core's own rules decide the rest, such as how an
    address is stored and that one site redirects an address once.

    An item's `"from"` is the address, such as `/2025/12/hello/`, with its `"query"` when it is one
    only with a query (`p=35` on `/`, `from_query`), and its `"to"` what it points at. The rule sends
    it, with a 301, to where the site serves that, as the same run or an earlier one wrote it:

      * a post, a category, a tag and an author (`"user"`) — at the address its Blog page gives it
        (`MishkaBlog.Address.of/3`), or the Blog's own one on a site with no such page
        (`MishkaBlog.Provision.item_paths/0`), the post with its date, number and first category: `/blog/hello`,
        `/2025/12/hello` on a site that keeps WordPress's addresses, `/fa/blog/salam` in Persian;
      * a page — at its path;
      * a file — at its Media address (`MishkaCmsMigration.Targets.CmsMedia.addresses/2`);
      * `"list"`, the feeds and date archives — at the Blog's list of posts
        (`MishkaCmsMigration.Targets.Helpers.BlogPages.list_address/1`); the Blog has no feed and no
        date archive.

    The records are read once a page, one query for the items and one for the records of each kind
    the page points at.

    ## Which items

    By the run's `post_address` choice (`MishkaCmsMigration.MigrationRun`'s options), read with
    `existing/2` before anything is written, in the dry run too:

      * `"blog_without_redirects"` — every item is skipped as `"not_chosen"`, and no rule is
        written;
      * `"keep"` (the default) and `"blog"` — a rule is written for each item, except:
        * one the source gives no address (`"from"` is `nil`, such as a draft's) — skipped as
          `"no_old_address"`;
        * in an import, one whose post has no Blog post — it failed, was never written or an admin
          left it out — skipped as `"post_missing"`, and one whose category, tag, author, page or
          file has no record, as `"not_imported"`;
        * in an import, one the site serves at the same address already, such as a post whose
          WordPress address its kept address is — skipped as `"same_address"`. So a post the
          site serves elsewhere than WordPress did, a date written in another timezone or a
          category under a parent (`/tutorials/news/hello` where the Blog's `:category` is the
          post's own category, `/news/hello`), is redirected without a rule of its own.

    A dry run writes no post, so it does not look for one: an item it plans may still be skipped
    for its post when the import runs.

    An old address the site already redirects, by a rule of an admin's own or of another source's
    run, is refused by the core's one-rule-per-address identity, and the item fails with the core's
    reason; the site's rule is kept as it is.

    A re-run is held to the rules every target is: a rule WordPress did not change is
    `"unchanged"`, and one an admin edited or deleted in the CMS is kept as the admin left it
    (`MishkaCmsMigration.Workers.Helpers.Decision`). Switching the choice off later leaves the
    rules an earlier run wrote.

    Defined only where Mishka Blog is loaded, and supervised by `MishkaCmsMigration.Application`
    only then; on a node without the Blog its items wait for it (`"blog_missing"`).
    """

    use MishkaCmsMigration.Target,
      kind: "post_redirect",
      resource: MishkaCmsCore.Runtime.Redirect,
      create: :create,
      update: :update

    alias MishkaBlog.{Address, Blogger, BlogPost, Collection, Provision, Tag}
    alias MishkaCmsCore.Runtime.{Languages, Page, Redirects}
    alias MishkaCmsMigration.Targets.CmsMedia
    alias MishkaCmsMigration.Targets.Helpers.{BlogPages, Written}

    @written %{
      "post" => {BlogPost, "post"},
      "category" => {Collection, "category"},
      "tag" => {Tag, "tag"},
      "user" => {Blogger, "user"},
      "page" => {Page, "page"}
    }

    @impl MishkaCmsMigration.Target
    def existing(items, %{options: %{post_address: "blog_without_redirects"}}),
      do: Map.new(items, &{&1.source_id, {:skipped, "not_chosen"}})

    def existing(items, context) do
      addresses = addresses(items, context)

      for item <- items,
          found = found(item, addresses, context),
          into: %{},
          do: {item.source_id, found}
    end

    @impl MishkaCmsMigration.Target
    def attrs(item, context) do
      %{
        from_path: item.attrs["from"],
        from_query: item.attrs["query"],
        to: [item] |> addresses(context) |> Map.get(to(item)),
        status: 301
      }
    end

    defp found(%{attrs: %{"from" => "/" <> _}} = item, addresses, context),
      do: planned(item, addresses, context)

    defp found(_no_old_address, _addresses, _context), do: {:skipped, "no_old_address"}

    defp planned(_item, _addresses, %{mode: :dry_run}), do: nil

    defp planned(item, addresses, _context),
      do: addresses |> Map.get(to(item)) |> moved(item)

    defp moved(nil, %{attrs: %{"to" => %{"kind" => "post"}}}), do: {:skipped, "post_missing"}
    defp moved(nil, _item), do: {:skipped, "not_imported"}
    defp moved(to, %{attrs: %{"query" => nil, "from" => from}}), do: unmoved(from, to)
    defp moved(_to, _queried), do: nil

    defp unmoved(from, to),
      do: from |> Redirects.normalize_path() |> same(Redirects.normalize_path(to))

    defp same({:ok, path}, {:ok, path}), do: {:skipped, "same_address"}
    defp same(_from, _to), do: nil

    defp to(%{attrs: %{"to" => %{"kind" => kind, "id" => id}}}), do: {kind, id}
    defp to(_item), do: nil

    # WHERE THE SITE SERVES WHAT EACH ITEM POINTS AT, by `{kind, id}`: one read of the records of each
    # kind the items point at, none in a dry run.
    defp addresses(_items, %{mode: :dry_run}), do: %{}

    defp addresses(items, context) do
      items
      |> Enum.flat_map(&List.wrap(to(&1)))
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.flat_map(fn {kind, ids} -> served(kind, Enum.uniq(ids), context) end)
      |> Map.new()
    end

    defp served("list", _ids, context),
      do: [{{"list", nil}, BlogPages.list_address(context.site_id)}]

    defp served("media", ids, context),
      do: for({id, path} <- CmsMedia.addresses(ids, context), do: {{"media", id}, path})

    defp served(kind, ids, context) when is_map_key(@written, kind) do
      {resource, written} = Map.fetch!(@written, kind)

      for {id, record} <- Written.call(read(resource), written, ids, context),
          address = address(record, context.site_id),
          do: {{kind, id}, address}
    end

    defp served(_kind, _ids, _context), do: []

    defp read(BlogPost), do: Ash.Query.load(BlogPost, :first_category_slug)
    defp read(resource), do: resource

    defp address(%Page{path: path, language: language}, site_id),
      do:
        Languages.url(
          path,
          %{Languages.capture() => language || Languages.primary(site_id)},
          site_id
        )

    defp address(%Blogger{} = blogger, site_id),
      do: at_page(blogger, site_id, Languages.primary(site_id))

    defp address(record, site_id), do: at_page(record, site_id, nil)

    # A site with no page for the kind yet, one the Blog's pages were never set up on, is given the
    # Blog's own address for it.
    defp at_page(record, site_id, language),
      do:
        Address.of(record, site_id, language) ||
          Address.fill(default_path(record), record, site_id, language)

    defp default_path(%BlogPost{}), do: Provision.item_paths().post
    defp default_path(%Collection{}), do: Provision.item_paths().category
    defp default_path(%Tag{}), do: Provision.item_paths().tag
    defp default_path(%Blogger{}), do: Provision.item_paths().author
  end
end
