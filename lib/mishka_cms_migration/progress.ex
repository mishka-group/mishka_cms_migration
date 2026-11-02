# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Progress do
  @moduledoc """
  A run's progress, broadcast over `MishkaCmsCore.PubSub` on the run's own topic (`topic/1`) after
  each page a dry run or an import has walked (`MishkaCmsMigration.Walker`):

      {:migration_progress,
       %{run_id: "…", site_id: "…", mode: :import, kind: "post",
         counts: %{created: 10, updated: 0, skipped: 2, failed: 0}}}

  `counts` are the run's so far, every kind together. A screen that shows a run subscribes once it
  has checked the reader may see it.
  """

  @pubsub MishkaCmsCore.PubSub

  @doc "The PubSub topic a run's progress is broadcast on."
  @spec topic(String.t()) :: String.t()
  def topic(run_id), do: "migration:run:#{run_id}"

  @doc "Subscribes the caller to a run's progress. The suite does, and the Import tab (issue #3) will."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(run_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(run_id))

  @doc "Broadcasts how far `run` is in `mode`, having walked a page of `kind`."
  @spec broadcast(map(), atom(), String.t(), map()) :: :ok | {:error, term()}
  def broadcast(run, mode, kind, counts) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(run.id),
      {:migration_progress,
       %{run_id: run.id, site_id: run.site_id, mode: mode, kind: kind, counts: counts}}
    )
  end
end
