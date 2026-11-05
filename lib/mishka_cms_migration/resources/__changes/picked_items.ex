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

  An admin the CMS's own policies do not let read the records a picked kind is written to
  (`MishkaCmsMigration.Target`'s `resources/0`, asked with `Ash.can?/3` from the admin's
  permissions, without a query) is refused on `items` too, "You may not change tags on this site.",
  before anything is queued: the job could only fail those items.
  """

  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  alias Ash.Error.Changes.InvalidArgument
  alias MishkaCmsMigration.{MigrationItem, MigrationRun, Target}

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
    |> job(changeset, context)
  end

  defp job({:ok, []}, changeset, _context),
    do:
      Ash.Changeset.add_error(
        changeset,
        InvalidArgument.exception(field: :items, message: @none)
      )

  defp job({:ok, items}, %{data: run} = changeset, context) do
    picked = Enum.group_by(items, & &1.source_kind, & &1.source_id)

    picked
    |> Map.keys()
    |> Enum.reject(&changeable?(&1, run.site_id, context))
    |> allowed(changeset, %{items: picked, back_to: run.status})
  end

  defp job({:error, error}, changeset, _context), do: Ash.Changeset.add_error(changeset, error)

  defp allowed([], changeset, arguments),
    do: Ash.Changeset.set_context(changeset, %{job_arguments: arguments})

  defp allowed(kinds, changeset, _arguments),
    do:
      Ash.Changeset.add_error(
        changeset,
        InvalidArgument.exception(
          field: :items,
          message: MigrationRun.reason_label("forbidden: " <> Enum.join(kinds, ", ")) <> "."
        )
      )

  defp changeable?(_kind, _site_id, %{authorize?: false}), do: true

  defp changeable?(kind, site_id, context),
    do: kind |> Target.fetch() |> readable?(site_id, context.actor)

  defp readable?({:ok, target}, site_id, actor),
    do:
      Enum.all?(target.resources(), fn resource ->
        Ash.can?(
          {resource, Ash.Resource.Info.primary_action!(resource, :read).name},
          actor,
          tenant: site_id,
          run_queries?: false,
          maybe_is: true
        )
      end)

  defp readable?({:error, :not_installed}, _site_id, _actor), do: true
end
