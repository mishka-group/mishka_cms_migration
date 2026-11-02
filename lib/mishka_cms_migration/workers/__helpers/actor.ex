# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Workers.Helpers.Actor do
  @moduledoc """
  Who a migration job runs as: the admin who started its run. The `AshOban.ActorPersister` of
  `MishkaCmsMigration.MigrationRun`'s triggers keeps the user's id in the job (`store/1`) and
  loads the user with their permissions when the job runs (`lookup/1`), so a target writes as that
  admin under the CMS's own policies, with the permissions they hold then. A user who is gone
  fails the attempt.
  """

  use AshOban.ActorPersister

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Accounts.User

  @impl AshOban.ActorPersister
  def store(%{id: id}), do: %{"id" => id}

  @impl AshOban.ActorPersister
  def lookup(%{"id" => id}), do: User |> Ash.get(id, authorize?: false) |> found()
  def lookup(nil), do: {:ok, nil}

  defp found({:ok, user}), do: {:ok, AccessPermissions.with_permissions(user)}
  defp found({:error, error}), do: {:error, error}
end
