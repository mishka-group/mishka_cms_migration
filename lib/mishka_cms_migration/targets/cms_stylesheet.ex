# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.CmsStylesheet do
  @moduledoc """
  The `"stylesheet"` items of a source, such as Elementor's global colours and fonts as theme tokens
  (`MishkaCmsMigration.Sources.WordPress.ElementorKit`), written as a stylesheet of the run's site
  (`MishkaCmsCore.Runtime.Stylesheet`) through the `:create` and `:update` the Stylesheets page
  runs, as the admin who pressed Import: the admin needs `admin:dashboard:runtime:stylesheet` (or
  the code permission), and the core's own rules decide the rest. A stylesheet Tailwind will not
  build is refused (`MishkaCmsCore.Runtime.Resources.Changes.StylesheetCompiles`), and each write
  builds the site's CSS again.

  An item's `"name"`, `"description"` and `"content"` are the stylesheet's own. It is written as a
  `:theme` stylesheet, active, after the site's own `site-theme` (priority 20), so the tokens it
  declares are there before Tailwind makes a page's classes. An admin edits it, turns it off or
  deletes it on the Stylesheets page like any other.

  ## The site's own

  A stylesheet of the same name the site already has, which no run wrote, is never written over on
  the import's own say: read before anything is written, in the dry run too (`existing/2`), the
  item waits for an admin's decision as `"site_has_own"` (`MishkaCmsMigration.MigrationItem`'s
  Decide…). Keep the site's own skips it as `"site_own_kept"`; Use the WordPress one writes the
  item over that stylesheet through the `:update`, which keeps its id.

  A re-run is held to the rules every target is: a stylesheet the source did not change is
  `"unchanged"`, and one an admin changed or deleted in the CMS since is kept as the admin left it
  (`MishkaCmsMigration.Workers.Helpers.Decision`).
  """

  use MishkaCmsMigration.Target,
    kind: "stylesheet",
    resource: MishkaCmsCore.Runtime.Stylesheet,
    create: :create,
    update: :update

  require Ash.Query

  alias MishkaCmsCore.Runtime.Stylesheet
  alias MishkaCmsMigration.Target
  alias MishkaCmsMigration.Targets.Helpers.Read

  @priority 20

  @impl MishkaCmsMigration.Target
  def existing(items, context) do
    held = items |> Enum.map(& &1.attrs["name"]) |> held(context)

    for item <- items,
        record = held[item.attrs["name"]],
        into: %{},
        do: {item.source_id, kept(record, Target.decision(context, item, "site_has_own"))}
  end

  @impl MishkaCmsMigration.Target
  def attrs(item, _context),
    do: %{
      name: item.attrs["name"],
      description: item.attrs["description"],
      content: item.attrs["content"],
      kind: :theme,
      priority: @priority,
      active: true
    }

  defp held(names, context),
    do:
      Stylesheet
      |> Ash.Query.filter(name in ^names)
      |> Read.call(context)
      |> Map.new(&{&1.name, &1})

  defp kept(_record, "keep"), do: {:skipped, "site_own_kept"}
  defp kept(record, "import"), do: {:updated, record}
  defp kept(_record, nil), do: {:undecided, "site_has_own"}
end
