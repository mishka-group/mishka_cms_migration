# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(MishkaBlog.Blogger) do
  defmodule MishkaCmsMigration.Targets.BlogBlogger do
    @moduledoc """
    The `"user"` items of a source, its authors, written as the Blog's bloggers
    (`MishkaBlog.Blogger`), each the profile of a user of the run's site, through the `:create` and
    `:update` an admin's own blogger form runs, on the run's site and as the admin who pressed
    Import: the admin needs the Blog's `admin:dashboard:blog:post`, and the Blog's own rules decide
    the rest, such as one slug and one profile per user on a site, and that a profile names a user
    of its own site.

    An item's title is the blogger's display name (its `"username"` when it has none), its `"slug"`
    the blogger's slug, its `"description"` the bio (an empty one is none) and the largest of its
    `"avatar_urls"` the avatar. Its email is never the blogger's public contact address, and its
    roles give nothing: a source's administrator becomes a blogger like any other author.

    ## Whose profile

    The user is the one whose email is the item's `"email"` among the users of the run's site, read
    as the admin (`existing/2`), so the admin needs the core's `admin:dashboard:user` to find any.
    Only the site's own users are read: a master, or a user of another site, with that address is
    never matched. Then, by the run's `authors` choice (`MishkaCmsMigration.MigrationRun`'s
    options):

      * a user who has a blogger profile on the site — the item is connected to it: the profile is
        kept as it is, now and on every later run, and the report says `"connected"`;
      * a user who has none — a blogger is created for them;
      * no user, under `"connect"` (the default) — skipped as `"no_user"`, and nothing is created;
      * no user, under `"create"` — a user of the site is created first, inside the blogger's
        transaction, through the core's `:tenant_create` (the action an admin's own New user form
        runs) as the admin, who needs the core's `admin:dashboard:user`: with no permission,
        unconfirmed, and a password of 32 random bytes that is neither kept nor shown, so nobody
        can sign in with it until the person sets their own through Forgot password. The core sends
        its own "Confirm your email address" email, as for any account an admin makes. An address
        the installation already has, such as a master's or another site's user's, is refused by
        the core and the item fails with its reason.

    A re-run writes the profile over a blogger it created, as any target does, and never changes
    whose profile it is: the user is named on create only.

    Defined only where Mishka Blog is loaded, and supervised by `MishkaCmsMigration.Application`
    only then; on a site without the Blog its kind is skipped as `"no_target"`.
    """

    use MishkaCmsMigration.Target,
      kind: "user",
      resource: MishkaBlog.Blogger,
      create: :create,
      update: :update

    require Ash.Query

    alias MishkaBlog.Blogger
    alias MishkaCmsCore.Accounts.User

    @impl MishkaCmsMigration.Target
    def existing(items, context) do
      users = items |> Enum.flat_map(&email/1) |> users(context)
      profiles = users |> Map.values() |> profiles(context)

      for item <- items,
          found = found(users[address(item)], profiles, context.options),
          into: %{},
          do: {item.source_id, found}
    end

    @impl MishkaCmsMigration.Target
    def attrs(item, %{record: nil} = context),
      do: item |> profile() |> Map.put(:user_id, user_id(item, context))

    def attrs(item, _update), do: profile(item)

    defp profile(item) do
      %{
        display_name: display_name(item),
        slug: item.attrs["slug"],
        bio: bio(item.attrs["description"]),
        avatar_url: avatar(item.attrs["avatar_urls"])
      }
    end

    defp found(nil, _profiles, %{authors: "create"}), do: nil
    defp found(nil, _profiles, _connect), do: {:skipped, "no_user"}
    defp found(%User{id: id}, profiles, _options), do: connected(profiles[id])

    defp connected(nil), do: nil
    defp connected(blogger), do: {:connected, blogger}

    defp user_id(item, context),
      do: item |> email() |> users(context) |> Map.values() |> account(item, context)

    defp account([%User{id: id}], _item, _context), do: id

    defp account([], item, %{options: %{authors: "create"}} = context),
      do: created!(item, context)

    defp account([], _item, _context), do: nil

    defp created!(item, context) do
      secret = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

      User
      |> Ash.Changeset.for_create(
        :tenant_create,
        %{email: item.attrs["email"], password: secret, password_confirmation: secret},
        actor: context.actor,
        tenant: context.site_id
      )
      |> Ash.create!()
      |> Map.fetch!(:id)
    end

    defp users([], _context), do: %{}

    defp users(emails, context) do
      User
      |> Ash.Query.filter(email in ^emails)
      |> Ash.read(actor: context.actor, tenant: context.site_id)
      |> read()
      |> Map.new(&{&1.email |> to_string() |> String.downcase(), &1})
    end

    defp profiles([], _context), do: %{}

    defp profiles(users, context) do
      ids = Enum.map(users, & &1.id)

      Blogger
      |> Ash.Query.filter(user_id in ^ids)
      |> Ash.read(actor: context.actor, tenant: context.site_id)
      |> read()
      |> Map.new(&{&1.user_id, &1})
    end

    defp read({:ok, rows}), do: rows
    defp read({:error, %Ash.Error.Forbidden{}}), do: []
    defp read({:error, error}), do: raise(error)

    defp email(item), do: item |> address() |> List.wrap()

    defp address(%{attrs: %{"email" => email}}) when is_binary(email) and email != "",
      do: String.downcase(email)

    defp address(_item), do: nil

    defp display_name(%{title: title}) when is_binary(title) and title != "", do: title
    defp display_name(%{attrs: attrs}), do: attrs["username"]

    defp bio(""), do: nil
    defp bio(bio), do: bio

    defp avatar(%{} = urls) when map_size(urls) > 0,
      do: urls |> Enum.max_by(&(&1 |> elem(0) |> Integer.parse() |> pixels())) |> elem(1)

    defp avatar(_none), do: nil

    defp pixels({pixels, ""}), do: pixels
    defp pixels(_not_a_size), do: 0
  end
end
