# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationTest do
  @moduledoc """
  The extension boots on its own: its application is supervised, its domain is registered with its
  resources and its repo answers through the sandbox.
  """
  use MishkaCmsMigration.DataCase, async: false

  test "the application is supervised and ships no source or target of its own yet" do
    assert is_pid(Process.whereis(MishkaCmsMigration.Supervisor))
    assert MishkaCmsMigration.Application.plugins() == []
  end

  test "the domain is registered and holds the runs and their items" do
    assert MishkaCmsMigration in Application.fetch_env!(:mishka_cms_migration, :ash_domains)

    assert Ash.Domain.Info.resources(MishkaCmsMigration) == [
             MishkaCmsMigration.MigrationRun,
             MishkaCmsMigration.MigrationItem
           ]
  end

  test "the repo answers a query through the sandbox" do
    assert {:ok, %{rows: [[1]]}} = Repo.query("SELECT 1")
  end
end
