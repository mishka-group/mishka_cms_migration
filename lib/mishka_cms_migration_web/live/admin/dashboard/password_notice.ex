# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Live.Admin.Dashboard.PasswordNotice do
  @moduledoc """
  The warning for the users an import created (`MishkaCmsMigration.Targets.BlogBlogger`): a
  source's password hashes cannot be carried over, so such a user signs in with Forgot password or
  a social sign-in. Both parts draw it as the admin's own warning (Gervaz's `:warning` alert,
  `MishkaGervaz.UIAdapters.Tailwind.alert/1`), as `MishkaCmsMigrationWeb.Live.Admin.Dashboard.LanguageNotice`
  does:

    * `run/1` in a run's expanded row (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.RunDetails`),
      with how many users the run created, and nothing for none;
    * `item/1` in an item's expanded row (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Index`),
      for the item of a user the import created (`MishkaCmsMigration.MigrationItem`'s `reason` is
      `"user_created"`), and nothing for any other.

  `created/2` counts the users of the run's source an import created, with one query.
  """

  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaGervaz.UIAdapters.Tailwind, only: [alert: 1]

  require Ash.Query

  alias MishkaCmsMigration.{MigrationItem, MigrationRun}

  @created "user_created"

  @doc "How many users the import of `run` created, read as `user` under the run's site."
  @spec created(MigrationRun.t(), map()) :: non_neg_integer()
  def created(%MigrationRun{status: status} = run, user) when status in [:importing, :done] do
    MigrationItem
    |> Ash.Query.filter(
      source_host == ^run.source_host and source_kind == "user" and reason == @created
    )
    |> Ash.count(actor: user, tenant: run.site_id)
    |> counted()
  end

  def created(_run, _user), do: 0

  defp counted({:ok, count}), do: count
  defp counted({:error, _unreadable}), do: 0

  attr :count, :integer, required: true, doc: "how many users the run created"
  attr :class, :string, default: nil, doc: "extra classes of the warning's box"

  @doc "The warning for a run that created `count` users, or nothing for none."
  def run(assigns) do
    ~H"""
    <div :if={@count > 0} data-role="created-users-warning" class={@class}>
      <.alert type={:warning} icon="hero-exclamation-triangle" title={gettext("Users were created")}>
        <p class="m-0">
          {ngettext(
            "%{count} user was created. Their WordPress passwords can't be carried over: they sign in with Forgot password or a social sign-in.",
            "%{count} users were created. Their WordPress passwords can't be carried over: they sign in with Forgot password or a social sign-in.",
            @count
          )}
        </p>
      </.alert>
    </div>
    """
  end

  attr :item, MigrationItem, required: true, doc: "the item, with its reason"

  @doc "The warning for the item of a user an import created, or nothing for any other item."
  def item(assigns) do
    ~H"""
    <div
      :if={@item.source_kind == "user" and @item.reason == "user_created"}
      data-role="created-user-warning"
    >
      <.alert type={:warning} icon="hero-exclamation-triangle" title={gettext("User created")}>
        <p class="m-0">
          {gettext(
            "This user was created. Their WordPress password can't be carried over: they sign in with Forgot password or a social sign-in."
          )}
        </p>
      </.alert>
    </div>
    """
  end
end
