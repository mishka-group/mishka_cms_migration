# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Workers.DryRunWorker do
  @moduledoc """
  The dry run of one run, on the `migration` queue: what an import would create, update and skip,
  and why, saved as the run's report. It writes nothing to the CMS and fires no event. See
  `MishkaCmsMigration.Workers.Helpers.Pipeline`.

  Queued by `MishkaCmsMigration.MigrationRun`'s `:start_dry_run` with
  `%{"run_id" => "…", "site_id" => "…", "actor_id" => "…", "resource" => "…"}`. A site has one
  migration job at a time, waiting or running, and an attempt has an hour
  (`MishkaCmsMigration.Workers.Helpers.Pipeline.unique/0` and `timeout/1`).
  """

  use Oban.Worker,
    queue: :migration,
    max_attempts: 3,
    unique: MishkaCmsMigration.Workers.Helpers.Pipeline.unique()

  alias MishkaCmsMigration.Workers.Helpers.Pipeline

  @impl Oban.Worker
  def perform(%Oban.Job{} = job), do: Pipeline.call(job, :dry_run)

  @impl Oban.Worker
  def timeout(%Oban.Job{} = job), do: Pipeline.timeout(job)
end
