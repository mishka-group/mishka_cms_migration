# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.ReportTest do
  @moduledoc """
  The report a run keeps: every item counted, by kind in the order met, and only the last entries
  kept, so it stays small however large the site; and an entry's reason as the admin reads it.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsMigration.{MigrationRun, Report}

  defp add_many(report, kind, ids, outcome),
    do: Enum.reduce(ids, report, &Report.add(&2, Report.entry(kind, "#{&1}", nil, outcome, nil)))

  test "counts every item and keeps only the last entries, in the order they were met" do
    total = Report.max_entries() * 2 + 500

    report = Report.new() |> add_many("post", 1..total, :created) |> Report.done()

    assert report.counts == %{created: total, updated: 0, skipped: 0, failed: 0}
    assert length(report.entries) == Report.max_entries()
    assert hd(report.entries).source_id == "#{total - Report.max_entries() + 1}"
    assert List.last(report.entries).source_id == "#{total}"
    assert Map.keys(report) |> Enum.sort() == [:counts, :entries, :kinds]
  end

  test "lists each kind that had an item, in the order the kinds were met" do
    report =
      Report.new()
      |> add_many("user", 1..2, :created)
      |> add_many("post", 1..1, :skipped)
      |> add_many("user", 3..3, :failed)
      |> Report.done()

    assert [%{kind: "user", created: 2, failed: 1}, %{kind: "post", skipped: 1}] = report.kinds
  end

  test "an entry's reason reads in words, each of its parts, and a reason of the CMS as it is" do
    assert MigrationRun.reason_label("draft_from_pending; unconverted: acme/callout, gallery") ==
             "Pending review at the source, so a draft; Kept as text: acme/callout, gallery"

    assert MigrationRun.reason_label("draft_from_password") ==
             "Password-protected at the source, so a draft"

    assert MigrationRun.reason_label("title: is required; slug: is required") ==
             "title: is required; slug: is required"
  end
end
