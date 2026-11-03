# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(MishkaBlog.Collection) do
  defmodule MishkaCmsMigration.Targets.BlogCollection do
    @moduledoc """
    The `"category"` items of a source written as the Blog's categories (`MishkaBlog.Collection`),
    through the `:create` and `:update` an admin's own category form runs, on the run's site and
    as the admin who pressed Import: the admin needs the Blog's `admin:dashboard:blog:post`, and
    the Blog's own rules decide the rest, such as one slug per site and how a slug is written (its
    `slugify`).

    An item's title is the category's name, its `"slug"` and `"description"` the category's own
    (an empty description is none), and its parent the category's parent category: the walk writes
    the parent first, whichever the source lists first, so a nested category lands under the one
    it sat under (`MishkaCmsMigration.Target`, "An item's parent"). A category is active, as a
    WordPress category is live once it exists, and in the language the site leads with
    (`MishkaCmsCore.Runtime.Languages.primary/1`): a WordPress term has no language of its own.

    A category the run's site already has, with the slug as the Blog writes it and in that language,
    waits for an admin's decision (`"slug_taken"`, `MishkaCmsMigration.Targets.Helpers.BySlug`).
    Connect to the existing record makes the item that category: it is not written, the posts that
    name it are linked to it, the categories that sat under it in the source go under it, the
    report says `"connected"`, and the category is kept as it is, now and on every later run.
    Import as new with another slug writes the item as a category of its own, its slug followed by
    its source id, and the report says `"another_slug"`.

    Defined only where Mishka Blog is loaded, and supervised by `MishkaCmsMigration.Application`
    only then; on a site without the Blog its kind is skipped as `"no_target"`.
    """

    use MishkaCmsMigration.Target,
      kind: "category",
      resource: MishkaBlog.Collection,
      create: :create,
      update: :update

    use MishkaCmsMigration.Targets.Helpers.BySlug

    alias MishkaCmsCore.Runtime.Languages
    alias MishkaCmsMigration.Targets.Helpers.BySlug

    @impl MishkaCmsMigration.Target
    def attrs(item, context) do
      %{
        name: item.title,
        slug: BySlug.wanted(item, context),
        description: description(item.attrs["description"]),
        status: :active,
        language: Languages.primary(context.site_id),
        parent_collection_id: context.parent_id
      }
    end

    defp description(""), do: nil
    defp description(description), do: description
  end
end
