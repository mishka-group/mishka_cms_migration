# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Resources.Validations.SiteIdle do
  @moduledoc """
  Holds an admin's choice on an item (`MishkaCmsMigration.MigrationItem`'s `:leave_out` and
  `:bring_back`, and their master actions) while one of the item's site's runs is dry running or
  importing: the job reads the choices as it walks, so one made halfway would hold for part of the
  run alone.

      update :leave_out do
        validate MishkaCmsMigration.Resources.Validations.SiteIdle, before_action?: true
      end

  The site's runs are read as the admin, under the item's site. Run it with `before_action?: true`,
  so the policies have let the admin make the choice before their runs are read.
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
  def validate(changeset, _opts, context) do
    MigrationRun
    |> Ash.Query.filter(status in ^@running)
    |> Ash.exists?(
      actor: context.actor,
      tenant: changeset.data.site_id,
      authorize?: context.authorize?
    )
    |> idle()
  end

  defp idle(false), do: :ok
  defp idle(true), do: {:error, InvalidChanges.exception(message: @message)}
end
