# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Workers.DryRunWorker do
  @moduledoc """
  The dry run of one run, on the `migration` queue: what an import would create, update and skip,
  and why, saved as the run's report. It writes nothing to the CMS and fires no event. See
  `MishkaCmsMigration.Pipeline`.

  Queued by `MishkaCmsMigration.MigrationRun`'s `:start_dry_run` with
  `%{"run_id" => "…", "site_id" => "…", "actor_id" => "…", "resource" => "…"}`. A site has one
  migration job at a time, waiting or running (`MishkaCmsMigration.Pipeline.unique/0`).
  """

  use Oban.Worker,
    queue: :migration,
    max_attempts: 3,
    unique: MishkaCmsMigration.Pipeline.unique()

  @impl Oban.Worker
  def perform(%Oban.Job{} = job), do: MishkaCmsMigration.Pipeline.perform(job, :dry_run)
end
