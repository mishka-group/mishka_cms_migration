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

  ## Google fonts

  An item's `@import` of a Google Fonts stylesheet (`https://fonts.googleapis.com/css…`), such as
  the one Elementor's global fonts make, is written as the `@font-face` rules Google answers for it.
  The site's Content-Security-Policy (`MishkaCmsWeb.Runtime.Plugs.SecurityHeaders`) refuses a
  stylesheet from Google on an admin page other than the builder's canvas, such as a page's
  preview, while its `font-src` lets every page load the font files from `fonts.gstatic.com`, so
  with the rules in the site's own CSS the fonts load wherever the CSS does, and a visitor's
  browser asks Google for no stylesheet, only for the files of the characters a page shows.

  In an import, the stylesheet is asked of Google before it is written (`prepare/3`), outside the
  write's transaction: one request for each such `@import`, with `Req`, as a browser asks it (a
  browser's `user-agent`, for Google to answer `woff2` files split by `unicode-range`), following
  no redirect and retrying nothing. A dry run asks nothing, and nor does a re-run that finds the
  stylesheet `"unchanged"`. Only the answer's `@font-face` rules are kept, each written again from
  its font descriptors (`font-family`, `font-style`, `font-weight`, `font-stretch`,
  `font-display`, `src`, `unicode-range`), read with igniter_css; an answer that is not a `200` of
  `text/css`, no answer, and one without a rule keep the item's `@import`, which a public page's
  policy allows, and its item records no hash (`recorded/2`), so the next run writes the stylesheet
  again and asks once more.

  `req_options` in the application environment are merged into every request, which is how the
  suite answers them from what Google answered:

      config :mishka_cms_migration, MishkaCmsMigration.Targets.CmsStylesheet,
        req_options: [plug: {Req.Test, MishkaCmsMigration.Sources.WordPress}]
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
  @google "fonts.googleapis.com"
  @browser "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) " <>
             "Chrome/130.0.0.0 Safari/537.36"
  @descriptors ~w(font-family font-style font-weight font-stretch font-display src unicode-range)

  @impl MishkaCmsMigration.Target
  def existing(items, context) do
    held = items |> Enum.map(& &1.attrs["name"]) |> held(context)

    for item <- items,
        record = held[item.attrs["name"]],
        into: %{},
        do: {item.source_id, kept(record, Target.decision(context, item, "site_has_own"))}
  end

  @impl MishkaCmsMigration.Target
  def prepare(item, context, write),
    do: write.(%{context | prepared: item.attrs["content"] |> google_imports() |> fonts()})

  @impl MishkaCmsMigration.Target
  def attrs(item, context),
    do: %{
      name: item.attrs["name"],
      description: item.attrs["description"],
      content: with_fonts(item.attrs["content"], context.prepared),
      kind: :theme,
      priority: @priority,
      active: true
    }

  @impl MishkaCmsMigration.Target
  def recorded(_item, %{prepared: [_ | _] = fonts}),
    do: fonts |> Enum.all?(&is_binary(elem(&1, 1))) |> asked_again()

  def recorded(_item, _context), do: %{}

  defp asked_again(true), do: %{}
  defp asked_again(false), do: %{content_hash: nil}

  defp held(names, context),
    do:
      Stylesheet
      |> Ash.Query.filter(name in ^names)
      |> Read.call(context)
      |> Map.new(&{&1.name, &1})

  defp kept(_record, "keep"), do: {:skipped, "site_own_kept"}
  defp kept(record, "import"), do: {:updated, record}
  defp kept(_record, nil), do: {:undecided, "site_has_own"}

  defp google_imports(css) when is_binary(css) do
    case IgniterCss.list_at_rules(css) do
      {:ok, rules} -> Enum.filter(rules, &google_import?/1)
      {:error, _refused} -> []
    end
  end

  defp google_imports(_none), do: []

  defp google_import?(%IgniterCss.AtRule{name: "import", target: target}) when is_binary(target),
    do: match?(%URI{scheme: "https", host: @google, path: "/css" <> _}, URI.parse(target))

  defp google_import?(_rule), do: false

  defp fonts([]), do: nil
  defp fonts(imports), do: Enum.map(imports, &{&1, &1.target |> asked() |> faces()})

  defp asked(url),
    do:
      [url: url, headers: [user_agent: @browser], redirect: false, retry: false]
      |> Req.new()
      |> Req.merge(req_options())
      |> Req.get()

  defp faces({:ok, %Req.Response{status: 200, body: css} = response}) when is_binary(css),
    do: response |> Req.Response.get_header("content-type") |> css_faces(css)

  defp faces(_not_answered), do: nil

  defp css_faces(["text/css" <> _charset], css) do
    case IgniterCss.get_at_rules(css, "font-face") do
      {:ok, [_ | _] = faces} -> Enum.map_join(faces, "\n", &face/1)
      _none_or_refused -> nil
    end
  end

  defp css_faces(_type, _css), do: nil

  defp face(%IgniterCss.AtRule{declarations: declarations}) do
    descriptors =
      for {name, value} <- declarations, name in @descriptors, do: "  #{name}: #{value};\n"

    "@font-face {\n#{descriptors}}"
  end

  defp with_fonts(css, [_ | _] = fonts) do
    fetched = for {rule, faces} <- fonts, is_binary(faces), do: {rule, faces}

    css
    |> without(Enum.map(fetched, &elem(&1, 0)))
    |> followed_by(Enum.map(fetched, &elem(&1, 1)))
  end

  defp with_fonts(css, _nothing_asked), do: css

  defp without(css, []), do: css

  defp without(css, rules) do
    {:ok, %{source: rest}} = IgniterCss.remove_at_rules(css, rules)
    rest
  end

  defp followed_by(css, []), do: css
  defp followed_by(css, faces), do: Enum.join([css | faces], "\n") <> "\n"

  defp req_options,
    do:
      :mishka_cms_migration
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:req_options, [])
end
