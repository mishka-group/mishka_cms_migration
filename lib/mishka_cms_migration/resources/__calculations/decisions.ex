# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Resources.Calculations.Decisions do
  @moduledoc """
  What waits for a decision now, and what an admin decided, among the items of each run's source
  host, for the run's `:decisions` calculation: `%{waiting: waiting, decided: decided}`.

  `waiting` counts the items that wait for a decision no admin has made (`waits_for_decision`) and
  `decided` those whose waiting decision an admin answered (`decided_waiting`, the Plan cell's
  Decided), so the Result chips of a run say what is true after the admin decided, not what the
  dry run counted.

  One query for each site of the runs asked for, so a page of the runs table costs one query
  whatever its size: every source host of the site is one row, with its two counts.
  """

  use Ash.Resource.Calculation

  require Ash.Query

  alias MishkaCmsMigration.MigrationItem

  @none %{waiting: 0, decided: 0}

  @impl true
  def load(_query, _opts, _context), do: [:site_id, :source_host]

  @impl true
  def calculate(runs, _opts, context) do
    counted =
      runs
      |> Enum.group_by(& &1.site_id, & &1.source_host)
      |> Enum.reduce(%{}, fn {site_id, hosts}, counted ->
        site_id |> counts(Enum.uniq(hosts), context) |> Enum.into(counted)
      end)

    Enum.map(runs, &Map.get(counted, {&1.site_id, &1.source_host}, @none))
  end

  defp counts(site_id, hosts, context) do
    MigrationItem
    |> Ash.Query.new()
    |> Ash.Query.set_tenant(site_id)
    |> Ash.Query.filter(source_host in ^hosts)
    |> Ash.Query.distinct([:source_host])
    |> Ash.Query.calculate(
      :waiting_count,
      :integer,
      Ash.Expr.expr(
        fragment(
          "count(*) FILTER (WHERE ?) OVER (PARTITION BY ?)",
          waits_for_decision,
          source_host
        )
      )
    )
    |> Ash.Query.calculate(
      :decided_count,
      :integer,
      Ash.Expr.expr(
        fragment("count(*) FILTER (WHERE ?) OVER (PARTITION BY ?)", decided_waiting, source_host)
      )
    )
    |> Ash.Query.select([:source_host])
    |> Ash.read(actor: context.actor, authorize?: context.authorize?)
    |> found(site_id)
  end

  defp found({:ok, rows}, site_id),
    do:
      for(
        row <- rows,
        do:
          {{site_id, row.source_host},
           %{waiting: row.calculations.waiting_count, decided: row.calculations.decided_count}}
      )

  defp found({:error, _error}, _site_id), do: []
end
