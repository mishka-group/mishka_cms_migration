# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(MishkaBlog.Address) do
  defmodule MishkaCmsMigration.Targets.Helpers.BlogPages do
    @moduledoc """
    The site's Blog pages a run moves so the Blog serves posts, categories, tags, authors and its
    list of posts where the source had them, before an import writes any of them
    (`MishkaCmsMigration.Targets.BlogPost`'s `before_import/1`).

    The Blog serves each kind of row at the page whose `extra` names it (`"blog:post"`,
    `"blog:category"`, `"blog:tag"`, `"blog:author"`, `MishkaBlog.Address`), so moving one is a
    normal page update, as the admin who pressed Import, through the page's `:update`:

      * with the run's `post_address` `"keep"` and a structure the source's posts share
        (`permalinks`' `"pattern"`), the post page's path is that pattern behind the language
        (`/:lang/:year/:monthnum/:slug`), and the category, tag and author pages' are the source's
        bases (`/:lang/category/:slug`, `/:lang/tag/:slug`, `/:lang/author/:slug`); otherwise they
        stay where they are;
      * the list of posts, the Blog's `/:lang/blog` page, moves by the run's `posts_page`:
        `"source"` to the source's posts page (`front_page`'s `"posts_page_link"`), or to `/`
        when the source shows its posts on its front (`"show_on_front"` `"posts"`), else it stays;
        `"front"` to `/`; the id of one of the site's pages to that page's address, which it frees
        by archiving the page (it can be restored from the archive); `"blog"` leaves it. The moved
        page is marked `"blog:home"` in its `extra`, which is how a later run finds it, and the
        Blog's `/blog` is then answered by the redirects (`list_address/1`,
        `MishkaCmsMigration.Targets.PostRedirect`).

    Only what differs is written, so a second import writes nothing, and a dry run asks nothing.
    The Blog's pages are read in one query, and a moved page is put in the site's routing table at
    once, so what the import writes next is addressed at its new path.
    """

    require Ash.Query

    alias MishkaBlog.Address
    alias MishkaCmsCore.Runtime.Handlers.BootHandler
    alias MishkaCmsCore.Runtime.{Languages, Page}
    alias MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState
    alias MishkaCmsMigration.Target
    alias MishkaCmsMigration.Targets.Helpers.Read

    @list "/:lang/blog"
    @home "blog:home"

    @doc "Moves the site's Blog pages as the run says (see the module doc)."
    @spec call(Target.context()) :: :ok | {:error, term()}
    def call(context) do
      pages =
        Page
        |> Ash.Query.filter(section == "blog")
        |> Read.call(context)

      moves =
        for {record, path} <- wanted(context),
            page <- pages,
            record_of(page) == record,
            page.path != path,
            do: {page, %{path: path}}

      with {:ok, list_moves} <- list_moves(pages, context) do
        Enum.reduce_while(moves ++ list_moves, :ok, fn {page, changes}, :ok ->
          page
          |> Ash.Changeset.for_update(:update, changes,
            actor: context.actor,
            tenant: context.site_id
          )
          |> Ash.update(load: [:site])
          |> moved()
        end)
      end
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

    defp wanted(%{
           options: %{post_address: "keep"},
           permalinks: %{"pattern" => "/" <> _} = found
         }),
         do: %{
           "blog:post" => "/:lang" <> found["pattern"],
           "blog:category" => based(found["category_base"]),
           "blog:tag" => based(found["tag_base"]),
           "blog:author" => based(found["author_base"] || "author")
         }

    defp wanted(_blog_addresses), do: %{}

    defp based(base), do: "/:lang/" <> base <> "/:slug"

    defp record_of(%{extra: %{"record" => record}}), do: record
    defp record_of(%{path: @list}), do: @home
    defp record_of(_other), do: nil

    defp list_moves(pages, context) do
      case Enum.find(pages, &(record_of(&1) == @home)) do
        nil -> {:ok, []}
        list -> list |> listed_at(context.options.posts_page, context) |> list_move(list)
      end
    end

    defp listed_at(_list, "blog", _context), do: nil
    defp listed_at(_list, "front", _context), do: "/:lang"
    defp listed_at(_list, "source", %{front_page: front_page}), do: posts_page(front_page)
    defp listed_at(_list, "source", _context), do: nil
    defp listed_at(_list, page_id, context), do: freed(page_id, context)

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

    # THE PAGE AN ADMIN PICKED gives the list its address: it is archived to free it. A page a run
    # already archived is not found, and the list stays where that run put it.
    defp freed(page_id, context) do
      case Page |> Ash.Query.filter(id == ^page_id) |> Read.call(context) do
        [page] ->
          page |> Ash.destroy(actor: context.actor, tenant: context.site_id) |> archived(page)

        [] ->
          nil
      end
    end

    defp archived(:ok, page), do: under_language(page.path)
    defp archived({:error, error}, _page), do: {:error, error}

    defp list_move({:error, error}, _list), do: {:error, error}
    defp list_move(nil, _list), do: {:ok, []}

    defp list_move(path, %{path: path, extra: %{"record" => @home}}), do: {:ok, []}
    defp list_move(path, list), do: {:ok, [{list, %{path: path, record: @home}}]}

    # THE MOVED PAGE ANSWERS AT ONCE: its routing row is put in memory as the compile job that follows
    # the update puts it (`MishkaCmsCore.Runtime.Handlers.BootHandler.web_metadata_row/2`), so the
    # posts and redirects this import writes next find the page where it now is.
    defp moved({:ok, page}) do
      :ok = page |> BootHandler.web_metadata_row("Page") |> WebRunTimeMetaDataState.save()
      {:cont, :ok}
    end

    defp moved({:error, error}), do: {:halt, {:error, error}}
  end
end
