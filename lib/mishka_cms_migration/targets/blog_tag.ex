# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(MishkaBlog.Tag) do
  defmodule MishkaCmsMigration.Targets.BlogTag do
    @moduledoc """
    The `"tag"` items of a source written as the Blog's tags (`MishkaBlog.Tag`), through the
    `:create` and `:update` an admin's own tag form runs, on the run's site and as the admin who
    pressed Import: the admin needs the Blog's `admin:dashboard:blog:post`, and the Blog's own
    rules decide the rest, such as one slug per site and how a slug is written (the scripts of the
    site's languages stay, Latin accents go).

    An item's title is the tag's name, its `"slug"` and `"description"` the tag's own (an empty
    description is none), and its parent, for a source whose tags nest, the tag's parent tag. A tag
    is in the language the item names (a site that runs Polylang or WPML names one), joined as one
    group with the tags that are its other editions, or, for an item that names none, in the
    language the site leads with (`MishkaCmsMigration.Targets.Helpers.Editions`). An item in a
    language the site does not publish in waits for an admin's decision.

    A tag the run's site already has, with the slug as the Blog writes it, in any language,
    waits for an admin's decision (`"slug_taken"`, `MishkaCmsMigration.Targets.Helpers.BySlug`).
    Connect to the existing record makes the item that tag: it is not written, the posts that name
    it are linked to it, the report says `"connected"`, and the tag is kept as it is, now and on
    every later run. Import as new with another slug writes the item as a tag of its own, its slug
    followed by its source id, and the report says `"another_slug"`.

    Defined only where Mishka Blog is loaded, and supervised by `MishkaCmsMigration.Application`
    only then; on a node without the Blog its items wait for it (`"blog_missing"`).
    """

    use MishkaCmsMigration.Target,
      kind: "tag",
      resource: MishkaBlog.Tag,
      create: :create,
      update: :update

    use MishkaCmsMigration.Targets.Helpers.BySlug
    use MishkaCmsMigration.Targets.Helpers.Editions

    alias MishkaCmsMigration.Targets.Helpers.{BySlug, Editions}

    @impl MishkaCmsMigration.Target
    def attrs(item, context) do
      %{
        name: item.title,
        slug: BySlug.wanted(__MODULE__, item, context),
        description: description(item.attrs["description"]),
        parent_tag_id: context.parent_id
      }
      |> Map.merge(Editions.attrs(item, context, MishkaBlog.Tag))
    end

    @impl MishkaCmsMigration.Target
    def note(item, context),
      do: Editions.note(item, context, BySlug.note(__MODULE__, item, context))

    defp description(""), do: nil
    defp description(description), do: description
  end
end
