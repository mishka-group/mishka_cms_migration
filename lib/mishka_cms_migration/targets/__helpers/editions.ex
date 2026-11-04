# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.Helpers.Editions do
  @moduledoc """
  An item's language and the other editions of it, for the targets whose resource keeps one record
  per language, joined by `language_group_id` (`MishkaCmsCore.LanguageEditions`): the core's pages
  (`MishkaCmsMigration.Targets.CmsPage`) and the Blog's posts, categories and tags
  (`MishkaCmsMigration.Targets.BlogPost`, `MishkaCmsMigration.Targets.BlogCollection`,
  `MishkaCmsMigration.Targets.BlogTag`). A source names them in the item's `"language"` and
  `"translations"` (`%{"en" => "121"}`, the source id of each other edition by language), as the
  WordPress source reads them from Polylang or WPML (`MishkaCmsMigration.Sources.WordPress`,
  "Languages").

  ## Its record

  Each edition is a record of its own, in its language (`attrs/3`). The group's key is the
  resource's own: the id of its first record. An item none of whose editions has a record yet is
  written as a group of its own, which the resource's create makes it, and each edition written
  after it joins that group, by the `language_group_id` of the records its editions' items
  (`MishkaCmsMigration.MigrationItem`) were written to. So the editions are one group whatever
  order the source lists them in, and whichever of them an earlier run wrote. That costs two
  queries for an item with editions, its editions' items and their records, and none for one
  without. An item that names no language is in the site's main language
  (`MishkaCmsCore.Runtime.Languages.primary/1`).

  ## What the report says

  `note/3`: `"translations: fa, de"` for the group's original, the edition in the site's main
  language (else the first by code), naming its other editions, and `"translation_of: <title>
  (<code>)"` for every other edition, with the original's title as the item an earlier run or
  this one recorded it (`#<source id>` before any did), in a dry run and in an import.
  """

  require Ash.Query

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Target
  alias MishkaCmsMigration.Targets.Helpers.Read

  @doc """
  The language and group a target writes `item` with, to the records of `resource`: its
  `language`, and its `language_group_id` when an edition of it was written already (see "Its
  record"), which the input leaves out otherwise.
  """
  @spec attrs(Item.t(), Target.context(), Ash.Resource.t()) :: map()
  def attrs(item, context, resource) do
    item
    |> written(context)
    |> grouped(resource, context)
    |> Map.put(:language, language(item, context))
  end

  @doc "The language `item` is written in: its own, else the site's main language."
  @spec language(Item.t(), Target.context()) :: String.t()
  def language(%Item{attrs: %{"language" => language}}, _context) when is_binary(language),
    do: language

  def language(_item, context), do: Languages.primary(context.site_id)

  @doc """
  What the report says of `item`'s language and editions (see "What the report says"), followed by
  `also`, a target's own note, joined by `"; "`, or `nil` when neither says anything.
  """
  @spec note(Item.t(), Target.context(), String.t() | nil) :: String.t() | nil
  def note(item, context, also \\ nil),
    do:
      [edition_note(item, context), also]
      |> Enum.reject(&is_nil/1)
      |> noted()

  defp edition_note(%Item{attrs: %{"translations" => %{} = others}} = item, context)
       when map_size(others) > 0 do
    language = language(item, context)
    original = original([language | Map.keys(others)], Languages.primary(context.site_id))
    edition_note(item, others, language, original, context)
  end

  defp edition_note(_item, _context), do: nil

  defp edition_note(_item, others, original, original, _context),
    do: "translations: " <> (others |> Map.keys() |> Enum.sort() |> Enum.join(", "))

  defp edition_note(item, others, _language, original, context) do
    id = Map.fetch!(others, original)

    context.source_host
    |> MishkaCmsMigration.items_by_sources!(item.kind, [id],
      actor: context.actor,
      tenant: context.site_id
    )
    |> titled(id)
    |> then(&"translation_of: #{&1} (#{original})")
  end

  defp original(languages, primary),
    do: if(primary in languages, do: primary, else: Enum.min(languages))

  defp titled([%{title: title} | _], _id) when is_binary(title) and title != "", do: title
  defp titled(_unrecorded, id), do: "#" <> id

  defp noted([]), do: nil
  defp noted(notes), do: Enum.join(notes, "; ")

  defp written(%Item{attrs: %{"translations" => %{} = others}} = item, context)
       when map_size(others) > 0,
       do:
         context.source_host
         |> MishkaCmsMigration.items_by_sources!(item.kind, Map.values(others),
           actor: context.actor,
           tenant: context.site_id
         )
         |> Enum.flat_map(&target_id/1)

  defp written(_item, _context), do: []

  defp target_id(%{target_id: id}) when is_binary(id), do: [id]
  defp target_id(_never_written), do: []

  defp grouped([], _resource, _context), do: %{}

  defp grouped(ids, resource, context) do
    resource
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select([:id, :language_group_id])
    |> Read.call(context)
    |> Enum.find_value(%{}, &group/1)
  end

  defp group(%{language_group_id: group}) when is_binary(group), do: %{language_group_id: group}
  defp group(%{id: id}), do: %{language_group_id: id}
end
