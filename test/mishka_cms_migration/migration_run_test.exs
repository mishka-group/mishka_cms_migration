# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.MigrationRunTest do
  @moduledoc """
  A run's own life: what creating one keeps, the order its steps may come in, the job each step
  queues, and the one migration job a site may have at a time.
  """
  use MishkaCmsMigration.DataCase, async: false

  alias MishkaCmsMigration.{Report, Secret, Workers.DryRunWorker, Workers.ImportWorker}

  setup do
    for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)

    site = create_site!()
    %{site: site, admin: migration_admin!(site)}
  end

  defp rows, do: %{"redirect" => [redirect_row(1, "/old", "/new")]}

  describe "creating a run" do
    test "keeps the secret only sealed, on the site, started by the actor", %{
      site: site,
      admin: admin
    } do
      run = create_run!(site, admin, rows(), %{secret: "app password"})

      assert {run.status, run.site_id, run.user_id} == {:pending, site.id, admin.id}
      refute run.connection_secret == "app password"
      refute inspect(run) =~ "app password"
      assert Secret.open(run.connection_secret) == {:ok, "app password"}
    end

    test "fills the admin's choices it was not given and refuses one it does not know", %{
      site: site,
      admin: admin
    } do
      run = create_run!(site, admin, rows(), %{options: %{pages: "publish"}})

      assert MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id).options == %{
               "authors" => "connect",
               "pages" => "publish",
               "post_address" => "blog",
               "comments" => false
             }

      assert {:error, %Ash.Error.Invalid{errors: [%{field: :pages, path: [:options]}]}} =
               MishkaCmsMigration.create_run(
                 %{source: "fake", source_host: "old.example.com", options: %{pages: "maybe"}},
                 actor: admin,
                 tenant: site.id
               )
    end

    test "cleans the source host and refuses one that is not a host", %{site: site, admin: admin} do
      run = create_run!(site, admin, rows(), %{source_host: "  Old.Example.COM:8080 "})
      assert run.source_host == "old.example.com:8080"

      assert {:error, %Ash.Error.Invalid{}} =
               MishkaCmsMigration.create_run(
                 %{source: "fake", source_host: "https://old.example.com/path"},
                 actor: admin,
                 tenant: site.id
               )
    end

    test "needs a site to be created on", %{admin: admin} do
      assert {:error, %Ash.Error.Invalid{}} =
               MishkaCmsMigration.create_run(%{source: "fake", source_host: "old.example.com"},
                 actor: admin
               )
    end
  end

  describe "its steps" do
    test "a dry run queues its job with the run, the site and who asked", %{
      site: site,
      admin: admin
    } do
      run =
        site
        |> create_run!(admin, rows())
        |> MishkaCmsMigration.start_dry_run!(actor: admin, tenant: site.id)

      assert run.status == :dry_running

      assert_enqueued worker: DryRunWorker,
                      queue: :migration,
                      args: %{run_id: run.id, site_id: site.id, actor_id: admin.id}
    end

    test "an import waits for the dry run's report", %{site: site, admin: admin} do
      run = create_run!(site, admin, rows())

      assert {:error, %Ash.Error.Invalid{}} =
               MishkaCmsMigration.start_import(run, actor: admin, tenant: site.id)

      run = dry_run!(run, admin)
      assert run.status == :dry_run

      run = MishkaCmsMigration.start_import!(run, actor: admin, tenant: site.id)
      assert run.status == :importing
      assert_enqueued worker: ImportWorker, args: %{run_id: run.id}
    end

    test "a dry run may be asked again before the import, and not after", %{
      site: site,
      admin: admin
    } do
      run = site |> create_run!(admin, rows()) |> dry_run!(admin) |> dry_run!(admin)
      assert run.status == :dry_run

      run = import!(run, admin)
      assert run.status == :done

      assert {:error, %Ash.Error.Invalid{}} =
               MishkaCmsMigration.start_dry_run(run, actor: admin, tenant: site.id)
    end

    test "a site has one migration job at a time, and a refused step changes nothing", %{
      site: site,
      admin: admin
    } do
      first = create_run!(site, admin, rows())
      second = create_run!(site, admin, rows())
      MishkaCmsMigration.start_dry_run!(first, actor: admin, tenant: site.id)

      assert {:error, %Ash.Error.Invalid{}} =
               MishkaCmsMigration.start_dry_run(second, actor: admin, tenant: site.id)

      assert MishkaCmsMigration.get_run!(second.id, actor: admin, tenant: site.id).status ==
               :pending

      assert [_one] = all_enqueued(queue: :migration)

      other_site = create_site!()
      other_admin = migration_admin!(other_site)

      assert {:ok, _run} =
               other_site
               |> create_run!(other_admin, rows())
               |> MishkaCmsMigration.start_dry_run(actor: other_admin, tenant: other_site.id)
    end

    test "the steps a job takes are refused to every actor, a master's included", %{
      site: site,
      admin: admin
    } do
      master = create_user_with_permissions!(["*"])

      run =
        site
        |> create_run!(admin, rows())
        |> MishkaCmsMigration.start_dry_run!(actor: admin, tenant: site.id)

      for actor <- [admin, master] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 MishkaCmsMigration.finish_dry_run(run, Report.done(Report.new()),
                   actor: actor,
                   tenant: site.id
                 )

        assert {:error, %Ash.Error.Forbidden{}} =
                 MishkaCmsMigration.fail_run(run, "stop", actor: actor, tenant: site.id)
      end
    end
  end
end
