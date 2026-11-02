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

  The records are read by `MishkaCmsMigration.Targets.Helpers.Read`.
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
    options = slugify_options(target)
    stored = for item <- items, slug = stored(item.attrs["slug"], options), do: {item, slug}
    held = stored |> Enum.map(&elem(&1, 1)) |> held(target.resource(), context)

    for {item, slug} <- stored, record = held[slug], into: %{} do
      {item.source_id, {:connected, record}}
    end
  end

  defp slugify_options(target) do
    target.resource()
    |> Info.action(target.actions().create)
    |> Helpers.slugifiers()
    |> Enum.find_value([], fn
      {:slug, :slug, options} -> options
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
