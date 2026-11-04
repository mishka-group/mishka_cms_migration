# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Test.Languages do
  @moduledoc """
  What a site that runs Polylang Pro or WPML would answer for the entries and terms the seeded
  WordPress has in English and Persian (`dev/wordpress/seed_polylang.sh`), DERIVED from what it
  really answered with Polylang's free plugin: the REST rows `record_polylang.sh` recorded
  (`rest/polylang-*`), which carry no language, and the export it recorded (`wxr/polylang.xml`),
  which carries every entry's and term's language and translations as Polylang's taxonomies.
  Neither Polylang Pro nor WPML can be installed on the test WordPress, so these shapes are made
  from their documentation, with the values the export says:

    * `pro_rows/1` — the recorded rows with Polylang Pro's `lang` and `translations` (every
      edition's id by code, its own among them; https://polylang.pro/doc/rest-api/);
    * `wpml_rows/1` — the recorded rows with the WPML REST API plugin's `wpml_current_locale` and
      `wpml_translations` (the other editions by locale, each with its `locale`, `id`, `slug`,
      `post_title` and `href`; https://github.com/shawnhooper/wpml-rest-api), the locales those
      Polylang recorded for its languages;
    * `wpml_export!/0` — the recorded export with WPML Export and Import's meta in place of
      Polylang's taxonomies: `_wpml_import_language_code` and `_wpml_import_translation_group` on
      each entry and term in a language
      (https://wpml.org/documentation/translating-your-contents/multilingual-content-import/).

  The export is read here with regular expressions and `Export.php/1`, not with the file source
  under test, so a mistake in the source cannot make these rows agree with it.
  """

  import MishkaCmsMigration.Test.WordPress, only: [recorded: 1]

  alias MishkaCmsMigration.Sources.WordPress.Export

  @export Path.expand("../fixtures/wordpress/wxr/polylang.xml", __DIR__)
  @taxonomies ~w(language term_language post_translations term_translations)

  @doc "The recorded export of the Polylang entries."
  @spec export() :: Path.t()
  def export, do: @export

  @doc "`recording`'s rows with Polylang Pro's `lang` and `translations` (derived)."
  @spec pro_rows(String.t()) :: [map()]
  def pro_rows(recording) do
    editions = editions(recording)

    for row <- recorded(recording) do
      case editions[row["id"]] do
        {language, group} -> Map.merge(row, %{"lang" => language, "translations" => group})
        nil -> row
      end
    end
  end

  @doc "`recording`'s rows with the WPML REST API plugin's fields (derived)."
  @spec wpml_rows(String.t()) :: [map()]
  def wpml_rows(recording) do
    editions = editions(recording)
    locales = locales()
    rows = recording |> recorded() |> Map.new(&{&1["id"], &1})

    for {id, row} <- rows do
      case editions[id] do
        {language, group} ->
          Map.merge(row, %{
            "wpml_current_locale" => locales[language],
            "wpml_translations" =>
              for(
                {other, other_id} <- group,
                other != language,
                into: %{},
                do: {locales[other], wpml_translation(locales[other], rows[other_id])}
              )
          })

        nil ->
          row
      end
    end
  end

  defp wpml_translation(locale, row),
    do: %{
      "locale" => locale,
      "id" => row["id"],
      "slug" => row["slug"],
      "post_title" => row["title"]["raw"],
      "href" => row["link"]
    }

  @doc """
  The recorded export with WPML Export and Import's meta in place of Polylang's taxonomies
  (derived), written to a file of its own, which is deleted when the test ends.
  """
  @spec wpml_export!() :: Path.t()
  def wpml_export! do
    %{entries: entries, terms: terms} = editions()

    groups =
      (Map.values(entries) ++ Map.values(terms))
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()
      |> Enum.with_index()
      |> Map.new()

    path = Path.join(System.tmp_dir!(), "wpml_#{System.unique_integer([:positive])}.xml")
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)

    @export
    |> File.read!()
    |> String.replace(~r/<wp:term>(?:(?!<\/wp:term>).)*<\/wp:term>\s*/s, &polylang_term_dropped/1)
    |> String.replace(
      ~r/\s*<category domain="(?:language|post_translations)"[^>]*>.*?<\/category>/,
      ""
    )
    |> String.replace(
      ~r/<item>.*?<\/item>/s,
      &wpml_meta(&1, {"wp:post_id", "wp:postmeta"}, entries, groups)
    )
    |> String.replace(
      ~r/<wp:(category|tag)>.*?<\/wp:\1>/s,
      &wpml_meta(&1, {"wp:term_id", "wp:termmeta"}, terms, groups)
    )
    |> then(&File.write!(path, &1))

    path
  end

  defp polylang_term_dropped(term) do
    case Regex.run(~r/<wp:term_taxonomy>(.*?)<\/wp:term_taxonomy>/, term) do
      [_, taxonomy] when taxonomy in @taxonomies -> ""
      _kept -> term
    end
  end

  defp wpml_meta(element, {id_tag, meta_tag}, editions, groups) do
    [_, id] = Regex.run(~r/<#{id_tag}>(\d+)<\/#{id_tag}>/, element)

    case editions[String.to_integer(id)] do
      {language, group} ->
        meta =
          for {key, value} <- [
                {"_wpml_import_language_code", language},
                {"_wpml_import_translation_group", "group-#{groups[group]}"}
              ],
              into: "",
              do:
                "<#{meta_tag}><wp:meta_key>#{key}</wp:meta_key><wp:meta_value><![CDATA[#{value}]]></wp:meta_value></#{meta_tag}>\n"

        String.replace(element, ~r/<\/(item|wp:category|wp:tag)>\z/, meta <> "</\\1>")

      nil ->
        element
    end
  end

  defp editions(recording) do
    %{entries: entries, terms: terms} = editions()
    if recording =~ ~r/categories|tags/, do: terms, else: entries
  end

  # Each entry's and term's language and group, by id, from the export: an entry's `language` term
  # and its `post_translations` group, else itself alone; a term's `term_translations` group.
  defp editions do
    xml = File.read!(@export)
    groups = groups(xml)

    entries =
      for [item] <- Regex.scan(~r/<item>.*?<\/item>/s, xml),
          [_, id] <- [Regex.run(~r/<wp:post_id>(\d+)<\/wp:post_id>/, item)],
          [_, language] <- [Regex.run(~r/<category domain="language" nicename="([^"]+)"/, item)],
          into: %{} do
        id = String.to_integer(id)

        group =
          case Regex.run(~r/<category domain="post_translations" nicename="([^"]+)"/, item) do
            [_, slug] -> groups[{"post_translations", slug}]
            nil -> %{language => id}
          end

        {id, {language, group}}
      end

    terms =
      for {{"term_translations", _slug}, group} <- groups,
          {language, id} <- group,
          into: %{},
          do: {id, {language, group}}

    %{entries: entries, terms: terms}
  end

  defp groups(xml),
    do:
      for(
        [term] <- Regex.scan(~r/<wp:term>.*?<\/wp:term>/s, xml),
        [_, taxonomy] <- [Regex.run(~r/<wp:term_taxonomy>(.*?)<\/wp:term_taxonomy>/, term)],
        taxonomy in ["post_translations", "term_translations"],
        [_, slug] <- [Regex.run(~r/<wp:term_slug>(.*?)<\/wp:term_slug>/, term)],
        [_, description] <- [Regex.run(~r/<!\[CDATA\[(a:.*?)\]\]>/, term)],
        into: %{},
        do: {{taxonomy, slug}, Export.php(description)}
      )

  defp locales do
    xml = File.read!(@export)

    for [term] <- Regex.scan(~r/<wp:term>.*?<\/wp:term>/s, xml),
        term =~ "<wp:term_taxonomy>language</wp:term_taxonomy>",
        [_, code] <- [Regex.run(~r/<wp:term_slug>(.*?)<\/wp:term_slug>/, term)],
        [_, description] <- [Regex.run(~r/<!\[CDATA\[(a:.*?)\]\]>/, term)],
        into: %{},
        do: {code, Export.php(description)["locale"]}
  end
end
