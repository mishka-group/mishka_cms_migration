# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.Helpers.BySlug do
  @moduledoc """
  The `existing/2` (`MishkaCmsMigration.Target`) of a target whose resource keeps one record per
  slug on a site, such as the Blog's tags and categories: an item whose slug the run's site already
  holds a record with, in any language, as the Blog keeps one slug per site, waits for an admin's
  decision as `"slug_taken"` (`MishkaCmsMigration.MigrationItem`'s Decide…). Connect to the existing
  record connects the item to it (`"keep"`), and Import as new with another slug (`"import"`) writes
  it as its own, with the slug `wanted/3` makes and the report saying so (`note/3`,
  `"another_slug"`).

  The slug is made the way the resource stores it. A WordPress slug arrives decoded, and the
  resource's `:create` runs its slug change over what it is given, so a slug is compared as the
  Blog writes it: with the scripts of the site's languages kept (`وردپرس` stays `وردپرس` on a site
  that publishes in Persian) and the Latin accents removed (`café` is `cafe`). The slug options
  are read from the create action itself (`MishkaCmsCore.Runtime.Helpers.slugifiers/1`) and
  resolved for the item's site and language (`MishkaSlug.Change.slug_options/2`), so a
  resource that slugs otherwise is matched as it is written. A slug the site's languages keep
  nothing of (`وردپرس` on a site that publishes in English alone) is written as `generated/2`
  makes it, the target's kind and eight hex characters (`tag-1a2b3c4d`), and the report says so
  (`"path_made_ascii"`): the same slug always gives the same one, so a later run and a post's link
  to it find it.

  A target whose records are found so, such as the Blog's categories and tags, says
  `use MishkaCmsMigration.Targets.Helpers.BySlug` after `use MishkaCmsMigration.Target`: its
  `existing/2` is `call/3`, its `note/2` says what `note/3` says, and its `attrs/2` writes the slug
  `wanted/3` makes.

  The records are read by `MishkaCmsMigration.Targets.Helpers.Read`. `slug/4` is that slug alone,
  for a target that points at a record by the address its slug makes, such as a post's link to
  another post.
  """

  require Ash.Query

  alias Ash.Resource.Info
  alias MishkaCmsCore.Runtime.Helpers
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Target
  alias MishkaCmsMigration.Targets.Helpers.{Editions, Read}

  @doc false
  defmacro __using__(_opts) do
    quote do
      @impl MishkaCmsMigration.Target
      def existing(items, context),
        do: MishkaCmsMigration.Targets.Helpers.BySlug.call(__MODULE__, items, context)
    end
  end

  @doc """
  What the run's site holds of `items` by slug, by source id: the record an admin decided to
  connect an item to, or the conflict an item waits on; an item whose slug the site does not hold,
  or that an admin decided to import as new, is left out, to be created.
  """
  @spec call(module(), [Item.t()], Target.context()) :: %{String.t() => Target.found()}
  def call(target, items, context) do
    stored =
      for item <- items,
          slug = slug(target, item.attrs["slug"], Editions.language(item, context), context),
          do: {item, slug}

    held = stored |> Enum.map(&elem(&1, 1)) |> held(target.resource(), context)

    for {item, slug} <- stored,
        record = held[slug],
        found = taken(record, Target.decision(context, item, "slug_taken")),
        into: %{},
        do: {item.source_id, found}
  end

  @doc """
  The slug `target` writes `item` with: the source's `"slug"` as `slug/4` makes it in the item's
  language, or, once an admin decided to import the item as new beside the site's record of that
  slug (`"slug_taken"`), that slug with `-<source id>` after it: `elixir` is `elixir-10`.
  """
  @spec wanted(module(), Item.t(), Target.context()) :: String.t() | nil
  def wanted(target, %Item{attrs: %{"slug" => slug}} = item, context)
      when is_binary(slug) and slug != "",
      do:
        target
        |> slug(slug, Editions.language(item, context), context)
        |> another(item, Target.decision(context, item, "slug_taken"))

  def wanted(_target, %Item{attrs: attrs}, _context), do: attrs["slug"]

  @doc """
  What the report says of `item` on a page (`MishkaCmsMigration.Target`'s `note/2`):
  `"another_slug"` once an admin decided to import it as new with another slug, else `nil`.
  """
  @spec note(Item.t(), Target.context()) :: String.t() | nil
  def note(item, context), do: context |> Target.decision(item, "slug_taken") |> noted()

  @doc """
  What the report says of `item` written by `target`: `note/2`, and `"path_made_ascii"` when the
  site's languages keep nothing of its `"slug"`, so it is written with a generated one (`slug/4`).
  """
  @spec note(module(), Item.t(), Target.context()) :: String.t() | nil
  def note(target, item, context) do
    [note(item, context), generated_note(target, item.attrs["slug"], item, context)]
    |> Enum.reject(&is_nil/1)
    |> joined()
  end

  @doc """
  The slug `target`'s resource stores for a source's `slug` written in `language` on the run's site,
  made as its create action makes it: `"وردپرس"` stays `"وردپرس"` for a Persian tag on a site that
  publishes in Persian, or that an admin decided to add Persian to for it (the item's language is
  one of the site's by the time it is written), and `generated/2` with `target`'s kind on a site
  whose languages keep nothing of it; `nil` for no slug.
  """
  @spec slug(module(), String.t() | nil, String.t(), Target.context()) :: String.t() | nil
  def slug(target, slug, language, context) when is_binary(slug) and slug != "",
    do: stored(target, slug, language, context) || generated(target.id(), slug)

  def slug(_target, _no_slug, _language, _context), do: nil

  @doc """
  An ASCII name for `text` that keeps no letter of it, for a slug or an address the CMS cannot
  write in `text`'s own script: `prefix`, `-` and the first eight hex characters of its SHA-256,
  so the same text always gives the same name. `generated("page", "وردپرس")` is `page-` followed
  by eight hex characters.
  """
  @spec generated(String.t(), String.t()) :: String.t()
  def generated(prefix, text),
    do:
      prefix <>
        "-" <>
        (:crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, 8))

  defp stored(target, slug, language, context) do
    resource = target.resource()

    options =
      resource
      |> slugify_options(target.actions().create, :slug)
      |> MishkaSlug.Change.slug_options(changeset(resource, language, context))
      |> Keyword.update(:locales, [], &with_language(&1, language))

    case MishkaSlug.slugify(slug, options) do
      {:ok, slug} -> slug
      {:error, _nothing_left} -> nil
    end
  end

  defp with_language([], _language), do: []
  defp with_language(locales, language), do: Enum.uniq(locales ++ [language])

  defp generated_note(target, slug, item, context) when is_binary(slug) and slug != "" do
    case stored(target, slug, Editions.language(item, context), context) do
      nil -> "path_made_ascii"
      _kept -> nil
    end
  end

  defp generated_note(_target, _no_slug, _item, _context), do: nil

  defp taken(record, "keep"), do: {:connected, record}
  defp taken(_record, "import"), do: nil
  defp taken(_record, nil), do: {:undecided, "slug_taken"}

  defp another(slug, item, "import") when is_binary(slug), do: slug <> "-" <> item.source_id
  defp another(slug, _item, _decision), do: slug

  defp noted("import"), do: "another_slug"
  defp noted(_decision), do: nil

  defp joined([]), do: nil
  defp joined(notes), do: Enum.join(notes, "; ")

  defp slugify_options(resource, action, field) do
    resource
    |> Info.action(action)
    |> Helpers.slugifiers()
    |> Enum.find_value([], fn
      {^field, ^field, options} -> options
      _other -> nil
    end)
  end

  defp changeset(resource, language, context),
    do:
      resource
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(context.site_id)
      |> Ash.Changeset.force_change_attribute(:language, language)

  defp held([], _resource, _context), do: %{}

  defp held(slugs, resource, context),
    do:
      resource
      |> Ash.Query.filter(slug in ^slugs)
      |> Read.call(context)
      |> Map.new(&{&1.slug, &1})
end
