# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Resources.Validations.SiteIdle do
  @moduledoc """
  Holds an admin's choice on an item (`MishkaCmsMigration.MigrationItem`'s `:leave_out`,
  `:bring_back`, `:choose`, `:decide_keep` and `:decide_import`, and their master actions) while
  one of the item's site's runs is dry running or
  importing: the job reads the choices as it walks, so one made halfway would hold for part of the
  run alone.

      update :leave_out do
        validate MishkaCmsMigration.Resources.Validations.SiteIdle, before_action?: true
      end

  The site's runs are read as the admin, under the item's site. Run it with `before_action?: true`,
  so the policies have let the admin make the choice before their runs are read.

  An atomic action (`:decide`, one update for a whole group) runs it once for the update, under
  its tenant, not once per item; a run the admin may not read counts as none, and the items'
  own policies then refuse the change.

      update :decide do
        validate MishkaCmsMigration.Resources.Validations.SiteIdle
      end
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  alias Ash.Error.Changes.InvalidChanges
  alias MishkaCmsMigration.MigrationRun

  @running [:dry_running, :importing]
  @message dgettext_noop(
             "errors",
             "A dry run or an import of this site is running. Change its items once it is done."
           )

  @impl true
  def supports(_opts), do: [Ash.Changeset]

  @impl true
  def validate(changeset, _opts, context),
    do: changeset.data.site_id |> running(context) |> idle()

  @impl true
  def atomic(changeset, _opts, context), do: changeset.tenant |> running(context) |> idle()

  defp running(site_id, context),
    do:
      MigrationRun
      |> Ash.Query.filter(status in ^@running)
      |> Ash.exists(actor: context.actor, tenant: site_id, authorize?: context.authorize?)

  defp idle({:ok, false}), do: :ok
  defp idle({:ok, true}), do: {:error, InvalidChanges.exception(message: @message)}
  defp idle({:error, %Ash.Error.Forbidden{}}), do: :ok
  defp idle({:error, error}), do: {:error, error}
end
