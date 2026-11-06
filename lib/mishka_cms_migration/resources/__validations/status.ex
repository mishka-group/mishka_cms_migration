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

  A refused run is an `Ash.Error.Changes.InvalidAttribute` on `status` whose message says, in
  words, what the run is doing and what to do, such as "An import of this run is running. Wait until
  it finishes, then try again." It names no variable, so the same sentence reads in a flash and in
  the log, and the atomic check picks it in the database by the status the run is in.
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  import Ash.Expr

  alias Ash.Error.Changes.InvalidAttribute

  @messages %{
    pending: dgettext_noop("errors", "The run has no dry run yet. Run a dry run first."),
    dry_running:
      dgettext_noop(
        "errors",
        "A dry run of this run is running. Wait until it finishes, then try again."
      ),
    dry_run: dgettext_noop("errors", "The run's dry run is ready and waits for its import."),
    importing:
      dgettext_noop(
        "errors",
        "An import of this run is running. Wait until it finishes, then try again."
      ),
    done: dgettext_noop("errors", "The run's import is done. Run it again to import once more."),
    failed: dgettext_noop("errors", "The run failed. Run it again to try once more."),
    cancelled: dgettext_noop("errors", "The run was cancelled. Start a New import.")
  }

  @impl true
  def init(opts), do: opts |> Keyword.get(:from) |> from(opts[:as_read] == true)

  @impl true
  def supports(_opts), do: [Ash.Changeset]

  @impl true
  def validate(changeset, opts, _context), do: allowed(changeset.data.status, opts[:from])

  @impl true
  def atomic(changeset, opts, _context) do
    {:atomic, [:status], refused(opts[:from], {opts[:as_read], changeset.data.status}),
     expr(error(^InvalidAttribute, %{field: :status, message: ^said()}))}
  end

  defp said,
    do:
      Enum.reduce(@messages, nil, fn {state, message}, otherwise ->
        expr(if status == ^state, do: ^message, else: ^otherwise)
      end)

  defp refused(from, {true, read}), do: expr(status not in ^from or status != ^read)
  defp refused(from, _any_status), do: expr(status not in ^from)

  defp from([_ | _] = from, as_read), do: {:ok, [from: from, as_read: as_read]}

  defp from(other, _as_read),
    do: {:error, "expected :from to be a list of statuses, got: #{inspect(other)}"}

  defp allowed(status, [status | _from]), do: :ok
  defp allowed(status, [_other | from]), do: allowed(status, from)

  defp allowed(status, []),
    do:
      {:error, InvalidAttribute.exception(field: :status, message: Map.fetch!(@messages, status))}
end
