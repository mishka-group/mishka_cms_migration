# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationTest do
  @moduledoc """
  The extension boots on its own: its application is supervised, its domain is registered with its
  resources and its repo answers through the sandbox.
  """
  use MishkaCmsMigration.DataCase, async: false

  test "the application supervises its install plugins, ships WordPress and its targets, the Blog's where it is loaded" do
    assert is_pid(Process.whereis(MishkaCmsMigration.Supervisor))

    assert {MishkaCmsMigration.Application.sources(), MishkaCmsMigration.Application.targets()} ==
             {[MishkaCmsMigration.Sources.WordPress],
              [
                MishkaCmsMigration.Targets.CmsPage,
                MishkaCmsMigration.Targets.BlogBlogger,
                MishkaCmsMigration.Targets.BlogCollection,
                MishkaCmsMigration.Targets.BlogTag,
                MishkaCmsMigration.Targets.BlogPost,
                MishkaCmsMigration.Targets.PostRedirect
              ]}

    for plugin <- MishkaCmsMigration.Application.plugins() do
      assert is_pid(Process.whereis(plugin))
    end

    assert MishkaCmsMigration.Provision in MishkaCmsMigration.Application.plugins()
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
