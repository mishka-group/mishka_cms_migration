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
        (`MishkaBlog.Address.of/3`), the post with its date, number and first category and the
        category with its chain of parents where its page names them: `/blog/hello`,
        `/2025/12/hello` on a site that keeps WordPress's addresses, `/fa/blog/salam` in Persian;
        an author with no blogger on the site, such as one the admin chose to connect by an email
        no user has, at the Blog's list of posts;
      * a page — at its path;
      * a file — at its Media address (`MishkaCmsMigration.Targets.CmsMedia.addresses/2`);
      * `"list"`, the feeds, the date archives and the pages of the front's list — at the Blog's list
        of posts (`MishkaCmsMigration.Targets.Helpers.BlogPages.list_address/1`); the Blog has no
        feed and no date archive;
      * `"sitemap"`, WordPress's sitemaps — at the site's own `/sitemap.xml`.

    An item whose `"to"` names a `"page"` (`/category/news/page/2`) is sent to that page of the
    list, `?page=2`.

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
        * one whose post has no Blog post — it failed, was never written or an admin left it out
          — skipped as `"post_missing"`, and one whose category, tag, page or file has no record,
          as `"not_imported"`;
        * one whose record no visitor can open at an address — a post that is not published, such
          as one behind a password at the source, an inactive page or category, or a record the
          site has no page for — skipped as `"not_served"`: a redirect is never written to an
          address that does not answer;
        * in an import, one the site serves at the same address already, such as a post whose
          WordPress address its kept address is — skipped as `"same_address"`. So a post the
          site serves elsewhere than WordPress did, a date written in another timezone or a
          category under a parent (`/tutorials/news/hello` where the Blog's `:category` is the
          post's own category, `/news/hello`), is redirected without a rule of its own.

    A dry run reads the records an earlier run wrote, as the import does, and the plans it recorded
    for the items it walked before this kind, so it says what the import will do: an item whose
    record it plans to write is planned as created (skipped as `"not_served"` when it writes it as
    a draft, as it writes every page unless the run's `pages` is `"publish"`), and one whose record it does not is skipped as the import skips it. A record it plans
    to write has no address yet, so with `"keep"` and a permalink structure the source's posts
    share, the post's, category's or tag's own WordPress address is planned as `"same_address"`:
    the import serves the record there. A record in a language the site serves under a prefix
    (`MishkaCmsCore.Runtime.Languages.url/3`, `/fa`), whose WordPress address does not start with
    it, such as an export's Persian term at `/category/safar/`, is served under its language
    (`/fa/category/safar`) and redirected after all: its language is the one the item's `"to"`
    names, else the one the import writes it in
    (`MishkaCmsMigration.Targets.Helpers.Editions.language/2`).

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

    alias MishkaBlog.{Address, Blogger, BlogPost, Collection, Tag}
    alias MishkaCmsCore.Runtime.{Languages, Page, Redirects}
    alias MishkaCmsMigration.Targets.CmsMedia
    alias MishkaCmsMigration.Targets.Helpers.{BlogPages, Editions, Written}

    @sitemap "/sitemap.xml"

    @written %{
      "post" => {BlogPost, "post"},
      "category" => {Collection, "category"},
      "tag" => {Tag, "tag"},
      "user" => {Blogger, "user"},
      "page" => {Page, "page"}
    }

    @written_kinds Map.keys(@written) ++ ["media"]

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
        to: [item] |> addresses(context) |> Map.get(to(item)) |> paged(item),
        status: 301
      }
    end

    defp found(%{attrs: %{"from" => "/" <> _}} = item, addresses, context),
      do: addresses |> Map.get(to(item)) |> paged(item) |> moved(item, context)

    defp found(_no_old_address, _addresses, _context), do: {:skipped, "no_old_address"}

    defp moved(:not_served, _item, _context), do: {:skipped, "not_served"}

    defp moved(:planned, item, %{mode: :dry_run} = context),
      do: (own_address?(item) and kept?(context) and prefixed?(item, context)) |> kept_planned()

    defp moved(nil, %{attrs: %{"to" => %{"kind" => "post"}}}, _context),
      do: {:skipped, "post_missing"}

    defp moved(nil, _item, _context), do: {:skipped, "not_imported"}
    defp moved(to, %{attrs: %{"query" => nil, "from" => from}}, _context), do: unmoved(from, to)
    defp moved(_to, _queried, _context), do: nil

    defp kept_planned(true), do: {:skipped, "same_address"}
    defp kept_planned(false), do: nil

    # A post's, a category's or a tag's own WordPress address, which a run that keeps the source's
    # addresses serves the record at.
    defp own_address?(%{
           source_id: id,
           attrs: %{"query" => nil, "to" => %{"kind" => "post", "id" => id}}
         }),
         do: true

    defp own_address?(%{
           source_id: key,
           attrs: %{"query" => nil, "to" => %{"kind" => kind, "id" => id}}
         })
         when kind in ["category", "tag"],
         do: key == kind <> ":" <> id

    defp own_address?(_item), do: false

    defp kept?(%{
           options: %{post_address: "keep", blog_pages: "use"},
           permalinks: %{"pattern" => "/" <> _}
         }),
         do: true

    defp kept?(_context), do: false

    # Whether the WordPress address starts with the prefix the site serves the record's language
    # under, which it holds for a language served with none.
    defp prefixed?(%{attrs: %{"from" => from, "to" => to}} = item, context) do
      language = Editions.language(%{item | attrs: %{"language" => to["language"]}}, context)

      ("/:" <> Languages.capture())
      |> Languages.url(%{Languages.capture() => language}, context.site_id)
      |> served_prefix(language)
      |> under_prefix?(Redirects.normalize_path(from))
    end

    defp served_prefix(nil, language), do: "/" <> language
    defp served_prefix(prefix, _language), do: prefix

    defp under_prefix?("/", _from), do: true

    defp under_prefix?(prefix, {:ok, from}),
      do: from == prefix or String.starts_with?(from, prefix <> "/")

    defp under_prefix?(_prefix, _from), do: false

    defp unmoved(from, to),
      do: from |> Redirects.normalize_path() |> same(Redirects.normalize_path(to))

    defp same({:ok, path}, {:ok, path}), do: {:skipped, "same_address"}
    defp same(_from, _to), do: nil

    defp to(%{attrs: %{"to" => %{"kind" => kind, "id" => id}}}), do: {kind, id}
    defp to(_item), do: nil

    # The page of a list an address names (`/category/news/page/2`), as the list's pager asks for it.
    defp paged(address, %{attrs: %{"to" => %{"page" => page}}})
         when is_binary(address) and is_integer(page),
         do: address <> "?page=" <> Integer.to_string(page)

    defp paged(address, _item), do: address

    # WHERE THE SITE SERVES WHAT EACH ITEM POINTS AT, by `{kind, id}`: one read of the records of each
    # kind the items point at, in a dry run too, where a record an earlier run wrote is found.
    # `:not_served` for a record no visitor can open there, and in a dry run `:planned` for one its
    # walk of that kind plans to write (`:not_served` again for one it writes as a draft), read in one
    # more query of the kind's items.
    defp addresses(items, context) do
      items
      |> Enum.flat_map(&List.wrap(to(&1)))
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.flat_map(fn {kind, ids} ->
        ids = Enum.uniq(ids)
        served = served(kind, ids, context)
        served ++ planned(kind, ids -- for({{_kind, id}, _to} <- served, do: id), context)
      end)
      |> Map.new()
    end

    defp planned(kind, missing, %{mode: :dry_run} = context) when kind in @written_kinds,
      do:
        for(
          {id, reason} <- Written.planned(kind, missing, context),
          do: {{kind, id}, planned_served(kind, reason, context)}
        )

    defp planned(_kind, _missing, _context), do: []

    # A record the walk plans to write as a draft (`"draft_from_password"`), and any page a run that
    # does not publish its pages writes, will not be served.
    defp planned_served("page", reason, %{options: %{pages: "publish"}}),
      do: draft_planned(reason)

    defp planned_served("page", _reason, _draft_pages), do: :not_served
    defp planned_served(_kind, reason, _context), do: draft_planned(reason)

    defp draft_planned(reason),
      do: reason |> to_string() |> String.contains?("draft_from_") |> drafted()

    defp drafted(true), do: :not_served
    defp drafted(false), do: :planned

    defp served("list", _ids, context),
      do: [{{"list", nil}, BlogPages.list_address(context.site_id)}]

    defp served("sitemap", _ids, _context), do: [{{"sitemap", nil}, @sitemap}]

    defp served("media", ids, context),
      do: for({id, path} <- CmsMedia.addresses(ids, context), do: {{"media", id}, path})

    # AN AUTHOR WITH NO BLOGGER ON THE SITE, as when the admin connected the authors to users by
    # email and none matched, is sent to the list of posts.
    defp served("user", ids, context) do
      found = written("user", ids, context)
      list = BlogPages.list_address(context.site_id)

      for id <- ids, do: {{"user", id}, Map.get(found, id, list)}
    end

    defp served(kind, ids, context) when is_map_key(@written, kind),
      do: for({id, address} <- written(kind, ids, context), do: {{kind, id}, address})

    defp served(_kind, _ids, _context), do: []

    defp written(kind, ids, context) do
      {resource, written} = Map.fetch!(@written, kind)

      for {id, record} <- Written.call(read(resource), written, ids, context),
          into: %{},
          do: {id, address(record, context.site_id)}
    end

    defp read(BlogPost), do: Ash.Query.load(BlogPost, :first_category_slug)
    defp read(Collection), do: Ash.Query.load(Collection, :slug_path)
    defp read(resource), do: resource

    defp address(%BlogPost{status: status}, _site_id) when status != :published, do: :not_served
    defp address(%Collection{status: status}, _site_id) when status != :active, do: :not_served
    defp address(%Page{active: false}, _site_id), do: :not_served

    defp address(%Page{path: path, language: language}, site_id),
      do:
        Languages.url(
          path,
          %{Languages.capture() => language || Languages.primary(site_id)},
          site_id
        ) || :not_served

    defp address(%Blogger{} = blogger, site_id),
      do: Address.of(blogger, site_id, Languages.primary(site_id)) || :not_served

    defp address(record, site_id), do: Address.of(record, site_id) || :not_served
  end
end
