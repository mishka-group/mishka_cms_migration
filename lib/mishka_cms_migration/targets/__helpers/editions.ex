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

  The CMS keeps a record in several languages as one main record, its master, and a translation
  of it per other language: each a record of its own, in its language (`attrs/3`), whose
  `language_group_id` is the master's id, the key the master's own `language_group_id` holds too
  (`MishkaCmsCore.LanguageEditions`, `MishkaCmsCore.Runtime.Resources.Changes.SetLanguageGroupId`).
  The CMS's Add translation writes a translation the same way: the resource's create, with the
  master's group (`MishkaCmsCore.Runtime.PageEditions.translate/4`).

  The master is the group's original: the edition in the site's main language, else the first by
  code, since the CMS lets a record in any language lead its group. The original is written as a
  group of its own, which the resource's create makes it, and every other edition joins the group
  of the records its editions' items (`MishkaCmsMigration.MigrationItem`) were written to. An
  original written after other editions of it, by a later page of the source or a later run, then
  takes them over (`lead/4`): they, and any translation an admin added to them in the CMS, move to
  its group through the resource's update action, and their items record the new `updated_at`, so
  a later run does not take the move for an edit in the CMS. So the editions are one group, led by
  the original, whatever order the source lists them in, and whichever of them an earlier run
  wrote. That costs two queries for an item with editions, its editions' items and their records,
  one more and an update each when the original takes them over, and none for one without.

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
  an item that names no language waits for an admin's decision on `"language_unknown"`: writing it
  in the site's language could mislabel a translation. Polylang's free plugin names an entry's
  language over the REST API only by the address it serves it under, which the WordPress source
  reads (`MishkaCmsMigration.Sources.WordPress`, "Languages"), so this waits only for an entry no
  language's address holds. Import it in the site's main language (`"import"`) writes it so;
  Wait (`"keep"`) skips it as `"waits_for_language"`, for a run of the site's export file, which
  carries every entry's language. An item that names no language on a run of a source with no
  language plugin is in the site's main language (`MishkaCmsCore.Runtime.Languages.primary/1`).

  ## One language for the run

  A run whose New import window chose one language (`one_language` of its options,
  `MishkaCmsMigration.MigrationRun.one_language/2`, one of the site's languages) asks neither
  decision: an item that names no language, and one in a language the site does not publish in, is
  written in that language and waits for nothing, and the Items page says so in one line. An item
  in one of the site's languages keeps it, and the editions the source links stay linked.

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
  alias MishkaCmsMigration.MigrationItem
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Target
  alias MishkaCmsMigration.Targets.Helpers.Read

  @recorded ~w(source_host source_kind source_id run_id title source_slug source_parent
               source_modified_at content_hash target_resource target_id outcome reason extra)a
  @missing "language_missing"
  @unknown "language_unknown"
  @setting "site.languages"

  @doc false
  defmacro __using__(_opts) do
    quote do
      @impl MishkaCmsMigration.Target
      def prepare(item, context, write),
        do: MishkaCmsMigration.Targets.Helpers.Editions.prepare(item, context, __MODULE__, write)

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
    |> joined(context)
    |> grouped(resource, context)
    |> Map.put(:language, language(item, context))
  end

  @doc """
  Runs `write`, the import's write of `item` by `target`, and, when `item` is the original of its
  group (see "Its record"), moves the editions written before it into its group, as the admin,
  with `target`'s update action. Answers what `write` does, or the CMS's refusal of a move.
  """
  @spec lead(Item.t(), Target.context(), module(), (Target.context() -> result)) ::
          result | {:error, term()}
        when result: term()
  def lead(item, context, target, write),
    do: item |> original?(context) |> led(write.(context), item, context, target)

  @doc """
  The language `item` is written in: its own, else the site's main language; on a run that puts
  such items in one language (see "One language for the run"), that language for an item with none
  or with one the site does not publish in.
  """
  @spec language(Item.t(), Target.context()) :: String.t()
  def language(%Item{attrs: %{"language" => language}}, context) when is_binary(language),
    do: if(missing?(language, context), do: one(context) || language, else: language)

  def language(_item, context), do: one(context) || Languages.primary(context.site_id)

  @doc """
  What a target's `prepare/3` asks first: `:ok` for an item in one of the site's languages, or one
  an admin decided to import, after adding its language to the site; else `{:undecided, conflict}`,
  `{:skipped, "waits_for_language"}`, or the core's refusal of the setting.
  """
  @spec call(Item.t(), Target.context()) ::
          :ok | {:error, term()} | {:skipped, String.t()} | {:undecided, String.t()}
  def call(item, context), do: item |> waits(context) |> added(context)

  @doc """
  The `prepare/3` of `target`, a target whose write waits on nothing else
  (`MishkaCmsMigration.Target`): `write.(context)`, led by `lead/4`, once `call/2` answers `:ok`,
  else what it answers.
  """
  @spec prepare(Item.t(), Target.context(), module(), (Target.context() -> result)) ::
          result | {:error, term()} | {:skipped, String.t()} | {:undecided, String.t()}
        when result: term()
  def prepare(item, context, target, write),
    do: with(:ok <- call(item, context), do: lead(item, context, target, write))

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
    do: context |> one() |> missing_asked(language, item, context)

  defp missing_asked(nil, language, item, context),
    do: context |> Target.decision(item, @missing) |> missing_decided(language)

  defp missing_asked(_one, _language, _item, _context), do: :ok

  defp missing_decided("import", language), do: {:add, language}
  defp missing_decided(_undecided, language), do: {:undecided, @missing <> ": " <> language}

  defp unknown(nil, _item, _context), do: :ok

  defp unknown(_plugin, item, context),
    do: context |> one() |> unknown_asked(item, context)

  defp unknown_asked(nil, item, context),
    do: context |> Target.decision(item, @unknown) |> unknown()

  defp unknown_asked(_one, _item, _context), do: :ok

  defp one(%{options: options, site_id: site_id}),
    do: MishkaCmsMigration.MigrationRun.one_language(options, site_id)

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

  defp joined(item, context), do: item |> original?(context) |> joined(item, context)

  defp joined(true, _item, _context), do: []
  defp joined(false, item, context), do: written(item, context)

  defp original?(%Item{attrs: %{"translations" => %{} = others}} = item, context)
       when map_size(others) > 0 do
    language = language(item, context)
    original([language | Map.keys(others)], Languages.primary(context.site_id)) == language
  end

  defp original?(_item, _context), do: false

  defp led(true, {:ok, {:ok, %{id: id} = record}} = written, item, context, target) do
    resource = target.resource()

    item
    |> written(context)
    |> groups(resource, context)
    |> then(&[record.language_group_id | &1])
    |> Enum.reject(&(is_nil(&1) or &1 == id))
    |> Enum.uniq()
    |> taken_over(id, resource, target.actions().update, item, context)
    |> then(&if(&1 == :ok, do: written, else: &1))
  end

  defp led(_original, written, _item, _context, _target), do: written

  defp groups([], _resource, _context), do: []

  defp groups(ids, resource, context) do
    resource
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select([:id, :language_group_id])
    |> Read.call(context)
    |> Enum.map(&(&1.language_group_id || &1.id))
  end

  defp taken_over([], _id, _resource, _update, _item, _context), do: :ok

  defp taken_over(groups, id, resource, update, item, context) do
    resource
    |> Ash.Query.filter(language_group_id in ^groups or id in ^groups)
    |> Read.call(context)
    |> Enum.reduce_while(:ok, fn edition, :ok ->
      edition
      |> Ash.Changeset.for_update(update, %{language_group_id: id},
        actor: context.actor,
        tenant: context.site_id
      )
      |> Ash.update()
      |> moved(item, context)
    end)
  end

  defp moved({:ok, edition}, item, context) do
    MigrationItem
    |> Ash.Query.filter(
      source_host == ^context.source_host and source_kind == ^item.kind and
        target_id == ^edition.id and not is_nil(target_updated_at)
    )
    |> Read.call(context)
    |> Enum.each(
      &MishkaCmsMigration.record_item!(
        &1 |> Map.take(@recorded) |> Map.put(:target_updated_at, edition.updated_at),
        scope: context.scope
      )
    )

    {:cont, :ok}
  end

  defp moved({:error, error}, _item, _context), do: {:halt, {:error, error}}

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
