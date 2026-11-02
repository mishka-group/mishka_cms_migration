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
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  import Ash.Expr

  alias Ash.Error.Changes.InvalidAttribute

  @message dgettext_noop("errors", "The run cannot do that while it is %{status}.")

  @impl true
  def init(opts), do: opts |> Keyword.get(:from) |> from()

  @impl true
  def supports(_opts), do: [Ash.Changeset]

  @impl true
  def validate(changeset, opts, _context), do: allowed(changeset.data.status, opts[:from])

  @impl true
  def atomic(_changeset, opts, _context) do
    {:atomic, [:status], expr(status not in ^opts[:from]),
     expr(
       error(^InvalidAttribute, %{
         field: :status,
         message: ^@message,
         vars: %{status: status}
       })
     )}
  end

  defp from([_ | _] = from), do: {:ok, [from: from]}

  defp from(other),
    do: {:error, "expected :from to be a list of statuses, got: #{inspect(other)}"}

  defp allowed(status, [status | _from]), do: :ok
  defp allowed(status, [_other | from]), do: allowed(status, from)

  defp allowed(status, []),
    do:
      {:error,
       InvalidAttribute.exception(field: :status, message: @message, vars: [status: status])}
end
