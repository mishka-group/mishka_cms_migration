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
  without.

  ## A language the site does not publish in

  An item in a language that is not one of the site's (`MishkaCmsCore.Runtime.Languages.site/1`)
  waits for an admin's decision on `"language_missing"`, its reason naming the code
  (`"language_missing: fa"`), in a dry run (`waiting/2`) and in an import (`call/2`), for an item an
  earlier import wrote as for a new one. Add the language to the site (`"import"`) adds it to the
  end of the site's `site.languages` as the admin (`MishkaCmsCore.Settings.put_as/4`) before the
  item is written, and the report says so (`"language_added: fa"`); the items in that language
  written after it then wait on nothing. Leave the translation out leaves the item out.

  ## A language the source does not say

  On a run whose source runs a language plugin (`MishkaCmsMigration.Target`'s context, `languages`),
  an item that names no language waits for an admin's decision on `"language_unknown"`: Polylang's
  free plugin says no entry's language over the REST API, so writing it in the site's language
  could mislabel a translation. Import it in the site's main language (`"import"`) writes it so;
  Wait (`"keep"`) skips it as `"waits_for_language"`, for a run of the site's export file, which
  carries every entry's language. An item that names no language on a run of a source with no
  language plugin is in the site's main language (`MishkaCmsCore.Runtime.Languages.primary/1`).

  ## What the report says

  `note/3`: `"translations: fa, de"` for the group's original, the edition in the site's main
  language (else the first by code), naming its other editions, and `"translation_of: <title>
  (<code>)"` for every other edition, with the original's title as the item an earlier run or
  this one recorded it (`#<source id>` before any did), in a dry run and in an import; and
  `"language_added: <code>"` once an admin decided to add the item's language.
  """

  require Ash.Query

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Settings
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Target
  alias MishkaCmsMigration.Targets.Helpers.Read

  @missing "language_missing"
  @unknown "language_unknown"
  @setting "site.languages"

  @doc false
  defmacro __using__(_opts) do
    quote do
      @impl MishkaCmsMigration.Target
      def prepare(item, context, write),
        do: MishkaCmsMigration.Targets.Helpers.Editions.prepare(item, context, write)

      @impl MishkaCmsMigration.Target
      def waiting(item, context),
        do: MishkaCmsMigration.Targets.Helpers.Editions.waiting(item, context)
    end
  end

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
  What a target's `prepare/3` asks first: `:ok` for an item in one of the site's languages, or one
  an admin decided to import, after adding its language to the site; else `{:undecided, conflict}`,
  `{:skipped, "waits_for_language"}`, or the core's refusal of the setting.
  """
  @spec call(Item.t(), Target.context()) ::
          :ok | {:error, term()} | {:skipped, String.t()} | {:undecided, String.t()}
  def call(item, context), do: item |> waits(context) |> added(context)

  @doc """
  The `prepare/3` of a target whose write waits on nothing else (`MishkaCmsMigration.Target`):
  `write.(context)` once `call/2` answers `:ok`, else what it answers.
  """
  @spec prepare(Item.t(), Target.context(), (Target.context() -> result)) ::
          result | {:error, term()} | {:skipped, String.t()} | {:undecided, String.t()}
        when result: term()
  def prepare(item, context, write), do: with(:ok <- call(item, context), do: write.(context))

  @doc "What a target's `waiting/2` answers in a dry run: what `call/2` would, without writing."
  @spec waiting(Item.t(), Target.context()) :: Target.found() | nil
  def waiting(item, context), do: item |> waits(context) |> planned()

  @doc """
  What the report says of `item`'s language and editions (see "What the report says"), followed by
  `also`, a target's own note, joined by `"; "`, or `nil` when neither says anything.
  """
  @spec note(Item.t(), Target.context(), String.t() | nil) :: String.t() | nil
  def note(item, context, also \\ nil),
    do:
      [added_note(waits(item, context)), edition_note(item, context), also]
      |> Enum.reject(&is_nil/1)
      |> noted()

  defp waits(%Item{attrs: %{"language" => language}} = item, context) when is_binary(language),
    do: language |> missing?(context) |> missing(language, item, context)

  defp waits(item, context), do: context |> Map.get(:languages) |> unknown(item, context)

  defp missing?(language, context), do: language not in Languages.site(context.site_id)

  defp missing(false, _language, _item, _context), do: :ok

  defp missing(true, language, item, context),
    do: context |> Target.decision(item, @missing) |> missing_decided(language)

  defp missing_decided("import", language), do: {:add, language}
  defp missing_decided(_undecided, language), do: {:undecided, @missing <> ": " <> language}

  defp unknown(nil, _item, _context), do: :ok

  defp unknown(_plugin, item, context),
    do: context |> Target.decision(item, @unknown) |> unknown()

  defp unknown("import"), do: :ok
  defp unknown("keep"), do: {:skipped, "waits_for_language"}
  defp unknown(nil), do: {:undecided, @unknown}

  defp added({:add, language}, context),
    do:
      context.actor
      |> Settings.put_as(@setting, Languages.site(context.site_id) ++ [language],
        site_id: context.site_id
      )
      |> stored()

  defp added(answer, _context), do: answer

  defp stored({:ok, _languages}), do: :ok
  defp stored({:error, error}), do: {:error, error}

  defp planned(:ok), do: nil
  defp planned({:add, _language}), do: nil
  defp planned(waiting), do: waiting

  defp added_note({:add, language}), do: "language_added: " <> language
  defp added_note(_answer), do: nil

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
