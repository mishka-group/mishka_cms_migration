# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Workers.ImportWorker do
  @moduledoc """
  The import of one run, on the `migration` queue: every item written through its target as the
  admin who pressed Import, each recorded so a later run updates instead of duplicating, the report
  saved on the run and handed to `migration:import:finished`. See
  `MishkaCmsMigration.Workers.Helpers.Pipeline`.

  Queued by `MishkaCmsMigration.MigrationRun`'s `:start_import` with
  `%{"run_id" => "…", "site_id" => "…", "actor_id" => "…", "resource" => "…"}`. A site has one
  migration job at a time, waiting or running, and an attempt has an hour
  (`MishkaCmsMigration.Workers.unique/0` and `timeout/1`). Another attempt walks
  the source again and skips what the first one wrote and recorded.
  """

  use Oban.Worker,
    queue: :migration,
    max_attempts: 3,
    unique: MishkaCmsMigration.Workers.unique()

  alias MishkaCmsMigration.Workers.Helpers.Pipeline

  @impl Oban.Worker
  def perform(%Oban.Job{} = job), do: Pipeline.call(job, :import)

  @impl Oban.Worker
  def timeout(%Oban.Job{} = job), do: MishkaCmsMigration.Workers.timeout(job)
end
