# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.Helpers.Read do
  @moduledoc """
  The records a query finds for a target's `existing/2` (`MishkaCmsMigration.Target`), read as the
  admin running the job under the run's site and the CMS's own policies.

  An admin the CMS does not let read them finds none, so the items are created, and the CMS then
  refuses or accepts each write as it does for any admin. Any other failure is raised.
  """

  alias MishkaCmsMigration.Target

  @doc """
  The records `query` finds in the run's site, `[]` when the admin may not read them. Of `context`
  only its `actor` and `site_id` are read, so a check of the admin's own, such as what an item may
  be mapped to, hands just those.
  """
  @spec call(
          Ash.Query.t() | Ash.Resource.t(),
          Target.context() | %{actor: term(), site_id: term()}
        ) ::
          [struct()]
  def call(query, context),
    do: query |> Ash.read(actor: context.actor, tenant: context.site_id) |> read()

  defp read({:ok, records}), do: records
  defp read({:error, %Ash.Error.Forbidden{}}), do: []
  defp read({:error, error}), do: raise(error)
end
