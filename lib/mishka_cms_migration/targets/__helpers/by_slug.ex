# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.Helpers.BySlug do
  @moduledoc """
  The `existing/2` (`MishkaCmsMigration.Target`) of a target whose resource keeps one record per
  slug on a site, such as the Blog's tags and categories: an item is the record the run's site
  already holds with its slug, in the language the site leads with, and is connected to it.

  The slug is made the way the resource stores it. A WordPress slug arrives decoded, and the
  resource's `:create` runs its `slugify` over what it is given, so an item with the slug
  `"وردپرس"` is the record with the slug `"wrdprs"`. The slugify options are read from the create
  action itself (`MishkaCmsCore.Runtime.Helpers.slugifiers/1`), so a resource that slugifies
  otherwise is matched as it is written.

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

  @doc "The item of `items` that is a record `target`'s resource already holds, by source id."
  @spec call(module(), [Item.t()], Target.context()) :: %{String.t() => Target.found()}
  def call(target, items, context) do
    options = slugify_options(target.resource(), target.actions().create, :slug)
    stored = for item <- items, slug = stored(item.attrs["slug"], options), do: {item, slug}
    held = stored |> Enum.map(&elem(&1, 1)) |> held(target.resource(), context)

    for {item, slug} <- stored, record = held[slug], into: %{} do
      {item.source_id, {:connected, record}}
    end
  end

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
