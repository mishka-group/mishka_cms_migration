# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(MishkaBlog.Address) do
  defmodule MishkaCmsMigration.Targets.Helpers.BlogPages do
    @moduledoc """
    The site's Blog pages a run puts in place, before an import writes any post, category, tag or
    author (`MishkaCmsMigration.Targets.BlogPost`'s `before_import/1`): it moves the ones the site
    has and creates the ones it is missing, so the Blog serves posts, categories, tags, authors and
    its list of posts where the run wants them.

    The Blog serves each kind of row at the page whose `extra` names it (`"blog:post"`,
    `"blog:category"`, `"blog:tag"`, `"blog:author"`, `"blog:team"`, `"blog:people"`,
    `"blog:home"`, `MishkaBlog.Address`); the categories and tags pages name none and are found at
    their paths (`MishkaBlog.Provision.places/0`). Where each goes follows the run's choices:

      * `blog_pages` `"use"` (the default) moves the pages the site has and creates the missing ones
        at the paths below. `"create"` creates the missing ones at the Blog's default paths
        (`MishkaBlog.Provision.page_paths/0`) and moves none, so the source's addresses reach
        them through the redirects (`MishkaCmsMigration.Targets.PostRedirect`);
      * with `"use"`, `post_address` `"keep"` and a structure the source's posts share
        (`permalinks`' `"pattern"`), the post page's path is that pattern behind the language
        (`/:lang/:year/:monthnum/:slug`), and the category, tag and author pages' are the source's
        bases (`/:lang/category/*slug`, `/:lang/tag/:slug`, `/:lang/author/:slug`), a category's
        with its chain of parents as WordPress writes it (`/category/travel/berlin`); otherwise a
        page stays where it is, and a missing one is created at the Blog's default;
      * with `"use"`, the list of posts, the Blog's `/:lang/blog` page, goes by the run's
        `posts_page`: `"source"` to the source's posts page (`front_page`'s `"posts_page_link"`),
        or to `/` when the source shows its posts on its front (`"show_on_front"` `"posts"`);
        `"front"` to `/`; `"blog"` leaves it. The id of one of the site's pages, with either
        `blog_pages`, puts it at that page's address, which it frees by archiving the page (it can
        be restored from the archive). The list is marked `"blog:home"` in its `extra`, which is how
        a later run finds it, and the Blog's `/blog` is then answered by the redirects
        (`list_address/1`).

    A page of the site's own outside the Blog at the path a Blog page would take, or at that path
    without the language (`/blog` for `/:lang/blog`), is never written over or archived: that Blog
    page is neither created nor moved, and waits for the admin's decision, `"taken"` in the plan
    below, until they move their own page and run again. A missing page waits too, `"not_allowed"`,
    while the admin running the job may not set up the Blog's components and pages
    (`MishkaCmsCore.Runtime.ExtensionProvision.missing/2`).

    A dry run writes nothing and answers the plan, an import carries it out and answers what it did,
    each as the run's `extra` `"blog_pages"`, one entry per Blog page that is or would be created
    (`"create"`), moved (`"move"`, with the path it was at, `"from"`) or held (`"taken"`, with the
    path of the page holding it, `"by"`), keyed by the page's default path (`"page"`) and with the
    path it gets (`"path"`): `%{"page" => "/:lang/blog/tags", "action" => "create", "path" =>
    "/:lang/blog/tags"}`. The two are the same list, so the run's details say before the import what
    it will do. A page is created through the Blog's own provisioning
    (`MishkaBlog.Provision.ensure_pages!/3`), as the admin who pressed Import, which gives the site
    the Blog's components too when it has none; one the Blog finds taken there, such as by a page
    an admin archived, is answered `"taken"` with no `"by"`.

    Only what differs is written, so a second import writes nothing. The site's pages are read in
    one query: the Blog's and those at the paths its pages would take. A created page is read once
    more, and a moved or created page is put in the site's routing table at once, so what the
    import writes next is addressed at its new path.
    """

    require Ash.Query

    alias MishkaBlog.{Address, Provision}
    alias MishkaCmsCore.Runtime.ExtensionProvision
    alias MishkaCmsCore.Runtime.Handlers.BootHandler
    alias MishkaCmsCore.Runtime.{Languages, Page}
    alias MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState
    alias MishkaCmsMigration.Target
    alias MishkaCmsMigration.Targets.Helpers.Read

    @list "/:lang/blog"
    @home "blog:home"

    @doc """
    Puts the site's Blog pages in place as the run says, or in a dry run plans it, and answers the
    plan as the run's `"blog_pages"` fact (see the module doc).
    """
    @spec call(Target.context()) :: {:ok, %{String.t() => [map()]}} | {:error, term()}
    def call(context) do
      picked = picked(context.options.posts_page, context)
      targets = targets(context, picked)

      candidates =
        for {default, target} <- targets,
            path <- [target || default, unprefixed(target || default)],
            uniq: true,
            do: path

      {blog, others} =
        Page
        |> Ash.Query.filter(section == "blog" or path in ^candidates)
        |> Read.call(context)
        |> Enum.split_with(&(&1.section == "blog"))

      held = Enum.reject(others, &(picked && &1.id == picked.id))

      plan =
        for {record, default} <- kinds(),
            step = step(present(blog, record, default), targets[default], default, held),
            do: step

      carried_out(context.mode, allowed(plan, context.actor), picked, context)
    end

    @doc """
    The path of the site's Blog post page in `language`, as an import serves it once `call/1` moved
    it (`MishkaBlog.Address.path/3`), else the Blog's default. Read from memory.
    """
    @spec post_path(Target.context(), String.t() | nil) :: String.t()
    def post_path(context, language),
      do: own_path(context.site_id, "blog:post", language, MishkaBlog.Provision.item_paths().post)

    @doc """
    Where the site serves the Blog's list of posts, as a public address in the language the site
    leads with: the page marked `"blog:home"`, else the Blog's `/blog`. Read from memory.
    """
    @spec list_address(String.t()) :: String.t() | nil
    def list_address(site_id) do
      primary = Languages.primary(site_id)

      site_id
      |> own_path(@home, primary, @list)
      |> Languages.url(%{Languages.capture() => primary}, site_id)
    end

    defp own_path(site_id, record, language, default) do
      case Address.path(site_id, record, language) do
        {:ok, path} -> path
        :error -> default
      end
    end

    defp kinds do
      items = Provision.item_paths()
      places = Provision.places()

      records = %{
        places[:posts] => @home,
        places[:people] => "blog:people",
        items.post => "blog:post",
        items.category => "blog:category",
        items.tag => "blog:tag",
        items.author => "blog:author",
        items.team => "blog:team"
      }

      for default <- Provision.page_paths(), do: {records[default], default}
    end

    # WHERE EACH BLOG PAGE GOES, by its default path: `nil` for one that stays where it is.
    defp targets(%{options: %{blog_pages: "create"}}, picked),
      do: listed(Map.new(Provision.page_paths(), &{&1, nil}), picked && picked.address)

    defp targets(context, picked) do
      items = Provision.item_paths()
      wanted = wanted(context)

      Provision.page_paths()
      |> Map.new(&{&1, nil})
      |> Map.merge(%{
        items.post => wanted["blog:post"],
        items.category => wanted["blog:category"],
        items.tag => wanted["blog:tag"],
        items.author => wanted["blog:author"]
      })
      |> listed(listed_at(context.options.posts_page, picked, context))
    end

    defp listed(targets, path), do: Map.put(targets, @list, path)

    defp wanted(%{
           options: %{post_address: "keep"},
           permalinks: %{"pattern" => "/" <> _} = found
         }),
         do: %{
           "blog:post" => "/:lang" <> found["pattern"],
           "blog:category" => based(found["category_base"], "*slug"),
           "blog:tag" => based(found["tag_base"], ":slug"),
           "blog:author" => based(found["author_base"] || "author", ":slug")
         }

    defp wanted(_blog_addresses), do: %{}

    defp based(base, capture), do: "/:lang/" <> base <> "/" <> capture

    defp listed_at("blog", _picked, _context), do: nil
    defp listed_at("front", _picked, _context), do: "/:lang"
    defp listed_at("source", _picked, %{front_page: front_page}), do: posts_page(front_page)
    defp listed_at("source", _picked, _context), do: nil
    defp listed_at(_page_id, picked, _context), do: picked && picked.address

    defp posts_page(%{"posts_page_link" => link}) when is_binary(link),
      do: link |> URI.parse() |> Map.get(:path) |> under_language()

    defp posts_page(%{"show_on_front" => "posts"}), do: "/:lang"
    defp posts_page(_none), do: nil

    defp under_language(nil), do: nil

    defp under_language(path) do
      case path |> URI.decode() |> String.split("/", trim: true) do
        [] -> "/:lang"
        [":lang" | _rest] = segments -> "/" <> Enum.join(segments, "/")
        segments -> "/:lang/" <> Enum.join(segments, "/")
      end
    end

    # THE PAGE AN ADMIN PICKED gives the list its address, archived by the import to free it. A page
    # a run already archived is not found, and the list stays where that run put it.
    defp picked(page_id, context) when page_id not in ["source", "front", "blog"] do
      case Page |> Ash.Query.filter(id == ^page_id) |> Read.call(context) do
        [page] -> %{id: page.id, page: page, address: under_language(page.path)}
        [] -> nil
      end
    end

    defp picked(_not_a_page, _context), do: nil

    defp present(blog, record, default),
      do: Enum.find(blog, &((record != nil and record_of(&1) == record) or &1.path == default))

    defp record_of(%{extra: %{"record" => record}}), do: record
    defp record_of(%{path: @list}), do: @home
    defp record_of(_other), do: nil

    defp unprefixed("/:lang"), do: "/"
    defp unprefixed("/:lang" <> path), do: path
    defp unprefixed(path), do: path

    defp holder(held, path),
      do: Enum.find(held, &(&1.path in [path, unprefixed(path)]))

    # WHAT ONE BLOG PAGE NEEDS: nothing, to be moved, to be created, or the admin's decision.
    defp step(nil, target, default, held),
      do: placed(holder(held, target || default), {:create, default, target || default})

    defp step(_page, nil, _default, _held), do: nil

    defp step(%{path: path, extra: %{"record" => @home}}, path, _default, _held), do: nil
    defp step(%{path: path} = page, path, @list, _held), do: {:move, page, path, @list}
    defp step(%{path: path}, path, _default, _held), do: nil

    defp step(page, target, default, held),
      do: placed(holder(held, target), {:move, page, target, default})

    defp placed(nil, step), do: step
    defp placed(page, {:create, default, path}), do: {:taken, default, path, page.path}
    defp placed(page, {:move, _blog, path, default}), do: {:taken, default, path, page.path}

    # A MISSING PAGE NEEDS AN ADMIN WHO MAY SET UP THE BLOG, its components and pages
    # (`MishkaCmsCore.Runtime.ExtensionProvision.missing/2`), else it waits for one, in the dry run too.
    defp allowed(plan, actor) do
      case Enum.any?(plan, &match?({:create, _default, _path}, &1)) and
             ExtensionProvision.missing(Provision.manifest(), actor) != [] do
        true -> Enum.map(plan, &not_allowed/1)
        false -> plan
      end
    end

    defp not_allowed({:create, default, path}), do: {:not_allowed, default, path}
    defp not_allowed(step), do: step

    defp carried_out(:dry_run, plan, _picked, _context), do: {:ok, facts(plan)}

    defp carried_out(:import, plan, picked, context) do
      with :ok <- freed(plan, picked, context),
           :ok <- moved(plan, context),
           {:ok, skipped} <- created(plan, context) do
        {:ok, plan |> Enum.map(&skipped(&1, skipped)) |> facts()}
      end
    end

    defp freed(plan, %{page: page, address: address}, context) do
      case Enum.any?(plan, &listed_at?(&1, address)) do
        true -> Ash.destroy(page, actor: context.actor, tenant: context.site_id)
        false -> :ok
      end
    end

    defp freed(_plan, _picked, _context), do: :ok

    defp listed_at?({:move, _page, address, @list}, address), do: true
    defp listed_at?({:create, @list, address}, address), do: true
    defp listed_at?(_step, _address), do: false

    defp moved(plan, context) do
      Enum.reduce_while(plan, :ok, fn
        {:move, page, path, default}, :ok ->
          page
          |> Ash.Changeset.for_update(:update, changes(path, default),
            actor: context.actor,
            tenant: context.site_id
          )
          |> Ash.update(load: [:site])
          |> routed()

        _other, :ok ->
          {:cont, :ok}
      end)
    end

    defp changes(path, @list), do: %{path: path, record: @home}
    defp changes(path, _default), do: %{path: path}

    defp created(plan, context) do
      case for({:create, default, path} <- plan, into: %{}, do: {default, path}) do
        paths when map_size(paths) == 0 -> {:ok, []}
        paths -> provisioned(paths, context)
      end
    end

    defp provisioned(paths, context) do
      report = Provision.ensure_pages!(context.site_id, paths, actor: context.actor)

      written =
        Page
        |> Ash.Query.filter(section == "blog" and path in ^report.pages)
        |> Ash.Query.load(:site)
        |> Read.call(context)

      Enum.each(written, &route/1)
      {:ok, Enum.map(report.skipped_pages, & &1.path)}
    rescue
      error -> {:error, error}
    end

    defp skipped({:create, default, path} = step, skipped),
      do: taken_by_blog(path in skipped, step, default, path)

    defp skipped(step, _skipped), do: step

    defp taken_by_blog(true, _step, default, path), do: {:taken, default, path, nil}
    defp taken_by_blog(false, step, _default, _path), do: step

    defp facts(plan), do: %{"blog_pages" => Enum.map(plan, &fact/1)}

    defp fact({:create, default, path}),
      do: %{"page" => default, "action" => "create", "path" => path}

    defp fact({:move, page, path, default}),
      do: %{"page" => default, "action" => "move", "path" => path, "from" => page.path}

    defp fact({:not_allowed, default, path}),
      do: %{"page" => default, "action" => "not_allowed", "path" => path}

    defp fact({:taken, default, path, by}),
      do: %{"page" => default, "action" => "taken", "path" => path, "by" => by}

    # THE MOVED OR CREATED PAGE ANSWERS AT ONCE: its routing row is put in memory as the compile job
    # that follows the write puts it (`MishkaCmsCore.Runtime.Handlers.BootHandler.web_metadata_row/2`),
    # so the posts and redirects this import writes next find the page where it now is.
    defp routed({:ok, page}) do
      route(page)
      {:cont, :ok}
    end

    defp routed({:error, error}), do: {:halt, {:error, error}}

    defp route(page),
      do: :ok = page |> BootHandler.web_metadata_row("Page") |> WebRunTimeMetaDataState.save()
  end
end
