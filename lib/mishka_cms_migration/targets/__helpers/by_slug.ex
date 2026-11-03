# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.Helpers.BySlug do
  @moduledoc """
  The `existing/2` (`MishkaCmsMigration.Target`) of a target whose resource keeps one record per
  slug on a site, such as the Blog's tags and categories: an item whose slug the run's site already
  holds a record with, in the language the site leads with, waits for an admin's decision as
  `"slug_taken"` (`MishkaCmsMigration.MigrationItem`'s Decide…). Connect to the existing record
  connects the item to it (`"keep"`), and Import as new with another slug (`"import"`) writes it as
  its own, with the slug `wanted/2` makes and the report saying so (`note/2`, `"another_slug"`).

  The slug is made the way the resource stores it. A WordPress slug arrives decoded, and the
  resource's `:create` runs its `slugify` over what it is given, so an item with the slug
  `"وردپرس"` is the record with the slug `"wrdprs"`. The slugify options are read from the create
  action itself (`MishkaCmsCore.Runtime.Helpers.slugifiers/1`), so a resource that slugifies
  otherwise is matched as it is written.

  A target whose records are found so, such as the Blog's categories and tags, says
  `use MishkaCmsMigration.Targets.Helpers.BySlug` after `use MishkaCmsMigration.Target`: its
  `existing/2` is `call/3` and its `note/2` is `note/2`, and its `attrs/2` writes the slug
  `wanted/2` makes.

  The records are read by `MishkaCmsMigration.Targets.Helpers.Read`. `slug/2` is that slug alone,
  for a target that points at a record by the address its slug makes, such as a post's link to
  another post, or the slug another resource's action stores in a field of its own, such as the
  name of a media folder.
  """

  require Ash.Query

  alias Ash.Resource.Info
  alias MishkaCmsCore.Runtime.{Helpers, Languages}
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Target
  alias MishkaCmsMigration.Targets.Helpers.Read

  @doc false
  defmacro __using__(_opts) do
    quote do
      @impl MishkaCmsMigration.Target
      def existing(items, context),
        do: MishkaCmsMigration.Targets.Helpers.BySlug.call(__MODULE__, items, context)

      @impl MishkaCmsMigration.Target
      def note(item, context), do: MishkaCmsMigration.Targets.Helpers.BySlug.note(item, context)
    end
  end

  @doc """
  What the run's site holds of `items` by slug, by source id: the record an admin decided to
  connect an item to, or the conflict an item waits on; an item whose slug the site does not hold,
  or that an admin decided to import as new, is left out, to be created.
  """
  @spec call(module(), [Item.t()], Target.context()) :: %{String.t() => Target.found()}
  def call(target, items, context) do
    options = slugify_options(target.resource(), target.actions().create, :slug)
    stored = for item <- items, slug = stored(item.attrs["slug"], options), do: {item, slug}
    held = stored |> Enum.map(&elem(&1, 1)) |> held(target.resource(), context)

    for {item, slug} <- stored,
        record = held[slug],
        found = taken(record, Target.decision(context, item, "slug_taken")),
        into: %{},
        do: {item.source_id, found}
  end

  @doc """
  The slug a target writes `item` with: the source's `"slug"`, or, once an admin decided to import
  the item as new beside the site's record of that slug (`"slug_taken"`), that slug with
  `-<source id>` after it: `elixir` is `elixir-10`. The resource's create makes it as it makes any
  slug, so the Blog's rule holds for it too: `وردپرس-20` is `wrdprs-20`.
  """
  @spec wanted(Item.t(), Target.context()) :: String.t() | nil
  def wanted(%Item{attrs: %{"slug" => slug}} = item, context) when is_binary(slug) and slug != "",
    do: another(slug, item, Target.decision(context, item, "slug_taken"))

  def wanted(%Item{attrs: attrs}, _context), do: attrs["slug"]

  @doc """
  What the report says of `item` (`MishkaCmsMigration.Target`'s `note/2`): `"another_slug"` once
  an admin decided to import it as new with another slug (`wanted/2`), else `nil`.
  """
  @spec note(Item.t(), Target.context()) :: String.t() | nil
  def note(item, context), do: context |> Target.decision(item, "slug_taken") |> noted()

  @doc """
  The slug `target`'s resource stores for a source's `slug`, made as its create action makes it:
  `"وردپرس"` is `"wrdprs"` for the Blog's tags; `nil` for no slug. Given
  `{resource, action, field}` instead of a target, the slug that action of that resource stores in
  that field, such as `{MishkaCmsCore.Runtime.MediaCategory, :create, :name}` for a media folder's
  name.
  """
  @spec slug(module() | {Ash.Resource.t(), atom(), atom()}, String.t() | nil) ::
          String.t() | nil
  def slug({resource, action, field}, slug),
    do: stored(slug, slugify_options(resource, action, field))

  def slug(target, slug), do: slug({target.resource(), target.actions().create, :slug}, slug)

  defp taken(record, "keep"), do: {:connected, record}
  defp taken(_record, "import"), do: nil
  defp taken(_record, nil), do: {:undecided, "slug_taken"}

  defp another(slug, item, "import"), do: slug <> "-" <> item.source_id
  defp another(slug, _item, _decision), do: slug

  defp noted("import"), do: "another_slug"
  defp noted(_decision), do: nil

  defp slugify_options(resource, action, field) do
    resource
    |> Info.action(action)
    |> Helpers.slugifiers()
    |> Enum.find_value([], fn
      {^field, ^field, options} -> options
      _other -> nil
    end)
  end

  defp stored(slug, options) when is_binary(slug), do: stored(Slug.slugify(slug, options))
  defp stored(_not_a_slug, _options), do: nil

  defp stored(slug) when slug in [nil, ""], do: nil
  defp stored(slug), do: slug

  defp held([], _resource, _context), do: %{}

  defp held(slugs, resource, context) do
    language = Languages.primary(context.site_id)

    resource
    |> Ash.Query.filter(slug in ^slugs and language == ^language)
    |> Read.call(context)
    |> Map.new(&{&1.slug, &1})
  end
end
