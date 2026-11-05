# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Resources.Validations.Status do
  @moduledoc """
  Holds a run's move to the statuses it may come from: the status the run is in before the action,
  not the one the action sets.

      update :start_import do
        validate {MishkaCmsMigration.Resources.Validations.Status, from: [:dry_run]}
        change set_attribute(:status, :importing)
      end

  Run atomically, it is a condition of the update itself, so two requests that both read the run
  before either wrote it cannot both move it.

  With `as_read: true` the run must also still be in the status the caller read it in, so what the
  action takes from that status, such as the status a job of picked items puts the run back in
  (`MishkaCmsMigration.Resources.Changes.PickedItems`), is the one the database held. A run read
  before it moved on is refused with the status it is in now.

      validate {MishkaCmsMigration.Resources.Validations.Status, from: [:done], as_read: true}
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  import Ash.Expr

  alias Ash.Error.Changes.InvalidAttribute

  @message dgettext_noop("errors", "The run cannot do that while it is %{status}.")

  @impl true
  def init(opts), do: opts |> Keyword.get(:from) |> from(opts[:as_read] == true)

  @impl true
  def supports(_opts), do: [Ash.Changeset]

  @impl true
  def validate(changeset, opts, _context), do: allowed(changeset.data.status, opts[:from])

  @impl true
  def atomic(changeset, opts, _context) do
    {:atomic, [:status], refused(opts[:from], {opts[:as_read], changeset.data.status}),
     expr(
       error(^InvalidAttribute, %{
         field: :status,
         message: ^@message,
         vars: %{status: status}
       })
     )}
  end

  defp refused(from, {true, read}), do: expr(status not in ^from or status != ^read)
  defp refused(from, _any_status), do: expr(status not in ^from)

  defp from([_ | _] = from, as_read), do: {:ok, [from: from, as_read: as_read]}

  defp from(other, _as_read),
    do: {:error, "expected :from to be a list of statuses, got: #{inspect(other)}"}

  defp allowed(status, [status | _from]), do: :ok
  defp allowed(status, [_other | from]), do: allowed(status, from)

  defp allowed(status, []),
    do:
      {:error,
       InvalidAttribute.exception(field: :status, message: @message, vars: [status: status])}
end
