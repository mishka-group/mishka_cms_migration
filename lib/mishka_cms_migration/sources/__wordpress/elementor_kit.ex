# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Sources.WordPress.ElementorKit do
  @moduledoc """
  Elementor's Site Settings, the kit a site's Elementor pages are drawn with: its global colours
  and fonts, which a widget names by id (`__globals__`), and the theme tokens of the CMS they
  become.

  ## Where they are read

  The WordPress source asks Elementor's own REST route, `/elementor/v1/globals`, once when it
  connects, and only when the REST index lists Elementor's `elementor/v1`: the colours and the
  fonts of the active kit by id, as Elementor resolves them, its defaults for a kit nobody changed
  among them. An export carries the kit as an `elementor_library` post whose
  `_elementor_template_type` is `kit`, with its settings in `_elementor_page_settings`;
  `from_settings/1` makes them the same answer, with Elementor's own defaults (`#6EC1E4`, Roboto,
  ...) for the system colours and fonts the kit never saved. An export does not say which kit is
  active, so the export file source reads the last one made.

  ## The tokens

  `stylesheet/2` writes them as theme tokens (`@theme`) of a stylesheet of their own,
  `elementor-globals`, which the CMS builds into the site's CSS as it builds its own `site-theme`:

    * a colour is `--color-el-<id>`, and `--color-el-<id>-dark` its twin for the dark theme, the
      same colour until an admin changes it, as the site's own colours each have a `-dark` twin
      the markup pairs with `dark:`;
    * a font is `--font-el-<id>`, its family then `sans-serif`, with a Google Fonts `@import` of
      every family but the system ones Elementor lists (Arial, Tahoma, ...), in the weights the
      kit's fonts give it and 400 and 700. The site's Content-Security-Policy allows Google
      Fonts, and the CSS compiler puts a remote `@import` ahead of everything else.

  A page names a colour through the builder's own style setting, `var(--color-el-<id>)`
  (`colour/1`), and its twin and a font by their token classes (`dark_class/2`, `font_class/1`),
  so Tailwind keeps only the tokens a page uses. `<id>` is Elementor's own: `primary`,
  `secondary`, `text`, `accent`, or the seven characters of a custom one, as in Elementor's
  `--e-global-color-<id>`. An id of anything but lower-case letters and digits, a colour that is
  not a hex, RGB or HSL value, and a family of anything but letters, digits, spaces, `-` and `_`
  are left out.
  """

  @name "elementor-globals"
  @system ~w(primary secondary text accent)

  # Elementor's own, for a kit that never saved its system colours or fonts
  # (`core/kits/documents/tabs/global-colors.php`, `global-typography.php`).
  @default_colors [
    %{"_id" => "primary", "title" => "Primary", "color" => "#6EC1E4"},
    %{"_id" => "secondary", "title" => "Secondary", "color" => "#54595F"},
    %{"_id" => "text", "title" => "Text", "color" => "#7A7A7A"},
    %{"_id" => "accent", "title" => "Accent", "color" => "#61CE70"}
  ]

  @default_typography [
    %{
      "_id" => "primary",
      "title" => "Primary",
      "typography_typography" => "custom",
      "typography_font_family" => "Roboto",
      "typography_font_weight" => "600"
    },
    %{
      "_id" => "secondary",
      "title" => "Secondary",
      "typography_typography" => "custom",
      "typography_font_family" => "Roboto Slab",
      "typography_font_weight" => "400"
    },
    %{
      "_id" => "text",
      "title" => "Text",
      "typography_typography" => "custom",
      "typography_font_family" => "Roboto",
      "typography_font_weight" => "400"
    },
    %{
      "_id" => "accent",
      "title" => "Accent",
      "typography_typography" => "custom",
      "typography_font_family" => "Roboto",
      "typography_font_weight" => "500"
    }
  ]

  # The families Elementor counts as the system's own (`includes/fonts.php`), which it never
  # loads from Google.
  @system_fonts [
    "Arial",
    "Tahoma",
    "Verdana",
    "Helvetica",
    "Times New Roman",
    "Trebuchet MS",
    "Georgia"
  ]

  @id ~r/\A[a-z0-9]+\z/
  @hex ~r/\A#(?:[0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})\z/i
  @functional ~r/\A(?:rgb|hsl)a?\([0-9.,%\s\/]+\)\z/i
  @family ~r/\A[A-Za-z0-9][A-Za-z0-9 _-]{0,99}\z/
  @weights %{"normal" => 400, "bold" => 700}
  @loaded_weights [400, 700]

  @typedoc """
  The globals as `/elementor/v1/globals` answers them: `"colors"` and `"typography"`, each a map of
  id to `%{"id", "title", "value"}`, a colour's value its CSS colour and a font's its typography
  settings (`typography_font_family`, `typography_font_weight`, `typography_font_size`, ...).
  """
  @type globals :: %{optional(String.t()) => %{optional(String.t()) => map()}}

  @typedoc """
  The globals a page is converted with (`read/1`): each valid colour's value and each font's
  settings by id, and the id of the first font of each family.
  """
  @type read :: %{
          colours: %{String.t() => String.t()},
          typography: %{String.t() => map()},
          families: %{String.t() => String.t()}
        }

  @doc """
  A kit's `_elementor_page_settings` as `/elementor/v1/globals` answers its globals: its system and
  custom colours and fonts by id, Elementor's defaults for the system ones it never saved.
  """
  @spec from_settings(map() | term()) :: globals()
  def from_settings(%{} = settings),
    do: %{
      "colors" =>
        settings
        |> listed("system_colors", @default_colors)
        |> Enum.concat(listed(settings, "custom_colors", []))
        |> answered(fn item -> item["color"] end),
      "typography" =>
        settings
        |> listed("system_typography", @default_typography)
        |> Enum.concat(listed(settings, "custom_typography", []))
        |> answered(&Map.drop(&1, ["_id", "title"]))
    }

  def from_settings(_no_settings), do: from_settings(%{})

  @doc "`globals` as a page is converted with them (`t:read/0`)."
  @spec read(globals() | term()) :: read()
  def read(globals) do
    fonts = fonts(globals)

    %{
      colours: for({id, _title, value} <- colours(globals), into: %{}, do: {id, value}),
      typography: for({id, _title, settings} <- fonts, into: %{}, do: {id, settings}),
      families:
        for(
          {id, _title, settings} <- Enum.reverse(fonts),
          family = family(settings),
          into: %{},
          do: {family, id}
        )
    }
  end

  @doc """
  The stylesheet `globals` become, as the stylesheet target writes it: its `"name"`,
  `"description"` (naming `host`, the site they came from) and `"content"`, the tokens; `nil` when
  they hold no colour and no font.
  """
  @spec stylesheet(globals() | term(), String.t() | nil) :: map() | nil
  def stylesheet(globals, host) do
    case {colours(globals), fonts(globals)} do
      {[], []} ->
        nil

      {colours, fonts} ->
        %{
          "name" => @name,
          "description" => description(host),
          "content" => css(colours, Enum.filter(fonts, &family(elem(&1, 2))))
        }
    end
  end

  @doc "The builder's style value for the colour `id`: `var(--color-el-<id>)`."
  @spec colour(String.t()) :: String.t()
  def colour(id), do: "var(--color-el-#{id})"

  @doc """
  The class of the colour `id`'s dark twin under the Tailwind `prefix` it colours: `"text"` makes
  `dark:text-el-<id>-dark`, `"bg"` `dark:bg-el-<id>-dark`.
  """
  @spec dark_class(String.t(), String.t()) :: String.t()
  def dark_class(prefix, id), do: "dark:#{prefix}-el-#{id}-dark"

  @doc "The class of the font `id`'s family: `font-el-<id>`."
  @spec font_class(String.t()) :: String.t()
  def font_class(id), do: "font-el-#{id}"

  @doc "The family a font's settings name, when it is one a stylesheet can name; else `nil`."
  @spec family(map()) :: String.t() | nil
  def family(%{"typography_font_family" => family}) when is_binary(family),
    do: family |> String.trim() |> named(@family)

  def family(_settings), do: nil

  defp listed(settings, key, default), do: settings |> Map.get(key) |> saved(default)

  defp saved([_ | _] = items, _default), do: Enum.filter(items, &is_map/1)
  defp saved(_none, default), do: default

  defp answered(items, value),
    do:
      for(
        %{"_id" => id} = item <- items,
        is_binary(id),
        into: %{},
        do: {id, %{"id" => id, "title" => item["title"], "value" => value.(item)}}
      )

  # Each valid colour, `{id, title, value}`, the system ones first in Elementor's order, then the
  # custom ones by id: one order for both sources, so an item's hash does not move with JSON's.
  defp colours(%{"colors" => %{} = colours}),
    do:
      for(
        {id, %{"value" => value} = colour} <- colours,
        Regex.match?(@id, id),
        value = colour_value(value),
        do: {id, title(colour), value}
      )
      |> Enum.sort_by(&order/1)

  defp colours(_globals), do: []

  defp fonts(%{"typography" => %{} = fonts}),
    do:
      for(
        {id, %{"value" => %{} = settings} = font} <- fonts,
        Regex.match?(@id, id),
        do: {id, title(font), settings}
      )
      |> Enum.sort_by(&order/1)

  defp fonts(_globals), do: []

  defp order({id, _title, _value}), do: {Enum.find_index(@system, &(&1 == id)) || 4, id}

  defp colour_value(value) when is_binary(value) do
    value = String.trim(value)
    named(String.downcase(value), @hex) || named(value, @functional)
  end

  defp colour_value(_value), do: nil

  defp named(value, pattern), do: pattern |> Regex.match?(value) |> matched(value)

  defp matched(true, value), do: value
  defp matched(false, _value), do: nil

  # A title is the admin's own words, written into a CSS comment: nothing that could close it.
  defp title(%{"title" => title}) when is_binary(title),
    do: title |> String.replace(~r/[^\p{L}\p{N} .,&()'_-]/u, "") |> String.trim()

  defp title(_item), do: ""

  defp description(nil), do: "Elementor's global colours and fonts."
  defp description(host), do: "Elementor's global colours and fonts, from #{host}."

  defp css(colours, fonts) do
    tokens =
      Enum.flat_map(colours, fn {id, title, value} ->
        commented(title) ++
          ["  --color-el-#{id}: #{value};", "  --color-el-#{id}-dark: #{value};"]
      end) ++
        Enum.flat_map(fonts, fn {id, title, settings} ->
          commented(title) ++ [~s(  --font-el-#{id}: "#{family(settings)}", sans-serif;)]
        end)

    Enum.join(
      [
        "/* Elementor's global colours and fonts. The dark theme shows a colour's -dark twin: " <>
          "the same colour until you change it. */"
      ] ++ imported(fonts) ++ ["", "@theme {"] ++ tokens ++ ["}", ""],
      "\n"
    )
  end

  defp commented(""), do: []
  defp commented(title), do: ["  /* #{title} */"]

  # One `@import` of every family Google serves, each in the weights its fonts give it.
  defp imported(fonts) do
    loaded =
      for {_id, _title, settings} <- fonts,
          family = family(settings),
          family not in @system_fonts,
          do: {family, weight(settings["typography_font_weight"])}

    weights = Enum.group_by(loaded, &elem(&1, 0), &elem(&1, 1))

    loaded
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.map(&{&1, weights |> Map.fetch!(&1) |> List.flatten()})
    |> import_rule()
  end

  defp import_rule([]), do: []

  defp import_rule(families),
    do: [~s|@import url("https://fonts.googleapis.com/css?family=#{asked(families)}");|]

  defp asked(families),
    do:
      Enum.map_join(families, "%7C", fn {family, weights} ->
        String.replace(family, " ", "+") <>
          ":" <>
          (weights
           |> Enum.concat(@loaded_weights)
           |> Enum.uniq()
           |> Enum.sort()
           |> Enum.join(","))
      end) <> "&display=swap"

  defp weight(value) when is_binary(value) do
    case Map.fetch(@weights, value) do
      {:ok, weight} -> [weight]
      :error -> value |> Integer.parse() |> numeric_weight()
    end
  end

  defp weight(value) when is_integer(value), do: numeric_weight({value, ""})
  defp weight(_none), do: []

  defp numeric_weight({weight, ""}) when weight in 100..900//100, do: [weight]
  defp numeric_weight(_not_a_weight), do: []
end
