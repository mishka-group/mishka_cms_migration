# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Live.Admin.Dashboard.LanguageNotice do
  @moduledoc """
  The warning a run shows when the links an import writes may not match the site's language
  addresses (`MishkaCmsMigration.Targets.Helpers.LanguageUrls.cause/2`): the source runs Polylang or
  WPML, or the site gives every language a prefix. `warning/1` draws it as the admin's own warning
  (Gervaz's `:warning` alert, `MishkaGervaz.UIAdapters.Tailwind.alert/1`) in a run's expanded row
  (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.RunDetails`) and on the Items page's head
  (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Index`): what the cause is, what is affected, a
  tip and a suggestion. A run with no cause draws nothing. The cause is read from the run's `extra`
  and the site's setting, which the settings cache answers, so it adds no query.

  The part that asks for an answer is the main menu's Needs your decision on the Items page, whose
  Decide… offers Write links for the site's current mode and Wait. For a source that runs a
  language plugin it also says how translations are imported, and what of them waits for a decision
  (`MishkaCmsMigration.Targets.Helpers.Editions`).
  """

  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaGervaz.UIAdapters.Tailwind, only: [alert: 1]

  alias MishkaCmsMigration.MigrationRun
  alias MishkaCmsMigration.Targets.Helpers.LanguageUrls

  attr :run, MigrationRun, required: true, doc: "the run, with its site and extra"
  attr :class, :string, default: nil, doc: "extra classes of the warning's box"

  @doc "The warning for `run`, or nothing when its links need no decision."
  def warning(assigns) do
    assigns =
      assign(
        assigns,
        :cause,
        LanguageUrls.cause(assigns.run.extra["languages"], assigns.run.site_id)
      )

    ~H"""
    <div :if={@cause} data-role="language-urls-warning" data-cause={@cause} class={@class}>
      <.alert
        type={:warning}
        icon="hero-exclamation-triangle"
        title={gettext("Imported links may not match the site's language addresses")}
      >
        <p class="m-0">
          {explained(@cause)}
          {gettext(
            "Menu links, links inside posts and pages, and redirects are written as fixed addresses, in the way this site names the language now."
          )}
        </p>
        <p :if={@cause in ["polylang", "wpml"]} class="m-0 mt-1.5" data-role="language-editions">
          <strong>{gettext("Translations:")}</strong>
          {gettext(
            "Each translation is imported in its own language and linked to its other editions. One in a language the site does not publish in, or whose language the source does not say (Polylang's free plugin says none over the REST API, and WPML's lists its default language alone), waits for your decision. The site's export file (Tools > Export) carries every translation and its language."
          )}
        </p>
        <p class="m-0 mt-1.5">
          <strong>{gettext("Tip:")}</strong>
          {gettext(
            "Choose the site's Language in addresses (Settings) before importing: links written under another choice stop matching, or break, when you switch it later."
          )}
        </p>
        <p class="m-0 mt-1.5">
          <strong>{gettext("Suggestion:")}</strong>
          {gettext(
            "The main menu needs your decision on the Items page: Write links for the site's current mode, or Wait until the site's languages are set."
          )}
        </p>
      </.alert>
    </div>
    """
  end

  defp explained("polylang"), do: explained_plugin("Polylang")
  defp explained("wpml"), do: explained_plugin("WPML")

  defp explained("prefix_all"),
    do: gettext("This site gives every language a prefix in its addresses, such as /en/blog.")

  defp explained_plugin(plugin),
    do:
      gettext(
        "The source runs %{plugin}, so its addresses carry a language prefix, such as /fa/about.",
        plugin: plugin
      )
end
