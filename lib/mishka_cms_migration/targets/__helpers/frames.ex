# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.Helpers.Frames do
  @moduledoc """
  The video players a post's or a page's content frames, allowed on the run's site, for the
  targets that write the content (`MishkaCmsMigration.Targets.BlogPost`,
  `MishkaCmsMigration.Targets.CmsPage`). The CMS's Content-Security-Policy lets a page frame only
  the origins of the site's `security.frame_origins` setting (Sites pages may embed), so an
  imported YouTube or Vimeo player would show nothing without its origin there.

  Only the players' own origins are added: `https://www.youtube.com`, `https://youtube.com`,
  `https://www.youtube-nocookie.com`, `https://youtube-nocookie.com` and
  `https://player.vimeo.com`, each when an `<iframe>` of the content plays from it. An `<iframe>`
  from any other origin is kept in the content, and is shown only once an admin allows its origin.

  `call/2` adds the origins the site does not allow yet to the site's own setting, after the ones it
  allows (its own, or the installation's global ones it takes), through
  `MishkaCmsCore.Settings.put_as/4` as the admin, and the settings cache knows them once it answers:
  a later item of the same run, which reads the cache, adds nothing, so a run adds each origin once.
  Whether the admin may write the setting (`MishkaCmsCore.Settings.write_permission/1`,
  `admin:dashboard:setting`) is read from the permissions the job's admin carries, so it costs no
  query.

  ## An admin who may not allow them

  An item whose players the site does not allow, imported by an admin who may not change the
  setting, is never written with a player that shows nothing: it waits for a decision as
  `"player_not_allowed"` (`MishkaCmsMigration.MigrationItem`'s Decide…), in a dry run through the
  target's `waiting/2` (`waiting/2`) and in an import through its `prepare/3` (`call/2`), for an
  item an earlier import wrote as for a new one. Wait for an admin skips it as `"waits_for_admin"`
  until a run by an admin who may
  allow the players writes it with them; Import without the player writes it with those
  `<iframe>`s left out of its content (`playable/2`), and the report says so (`"player_left_out"`).
  `note/2` says which for the report, `"frames_allowed: <origins>"` naming the origins when the
  admin allows them, in a dry run too.
  """

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Settings
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Target

  @key "security.frame_origins"
  @conflict "player_not_allowed"
  @players ~w(https://www.youtube.com https://youtube.com https://www.youtube-nocookie.com
              https://youtube-nocookie.com https://player.vimeo.com)

  @doc """
  Allows on the run's site the players `item`'s content frames that it does not allow yet, when the
  admin may: `:ok`, or the core's refusal of the write. For an admin who may not, `:ok` once an
  admin decided to import the item without them, else what `waiting/2` says.
  """
  @spec call(Item.t(), Target.context()) ::
          :ok | {:error, term()} | {:skipped, String.t()} | {:undecided, String.t()}
  def call(item, context), do: item |> missing(context) |> allowed(item, context)

  @doc """
  What a dry run plans for `item` (the target's `waiting/2`) whose content frames a player the site
  does not allow, for an admin who may not allow it: `{:undecided, "player_not_allowed"}` until an
  admin decides,
  `{:skipped, "waits_for_admin"}` once one decided to wait for an admin who may, and `nil`, to be
  written, once one decided to import it without the player, for an admin who may allow it, and
  for an item that frames no such player.
  """
  @spec waiting(Item.t(), Target.context()) :: {:undecided | :skipped, String.t()} | nil
  def waiting(item, context), do: item |> missing(context) |> waits(item, context)

  @doc """
  What the report says of `item`'s players: `"frames_allowed: <origins>"` when its content frames
  players the run's site does not allow yet and the admin may allow them, the origins joined by
  `", "`; `"player_left_out"` when they may not and an admin decided to import it without the
  player, `"player_not_allowed"` or `"waits_for_admin"` while it waits, else `nil`.
  """
  @spec note(Item.t(), Target.context()) :: String.t() | nil
  def note(item, context), do: item |> missing(context) |> noted(item, context)

  @doc """
  `html` without the `<iframe>`s of a player the run's site does not allow, for an item an admin
  decided to import without them; every other `<iframe>` is kept. After `call/2` allowed the
  players of an admin who may, it leaves out none.
  """
  @spec playable(String.t(), Target.context()) :: String.t()
  def playable(html, context), do: html |> players() |> unallowed(context) |> left_out(html)

  defp missing(item, context), do: item |> Item.html() |> players() |> unallowed(context)

  defp players(html),
    do:
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("iframe[src]")
      |> LazyHTML.attribute("src")
      |> Enum.map(&origin/1)
      |> Enum.filter(&(&1 in @players))
      |> Enum.uniq()

  defp unallowed([], _context), do: []
  defp unallowed(players, context), do: players -- Settings.get(@key, [], context.site_id)

  defp origin(src), do: src |> String.trim() |> URI.parse() |> origin_of()

  defp origin_of(%URI{scheme: "https", host: host, port: 443}) when is_binary(host),
    do: "https://" <> String.downcase(host)

  defp origin_of(_uri), do: nil

  defp permitted?(actor),
    do: AccessPermissions.match?(actor, %{}, permissions: Settings.write_permission(@key))

  defp decision(item, context), do: Target.decision(context, item, @conflict)

  defp allowed([], _item, _context), do: :ok

  defp allowed(missing, item, context),
    do: allowed(missing, permitted?(context.actor), item, context)

  defp allowed(missing, true, _item, context),
    do:
      context.actor
      |> Settings.put_as(@key, Settings.get(@key, [], context.site_id) ++ missing,
        site_id: context.site_id
      )
      |> written()

  defp allowed(_missing, false, item, context), do: item |> decision(context) |> decided()

  defp written({:ok, _origins}), do: :ok
  defp written({:error, error}), do: {:error, error}

  defp waits([], _item, _context), do: nil
  defp waits(_missing, item, context), do: context.actor |> permitted?() |> blocked(item, context)

  defp blocked(true, _item, _context), do: nil
  defp blocked(false, item, context), do: item |> decision(context) |> decided() |> found()

  defp decided("import"), do: :ok
  defp decided("keep"), do: {:skipped, "waits_for_admin"}
  defp decided(nil), do: {:undecided, @conflict}

  defp found(:ok), do: nil
  defp found(waiting), do: waiting

  defp noted([], _item, _context), do: nil

  defp noted(missing, item, context),
    do: context.actor |> permitted?() |> told(missing, item, context)

  defp told(true, missing, _item, _context), do: "frames_allowed: " <> Enum.join(missing, ", ")
  defp told(false, _missing, item, context), do: item |> decision(context) |> decided() |> said()

  defp said(:ok), do: "player_left_out"
  defp said({_waiting, reason}), do: reason

  defp left_out([], html), do: html

  defp left_out(unallowed, html),
    do:
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.to_tree()
      |> LazyHTML.Tree.postwalk(&kept(&1, unallowed))
      |> LazyHTML.Tree.to_html()

  defp kept({"iframe", attributes, _children} = frame, unallowed),
    do: attributes |> Enum.find_value(&src_origin/1) |> dropped(frame, unallowed)

  defp kept(node, _unallowed), do: node

  defp src_origin({"src", src}), do: origin(src)
  defp src_origin(_attribute), do: nil

  defp dropped(origin, frame, unallowed), do: unless_in(frame, origin in unallowed)

  defp unless_in(_frame, true), do: []
  defp unless_in(frame, false), do: frame
end
