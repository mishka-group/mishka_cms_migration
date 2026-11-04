# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.Helpers.LanguageUrls do
  @moduledoc """
  Whether the links an import writes may not match the site's addresses, for the targets that write
  links (`MishkaCmsMigration.Targets.CmsLayout`).

  A link is written as a fixed address in the way the run's site names the language in its
  addresses at that moment (`MishkaCmsCore.Runtime.Languages.url/3`, the site's `site.language_urls`
  setting). It does not follow the source's addresses when the source names the language in them,
  nor the site when an admin later changes how it names it. `cause/2` tells when that can happen:

    * `"polylang"` or `"wpml"` — the source runs that language plugin
      (`MishkaCmsMigration.Sources.WordPress`'s `extra/1` keeps it as `"languages"`), so its
      addresses carry a language prefix, such as `/fa/about/`;
    * `"prefix_all"` — the site gives every language a prefix, so the links are written with
      `/en/…` and an unprefixed source address is not the address they point at.

  The plugin is named first when both hold; a site that does not prefix its first language, with a
  source that runs no language plugin, has no cause.

  `call/2` makes a target that writes links wait for an admin's decision on such a run, as
  `"language_urls: <cause>"` (`MishkaCmsMigration.MigrationItem`'s Decide…): Write links for the
  site's current mode (`"import"`) goes on, and Wait (`"keep"`) skips the item as
  `"waits_for_language_urls"` until the admin has set up the site's languages, then decided.
  """

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Target

  @conflict "language_urls"

  @doc """
  What makes links written now differ from the source's, or `nil`. `languages` is the source's
  language plugin, `nil` for none.
  """
  @spec cause(String.t() | nil, String.t()) :: String.t() | nil
  def cause(languages, _site_id) when is_binary(languages), do: languages
  def cause(_none, site_id), do: site_id |> Languages.url_mode() |> mode()

  @doc """
  `:ok` for an item whose links need no decision, or one an admin decided to write for the site's
  current mode, `{:skipped, "waits_for_language_urls"}` for one an admin decided to wait with, and
  `{:undecided, "language_urls: <cause>"}` while no admin has decided.
  """
  @spec call(Item.t(), Target.context()) ::
          :ok | {:skipped, String.t()} | {:undecided, String.t()}
  def call(item, context),
    do:
      context.languages
      |> cause(context.site_id)
      |> decided(Target.decision(context, item, @conflict))

  defp mode("prefix_all"), do: "prefix_all"
  defp mode(_prefix_others), do: nil

  defp decided(nil, _decision), do: :ok
  defp decided(_cause, "import"), do: :ok
  defp decided(_cause, "keep"), do: {:skipped, "waits_for_language_urls"}
  defp decided(cause, nil), do: {:undecided, @conflict <> ": " <> cause}
end
