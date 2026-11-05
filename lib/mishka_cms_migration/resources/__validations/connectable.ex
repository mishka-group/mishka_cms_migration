# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Resources.Validations.Connectable do
  @moduledoc """
  Holds a step that queues a job, Run again (`:start_dry_run`) and the jobs of picked items
  (`:dry_run_items`, `:import_items`), on a run that still holds what its source connects with
  (`MishkaCmsMigration.MigrationRun.connectable?/1`): its sealed password, or the file it was
  handed. A run an earlier release ended cleared both, and its job could only fail on the source's
  refusal, so it is refused before anything is queued, in words: "This run no longer holds its
  WordPress password. Start a New import.", or its file, for a source that reads one.

      update :start_dry_run do
        validate MishkaCmsMigration.Resources.Validations.Connectable
      end

  It reads the run as the action was handed it, with no query, also when the action runs
  atomically: a run's secret and file are cleared only by `:cancel`, which leaves it in a status
  `MishkaCmsMigration.Resources.Validations.Status` refuses.
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  alias Ash.Error.Changes.InvalidChanges
  alias MishkaCmsMigration.{MigrationRun, Source}

  @password dgettext_noop(
              "errors",
              "This run no longer holds its %{source} password. Start a New import."
            )
  @file_gone dgettext_noop(
               "errors",
               "This run no longer holds its %{source}. Start a New import."
             )

  @impl true
  def supports(_opts), do: [Ash.Changeset]

  @impl true
  def validate(%{data: run}, _opts, _context), do: run |> MigrationRun.connectable?() |> held(run)

  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)

  defp held(true, _run), do: :ok

  defp held(false, run),
    do:
      {:error,
       InvalidChanges.exception(
         message: run.source |> Source.file?() |> message(),
         vars: [source: Source.label(run.source)]
       )}

  defp message(true), do: @file_gone
  defp message(false), do: @password
end
