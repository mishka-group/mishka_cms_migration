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
  def init(opts) do
    case Keyword.get(opts, :from) do
      [_ | _] = from -> {:ok, [from: from]}
      other -> {:error, "expected :from to be a list of statuses, got: #{inspect(other)}"}
    end
  end

  @impl true
  def supports(_opts), do: [Ash.Changeset]

  @impl true
  def validate(changeset, opts, _context) do
    status = changeset.data.status

    case status in opts[:from] do
      true ->
        :ok

      false ->
        {:error,
         InvalidAttribute.exception(field: :status, message: @message, vars: [status: status])}
    end
  end

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
end
