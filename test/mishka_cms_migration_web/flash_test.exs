# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.FlashTest do
  @moduledoc """
  The flashes of the migration pages by what they mean: success, info, warning and error, drawn
  with the four kinds the core has, and the kind of the one flash that sums up several items.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsMigration.MigrationItem
  alias MishkaCmsMigrationWeb.Flash
  alias MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Summary

  describe "the kinds" do
    test "every meaning is drawn with its own kind of the core" do
      assert Flash.kinds() == [:success, :info, :warning, :error]

      for kind <- Flash.kinds(), do: assert(Flash.core_kind(kind) == kind)
    end

    test "an item's result means success when written, error when failed, and a warning otherwise" do
      assert Flash.result_kind(:created) == :success
      assert Flash.result_kind(:updated) == :success
      assert Flash.result_kind(:failed) == :error

      for result <- [:skipped, :undecided, nil], do: assert(Flash.result_kind(result) == :warning)
    end

    test "put draws the meaning with the core's kind" do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

      assert %{assigns: %{flash: %{"success" => "Done"}}} = Flash.put(socket, :success, "Done")
      assert %{assigns: %{flash: %{"warning" => "Mind"}}} = Flash.put(socket, :warning, "Mind")
      assert %{assigns: %{flash: %{"error" => "No"}}} = Flash.put(socket, :error, "No")
    end
  end

  describe "a choice refused for another reason than a running job" do
    test "is left to Gervaz's own failure flash" do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

      assert MigrationItem.refused(:leave_out, %RuntimeError{message: "boom"}, socket) == socket
      assert MigrationItem.refused_bulk(%{failed_errors: []}, socket) == socket
    end
  end

  describe "the one flash for several items" do
    defp item(id, outcome, reason \\ nil),
      do: %MigrationItem{
        id: id,
        source_id: id,
        source_kind: "post",
        title: "Post " <> id,
        outcome: outcome,
        reason: reason
      }

    defp settled(items), do: Map.new(items, &{&1.id, &1})

    test "is a success when every item was written" do
      items = [item("1", :created), item("2", :updated)]
      assert {:success, words} = Summary.call(["1", "2"], settled(items))
      assert words =~ "created"
    end

    test "is a warning when an item was skipped, waits for a decision, or was not reached" do
      assert {:warning, _} =
               Summary.call(["1", "2"], settled([item("1", :created), item("2", :skipped)]))

      assert {:warning, _} =
               Summary.call(["1"], settled([item("1", :undecided, "slug_taken")]))

      assert {:warning, words} = Summary.call(["1", "2"], settled([item("1", :created)]))
      assert words =~ "did not reach"
    end

    test "is an error when any item failed, whatever else came of the others" do
      items = [item("1", :created), item("2", :failed, "boom"), item("3", :skipped)]
      assert {:error, _} = Summary.call(["1", "2", "3"], settled(items))
    end
  end
end
