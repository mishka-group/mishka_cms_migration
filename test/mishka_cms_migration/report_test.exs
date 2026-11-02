# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.ReportTest do
  @moduledoc """
  The report a run keeps: every item counted, by kind in the order met, and only the last entries
  kept, so it stays small however large the site.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsMigration.Report

  defp add_many(report, kind, ids, outcome),
    do: Enum.reduce(ids, report, &Report.add(&2, Report.entry(kind, "#{&1}", nil, outcome, nil)))

  test "counts every item and keeps only the last entries, in the order they were met" do
    total = Report.max_entries() * 2 + 500

    report = Report.new() |> add_many("post", 1..total, :create) |> Report.done()

    assert report.counts == %{create: total, update: 0, skip: 0, fail: 0}
    assert length(report.entries) == Report.max_entries()
    assert hd(report.entries).source_id == "#{total - Report.max_entries() + 1}"
    assert List.last(report.entries).source_id == "#{total}"
    assert Map.keys(report) |> Enum.sort() == [:counts, :entries, :kinds]
  end

  test "lists each kind that had an item, in the order the kinds were met" do
    report =
      Report.new()
      |> add_many("user", 1..2, :create)
      |> add_many("post", 1..1, :skip)
      |> add_many("user", 3..3, :fail)
      |> Report.done()

    assert [%{kind: "user", create: 2, fail: 1}, %{kind: "post", skip: 1}] = report.kinds
  end
end
