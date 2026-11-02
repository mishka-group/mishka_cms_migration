# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Resources.Changes.Reason do
  @moduledoc """
  Keeps why a run failed: the action's `error` argument in words
  (`MishkaCmsMigration.Report.reason/1`) as the run's `reason`. The error is what AshOban hands its
  trigger's `on_error` action after the last attempt, or what Oban says of a job it discarded.

      update :fail do
        argument :error, :term, allow_nil?: false
        change MishkaCmsMigration.Resources.Changes.Reason
      end
  """

  use Ash.Resource.Change

  alias MishkaCmsMigration.Report

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.force_change_attribute(changeset, :reason, said(changeset))

  @impl true
  def atomic(changeset, _opts, _context), do: {:atomic, %{reason: said(changeset)}}

  defp said(changeset), do: changeset |> Ash.Changeset.get_argument(:error) |> Report.reason()
end
