# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(MishkaBlog.Tag) do
  defmodule MishkaCmsMigration.Targets.BlogTag do
    @moduledoc """
    The `"tag"` items of a source written as the Blog's tags (`MishkaBlog.Tag`), through the
    `:create` and `:update` an admin's own tag form runs, on the run's site and as the admin who
    pressed Import: the admin needs the Blog's `admin:dashboard:blog:post`, and the Blog's own
    rules decide the rest, such as one slug per site and how a slug is written (its `slugify`).

    An item's title is the tag's name, its `"slug"` and `"description"` the tag's own (an empty
    description is none), and its parent, for a source whose tags nest, the tag's parent tag. A tag
    is in the language the site leads with (`MishkaCmsCore.Runtime.Languages.primary/1`): a
    WordPress term has no language of its own.

    Defined only where Mishka Blog is loaded, and supervised by `MishkaCmsMigration.Application`
    only then; on a site without the Blog its kind is skipped as `"no_target"`.
    """

    use MishkaCmsMigration.Target,
      kind: "tag",
      resource: MishkaBlog.Tag,
      create: :create,
      update: :update

    alias MishkaCmsCore.Runtime.Languages

    @impl MishkaCmsMigration.Target
    def attrs(item, context) do
      %{
        name: item.title,
        slug: item.attrs["slug"],
        description: description(item.attrs["description"]),
        language: Languages.primary(context.site_id),
        parent_tag_id: context.parent_id
      }
    end

    defp description(""), do: nil
    defp description(description), do: description
  end
end
