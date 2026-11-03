# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(MishkaBlog.BlogPost) do
  defmodule MishkaCmsMigration.Targets.PostRedirect do
    @moduledoc """
    The `"post_redirect"` items of a source, each post's old address, written as the CMS's own
    redirect rules (`MishkaCmsCore.Runtime.Redirect`), through the `:create` and `:update` an
    admin's own redirect form runs, on the run's site and as the admin who pressed Import: the admin
    needs the core's `admin:dashboard:runtime:redirect`, and the core's own rules decide the rest,
    such as how an address is stored and that one site redirects an address once.

    An item's `"from"` is the address the post had at the source, such as `/2025/12/hello/`, and the
    rule sends it, with a 301, to where the Blog serves the post the same run or an earlier one
    wrote for that source id (`MishkaCmsMigration.Targets.BlogPost.address/3`): `/blog/hello` in
    the language the site leads with.

    ## Which items

    By the run's `post_address` choice (`MishkaCmsMigration.MigrationRun`'s options), read with
    `existing/2` before anything is written, in the dry run too:

      * `"blog_without_redirects"` — every item is skipped as `"not_chosen"`, and no rule is
        written;
      * `"blog"` (the default) — a rule is written for each item, except:
        * one the source gives no old address (`"from"` is `nil`, such as a draft's) — skipped as
          `"no_old_address"`;
        * in an import, one whose post has no Blog post — it failed, was never written or an admin
          left it out — skipped as `"post_missing"`;
        * in an import, one whose old address is the post's Blog address already — skipped as
          `"same_address"`.

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
    only then; on a site without the Blog its kind is skipped as `"no_target"`.
    """

    use MishkaCmsMigration.Target,
      kind: "post_redirect",
      resource: MishkaCmsCore.Runtime.Redirect,
      create: :create,
      update: :update

    alias MishkaBlog.BlogPost
    alias MishkaCmsCore.Runtime.Redirects
    alias MishkaCmsMigration.Targets.BlogPost, as: PostTarget
    alias MishkaCmsMigration.Targets.Helpers.Written

    @impl MishkaCmsMigration.Target
    def existing(items, %{options: %{post_address: "blog_without_redirects"}}),
      do: Map.new(items, &{&1.source_id, {:skipped, "not_chosen"}})

    def existing(items, context) do
      posts = posts(items, context)

      for item <- items,
          found = found(item, posts, context),
          into: %{},
          do: {item.source_id, found}
    end

    @impl MishkaCmsMigration.Target
    def attrs(item, context) do
      %{
        from_path: item.attrs["from"],
        to: [item] |> posts(context) |> Map.get(item.source_id) |> address(context),
        status: 301
      }
    end

    defp found(%{attrs: %{"from" => "/" <> _}} = item, posts, context),
      do: planned(item, posts, context)

    defp found(_no_old_address, _posts, _context), do: {:skipped, "no_old_address"}

    defp planned(_item, _posts, %{mode: :dry_run}), do: nil

    defp planned(item, posts, context),
      do: posts |> Map.get(item.source_id) |> moved(item, context)

    defp moved(nil, _item, _context), do: {:skipped, "post_missing"}
    defp moved(post, item, context), do: unmoved(item.attrs["from"], address(post, context))

    defp unmoved(from, to) when is_binary(to),
      do: from |> Redirects.normalize_path() |> same(Redirects.normalize_path(to))

    defp unmoved(_from, _no_address), do: nil

    defp same({:ok, path}, {:ok, path}), do: {:skipped, "same_address"}
    defp same(_from, _to), do: nil

    defp address(%BlogPost{slug: slug, language: language}, context),
      do: PostTarget.address(slug, language, context.site_id)

    defp address(nil, _context), do: nil

    defp posts(_items, %{mode: :dry_run}), do: %{}

    defp posts(items, context),
      do: Written.call(BlogPost, "post", Enum.map(items, & &1.source_id), context)
  end
end
