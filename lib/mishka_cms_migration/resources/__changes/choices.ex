# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Resources.Changes.Choices do
  @moduledoc """
  Folds what the New import window's steps ask apart from the run's Advanced options into the run's
  `options`: the `bring` argument (the switches of what to bring, such as `"bring_posts"` and
  `"comments"`) and the `language` argument (the one language to put every item of an unknown or
  unpublished language in, blank to keep the source's languages), as the run's `"one_language"`.

      create :create do
        argument :bring, :map
        argument :language, :string
        change MishkaCmsMigration.Resources.Changes.Choices
      end

  It runs before the options are checked (`MishkaCmsMigration.MigrationRun.Options`), so a switch
  typed as `"false"` becomes a boolean and every key left alone keeps its default there. A language
  that is not one of the site's is refused in words, under the language field.
  """

  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.Languages

  @not_published dgettext_noop("errors", "Pick one of the site's languages.")

  @impl true
  def change(changeset, _opts, _context) do
    options = Ash.Changeset.get_attribute(changeset, :options) || %{}
    bring = Ash.Changeset.get_argument(changeset, :bring) || %{}
    language = changeset |> Ash.Changeset.get_argument(:language) |> chosen()

    merged =
      options
      |> stringified()
      |> Map.merge(stringified(bring))
      |> asked(language)

    changeset
    |> Ash.Changeset.force_change_attribute(:options, merged)
    |> published(language)
  end

  defp asked(options, nil), do: options
  defp asked(options, language), do: Map.put(options, "one_language", language)

  defp chosen(code) when is_binary(code), do: code
  defp chosen(_none), do: nil

  defp published(changeset, language) when language in [nil, ""], do: changeset

  defp published(%{tenant: tenant} = changeset, language) do
    site_id = tenant || Ash.Changeset.get_attribute(changeset, :site_id)

    case language in Languages.site(site_id) do
      true -> changeset
      false -> Ash.Changeset.add_error(changeset, field: :language, message: @not_published)
    end
  end

  defp stringified(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
