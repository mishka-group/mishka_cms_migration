# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Resources.Changes.PickedItems do
  @moduledoc """
  Turns the `items` argument of a run's `:dry_run_items` or `:import_items`, the ids of the items an
  admin picked on the Items page (`MishkaCmsMigration.MigrationItem`), into what the run's job is
  handed (`MishkaCmsMigration.Resources.Changes.EnqueueJob`): their source ids by kind, and the
  status the run goes back to once the job is done, the one it is in now.

      update :import_items do
        change MishkaCmsMigration.Resources.Changes.PickedItems
        change {MishkaCmsMigration.Resources.Changes.EnqueueJob, trigger: :run_import}
      end

  The items are read in one query, as the admin, among the items of the run's site and source host
  alone, while the action is built: an id that names none of them is left out, and when none is
  left the action is refused on `items`, in words. The run's move is then one atomic update, held
  by `MishkaCmsMigration.Resources.Validations.Status` with `as_read: true`, so a request made with
  a run read before it moved on, such as a second click on a page drawn before the first, is
  refused by the database, queues no job, and the status the run goes back to is the one it held.
  """

  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  alias Ash.Error.Changes.InvalidArgument
  alias MishkaCmsMigration.MigrationItem

  @none dgettext_noop("errors", "Pick items of this run's source.")

  @impl true
  def change(changeset, _opts, context),
    do: Ash.Changeset.before_action(changeset, &picked(&1, context))

  @impl true
  def atomic(changeset, _opts, context), do: {:ok, picked(changeset, context)}

  defp picked(%{data: run} = changeset, context) do
    ids = Ash.Changeset.get_argument(changeset, :items)

    MigrationItem
    |> Ash.Query.filter(id in ^ids and source_host == ^run.source_host)
    |> Ash.Query.select([:source_kind, :source_id])
    |> Ash.read(actor: context.actor, tenant: run.site_id, authorize?: context.authorize?)
    |> job(changeset)
  end

  defp job({:ok, []}, changeset),
    do:
      Ash.Changeset.add_error(
        changeset,
        InvalidArgument.exception(field: :items, message: @none)
      )

  defp job({:ok, items}, %{data: run} = changeset),
    do:
      Ash.Changeset.set_context(changeset, %{
        job_arguments: %{
          items: Enum.group_by(items, & &1.source_kind, & &1.source_id),
          back_to: run.status
        }
      })

  defp job({:error, error}, changeset), do: Ash.Changeset.add_error(changeset, error)
end
