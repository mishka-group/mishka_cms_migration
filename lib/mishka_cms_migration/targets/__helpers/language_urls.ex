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

  A Run again writes such links again after an admin changes the site's `Language in addresses`:
  `hash/2` is the item's hash with that mode added for an item that writes links, so the item is
  no longer `"unchanged"`. Links are rewritten for the new mode, unless the record was changed in
  the CMS since, which keeps it as it is. The menu's links stay fixed addresses: the core's
  navigation (`MishkaCmsCore.Install.StarterContent.nav_links/1`) can draw a path in the page's own
  language (`site_path/2`), but has no form for a link to one language's edition.

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
  @linked ["links", "pages"]

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

  @doc """
  `MishkaCmsMigration.Source.Item.hash/1`, with the site's language address mode added for an item
  that writes links: a menu, and a page or post whose content links to pages or posts of the
  source. Links are written as fixed addresses in that mode, so when the site's `Language in
  addresses` changes, such an item no longer matches what was recorded, and a Run again writes its
  links again (unless an admin changed it in the CMS since, which keeps it). Any other item hashes
  as it always did.
  """
  @spec hash(Item.t(), String.t()) :: String.t()
  def hash(item, site_id), do: stamped(Item.hash(item), linked?(item), site_id)

  defp stamped(hash, true, site_id), do: hash <> "@" <> Languages.url_mode(site_id)
  defp stamped(hash, false, _site_id), do: hash

  defp linked?(%Item{kind: "menu"}), do: true
  defp linked?(%Item{attrs: attrs}), do: Enum.any?(@linked, &(attrs[&1] not in [nil, %{}]))

  defp mode("prefix_all"), do: "prefix_all"
  defp mode(_prefix_others), do: nil

  defp decided(nil, _decision), do: :ok
  defp decided(_cause, "import"), do: :ok
  defp decided(_cause, "keep"), do: {:skipped, "waits_for_language_urls"}
  defp decided(cause, nil), do: {:undecided, @conflict <> ": " <> cause}
end
