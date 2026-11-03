# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Resources.Validations.MappedRecord do
  @moduledoc """
  Holds an item's `mapped_id` (`MishkaCmsMigration.MigrationItem`'s `:choose`) to a record the item
  may be mapped to: one of the CMS resource its kind is written to (`MishkaCmsMigration.Target`),
  on the item's site, that the admin may read. `nil`, importing the item as its own, is always
  taken.

      update :choose do
        validate MishkaCmsMigration.Resources.Validations.MappedRecord,
          before_action?: true,
          where: [changing(:mapped_id)]
      end

  The record is read as the admin, under the item's site and the CMS's own policies
  (`MishkaCmsMigration.Targets.Helpers.Read`), so another site's record, another kind's, one that
  is gone and one the admin may not read are all refused the same way, on `mapped_id`. Run it with
  `before_action?: true`, after the policies have let the admin make the choice.
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  alias Ash.Error.Changes.InvalidAttribute
  alias MishkaCmsMigration.Target
  alias MishkaCmsMigration.Targets.Helpers.Read

  @message dgettext_noop("errors", "Pick a record of this site to map it to.")

  @impl true
  def supports(_opts), do: [Ash.Changeset]

  @impl true
  def validate(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.get_attribute(:mapped_id)
    |> held(changeset.data, context)
  end

  defp held(nil, _item, _context), do: :ok

  defp held(id, item, context) do
    with {:ok, target} <- Target.fetch(item.source_kind),
         [_record] <-
           target.resource()
           |> Ash.Query.filter(id == ^id)
           |> Read.call(%{actor: context.actor, site_id: item.site_id}) do
      :ok
    else
      _not_one -> {:error, InvalidAttribute.exception(field: :mapped_id, message: @message)}
    end
  end
end
