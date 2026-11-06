# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.MigrationItemTest do
  @moduledoc """
  What an item that waits for its parent says holds it, read from its parents as they are now
  rather than from what its last import recorded, and where each item of a branch stands.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsMigration.{MigrationItem, MigrationRun}

  defp item(source_id, fields \\ %{}),
    do:
      struct(
        MigrationItem,
        Map.merge(
          %{
            id: "id-" <> source_id,
            source_kind: "page",
            source_id: source_id,
            title: "Page " <> source_id,
            decisions: %{},
            left_out: false
          },
          fields
        )
      )

  defp undecided(source_id),
    do: item(source_id, %{plan: :undecided, plan_reason: "language_unknown"})

  defp imported(source_id), do: item(source_id, %{target_id: "page-" <> source_id})

  defp skipped(reason, ancestors),
    do: item("157", %{outcome: :skipped, reason: reason, ancestors: ancestors})

  describe "waits_for_parent/1" do
    test "names the parent as it is now, not as the stale reason the last import recorded" do
      waiting = skipped("parent_missing", [item("24", %{decisions: %{"x" => "import"}})])

      assert MigrationItem.waits_for_parent(waiting) == "parent_missing: Page 24 (#24)"

      assert MigrationItem.waits_for_parent(%{waiting | ancestors: [undecided("24")]}) ==
               "parent_undecided: Page 24 (#24)"
    end

    test "names the top one that holds the branch, as above its parent when it is not the parent" do
      waiting = skipped("parent_missing: Page 25 (#25)", [undecided("24"), item("25")])

      assert MigrationItem.waits_for_parent(waiting) == "ancestor_undecided: Page 24 (#24)"

      assert MigrationRun.reason_label(MigrationItem.waits_for_parent(waiting), "page") =~
               "Page 24 (#24), above its parent, needs your decision"

      not_listed = %MigrationItem{id: nil, source_kind: "page", source_id: "9"}

      assert MigrationItem.waits_for_parent(%{waiting | ancestors: [not_listed, item("25")]}) ==
               "ancestor_not_listed: 9"
    end

    test "waits for nothing once every parent has a record, and for nothing it was never held by" do
      assert nil ==
               MigrationItem.waits_for_parent(
                 skipped("parent_undecided: Page 25 (#25)", [imported("24"), imported("25")])
               )

      assert nil ==
               MigrationItem.waits_for_parent(
                 item("157", %{plan: :created, ancestors: [undecided("24")]})
               )
    end

    test "keeps the stored reason when the ancestors are not loaded" do
      assert MigrationItem.waits_for_parent(skipped("parent_missing: Team (#25)", nil)) ==
               "parent_missing: Team (#25)"
    end
  end

  describe "standing/1" do
    test "tells a failed import and a decided item from one not imported yet" do
      assert MigrationItem.standing(item("1", %{outcome: :failed, reason: "x"})) == :failed

      assert MigrationItem.standing(item("1", %{decisions: %{"slug_taken" => "keep"}})) ==
               :decided

      assert MigrationItem.standing(item("1")) == :not_imported
      assert MigrationItem.standing(undecided("1")) == :undecided
      assert MigrationItem.standing_word(:decided) =~ "ready to import"
    end

    test "is decided once an admin answers what a dry run found after its import failed" do
      failed =
        item("24", %{
          outcome: :failed,
          reason: "path: The page “About” at /:lang/about already answers at /about.",
          plan: :undecided,
          plan_reason: "slug_taken: About"
        })

      assert MigrationItem.standing(failed) == :undecided

      assert MigrationItem.standing(%{failed | decisions: %{"slug_taken" => "keep"}}) ==
               :decided

      assert MigrationItem.standing(
               item("24", %{
                 outcome: :failed,
                 reason: "path: taken",
                 plan: :skipped,
                 plan_reason: "connected",
                 decisions: %{"slug_taken" => "keep"}
               })
             ) == :decided
    end
  end
end
