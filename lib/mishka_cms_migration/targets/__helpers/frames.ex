# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.Helpers.Frames do
  @moduledoc """
  The video players a post's or a page's content frames, allowed on the run's site, for the
  targets that write the content (`MishkaCmsMigration.Targets.BlogPost`,
  `MishkaCmsMigration.Targets.CmsPage`). The CMS's Content-Security-Policy lets a page frame only
  the origins of the site's `security.frame_origins` setting, so an imported YouTube or Vimeo
  player would show nothing without its origin there.

  Only the players' own origins are added: `https://www.youtube.com`, `https://youtube.com`,
  `https://www.youtube-nocookie.com`, `https://youtube-nocookie.com` and
  `https://player.vimeo.com`, each when an `<iframe>` of the content plays from it. An `<iframe>`
  from any other origin is kept in the content, and is shown only once an admin allows its origin.

  `call/2` adds the origins the site does not allow yet to the site's own setting, after the ones it
  allows (its own, or the installation's global ones it takes), through
  `MishkaCmsCore.Settings.put_as/4` as the admin, and the settings cache knows them once it answers:
  a later item of the same run, which reads the cache, adds nothing, so a run adds each origin once.
  An admin who may not write the setting (`MishkaCmsCore.Settings.write_permission/1`,
  `admin:dashboard:setting`; the job's admin carries their permissions, so it costs no query) adds
  none, and the content is written all the same: its player is blocked until an admin allows it.
  `note/2` says which for the report, naming the origins, `"frames_allowed: <origins>"` or
  `"frames_blocked: <origins>"`, in a dry run too.
  """

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Settings
  alias MishkaCmsMigration.Target

  @key "security.frame_origins"
  @players ~w(https://www.youtube.com https://youtube.com https://www.youtube-nocookie.com
              https://youtube-nocookie.com https://player.vimeo.com)

  @doc """
  Allows on the run's site the players `html` frames that it does not allow yet, when the admin may:
  `:ok`, or the core's refusal of the write.
  """
  @spec call(String.t(), Target.context()) :: :ok | {:error, term()}
  def call(html, context), do: html |> players() |> missing(context) |> allowed(context)

  @doc """
  `"frames_allowed: <origins>"` when `html` frames players the run's site does not allow yet and
  the admin may allow them, `"frames_blocked: <origins>"` when they may not, else `nil`; the
  origins are joined by `", "`.
  """
  @spec note(String.t(), Target.context()) :: String.t() | nil
  def note(html, context), do: html |> players() |> missing(context) |> noted(context)

  defp players(html),
    do:
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("iframe[src]")
      |> LazyHTML.attribute("src")
      |> Enum.map(&origin/1)
      |> Enum.filter(&(&1 in @players))
      |> Enum.uniq()

  defp missing([], _context), do: []
  defp missing(players, context), do: players -- Settings.get(@key, [], context.site_id)

  defp origin(src), do: src |> String.trim() |> URI.parse() |> origin_of()

  defp origin_of(%URI{scheme: "https", host: host, port: 443}) when is_binary(host),
    do: "https://" <> String.downcase(host)

  defp origin_of(_uri), do: nil

  defp permitted?(actor),
    do: AccessPermissions.match?(actor, %{}, permissions: Settings.write_permission(@key))

  defp allowed([], _context), do: :ok
  defp allowed(missing, context), do: allowed(missing, permitted?(context.actor), context)

  defp allowed(_missing, false, _context), do: :ok

  defp allowed(missing, true, context),
    do:
      context.actor
      |> Settings.put_as(@key, Settings.get(@key, [], context.site_id) ++ missing,
        site_id: context.site_id
      )
      |> written()

  defp written({:ok, _origins}), do: :ok
  defp written({:error, error}), do: {:error, error}

  defp noted([], _context), do: nil

  defp noted(missing, context),
    do: noted(permitted?(context.actor)) <> ": " <> Enum.join(missing, ", ")

  defp noted(true), do: "frames_allowed"
  defp noted(false), do: "frames_blocked"
end
