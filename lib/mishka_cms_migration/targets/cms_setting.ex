# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.CmsSetting do
  @moduledoc """
  The `"setting"` items of a source, the site's own name and pictures, written to the run's site's
  settings (`MishkaCmsCore.Runtime.Setting`) through the `:set` the Settings page's save runs
  (`MishkaCmsCore.Settings.put_as/4`), as the admin who pressed Import: the admin needs what
  writing the setting takes (`MishkaCmsCore.Settings.write_permission/1`,
  `admin:dashboard:setting` for these), and the core's own rules decide the rest.

  An item is one setting, by its source id:

    * `"title"` — the site's name, its `site.title`;
    * `"logo"` — its logo, `site.logo`, and `"icon"` — its icon, `site.favicon`: the item's
      `"value"` is the source id of a file, and the setting is the Media address of the file the
      same run, or an earlier one, wrote for it (`MishkaCmsMigration.Targets.CmsMedia.addresses/2`).
      An import whose file was not written, such as an SVG, skips it as `"file_missing"`; a dry
      run, which writes no file, does not;
    * `"tagline"` — the CMS has no setting for a tagline, so it is skipped as `"no_setting"`, in
      the dry run too, and so is any other.

  ## The site's own

  A setting the site already holds a value of its own for is never written over: read before
  anything is written, in the dry run too (`existing/2`), from the core's settings cache, so with
  no query, it is skipped as `"site_own_kept"`. A value the site takes from the installation's
  global settings, or an empty one, is not the site's own, and is written over by the site's own.

  A re-run is held to the rules every target is: a setting the source did not change is
  `"unchanged"`, and one an admin changed or removed in the CMS since is kept as the admin left it
  (`MishkaCmsMigration.Workers.Helpers.Decision`). One the source changed is written again through
  the same `:set`, which writes over the site's row and keeps its id.
  """

  use MishkaCmsMigration.Target,
    kind: "setting",
    resource: MishkaCmsCore.Runtime.Setting,
    create: :set,
    update: :set

  alias MishkaCmsCore.Settings
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Targets.CmsMedia

  @keys %{"title" => "site.title", "logo" => "site.logo", "icon" => "site.favicon"}
  @files ["logo", "icon"]

  @impl MishkaCmsMigration.Target
  def existing(items, context),
    do:
      for(
        item <- items,
        found = @keys |> Map.get(item.source_id) |> found(context.site_id),
        into: %{},
        do: {item.source_id, found}
      )

  @impl MishkaCmsMigration.Target
  def prepare(%Item{source_id: id, attrs: %{"value" => file}}, context, write) when id in @files,
    do: [file] |> CmsMedia.addresses(context) |> Map.get(to_string(file)) |> filed(context, write)

  def prepare(%Item{attrs: %{"value" => value}}, context, write),
    do: write.(%{context | prepared: value})

  @impl MishkaCmsMigration.Target
  def attrs(item, context),
    do: %{key: Map.fetch!(@keys, item.source_id), value: %{"value" => context.prepared}}

  defp found(nil, _site_id), do: {:skipped, "no_setting"}
  defp found(key, site_id), do: key |> Settings.get_own(nil, site_id) |> own()

  defp own(value) when value in [nil, ""], do: nil
  defp own(_value), do: {:skipped, "site_own_kept"}

  defp filed(nil, _context, _write), do: {:skipped, "file_missing"}
  defp filed(address, context, write), do: write.(%{context | prepared: address})
end
