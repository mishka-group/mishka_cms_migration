# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.MigrationRunTest do
  @moduledoc """
  A run's own life: what creating one keeps, the order its steps may come in, the job each step
  queues, and the one migration job a site may have at a time.
  """
  use MishkaCmsMigration.DataCase, async: false

  alias MishkaCmsMigration.{MigrationRun, Report}
  alias MishkaCmsMigration.Workers.DryRunWorker

  alias MishkaCmsMigration.MigrationRun.Options

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
      assert MigrationRun.open_secret(run) == {:ok, "app password"}
    end

    test "never broadcasts its secret or its connection", %{site: site, admin: admin} do
      :ok = MishkaCmsMigration.TestEndpoint.subscribe("migration_run:#{site.id}:created")
      run = create_run!(site, admin, rows(), %{secret: "app password"})
      run_id = run.id

      assert_receive %Phoenix.Socket.Broadcast{payload: %{data: %{id: ^run_id} = data} = payload}
      assert {data.connection_secret, data.connection, payload.changeset} == {nil, %{}, nil}

      sent = :erlang.term_to_binary(payload)
      assert :binary.match(sent, "app password") == :nomatch
      assert :binary.match(sent, run.connection_secret) == :nomatch
    end

    test "stores the admin's choices with the defaults of the others, and names an unknown one",
         %{site: site, admin: admin} do
      run = create_run!(site, admin, rows(), %{options: %{pages: "publish"}})
      stored = MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id).options

      assert stored == %{
               "authors" => "connect",
               "pages" => "publish",
               "post_address" => "blog",
               "comments" => false
             }

      assert {:ok,
              %Options{
                authors: "connect",
                pages: "publish",
                post_address: "blog",
                comments: false
              }} =
               Options.builder(stored)

      for {options, field} <- [{%{pages: "maybe"}, :pages}, {%{mode: "x"}, :mode}] do
        assert {:error,
                %Ash.Error.Invalid{
                  errors: [%Ash.Error.Changes.InvalidAttribute{field: ^field, path: [:options]}]
                }} =
                 MishkaCmsMigration.create_run(
                   %{source: "fake", source_host: "old.example.com", options: options},
                   actor: admin,
                   tenant: site.id
                 )
      end

      assert [_only_the_first] = Ash.read!(MigrationRun, actor: admin, tenant: site.id)
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

    test "refuses a source that is not installed", %{site: site, admin: admin} do
      assert {:error, %Ash.Error.Invalid{errors: [%{field: :source}]}} =
               MishkaCmsMigration.create_run(%{source: "ghost", source_host: "old.example.com"},
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

      assert [%{queue: "migration", args: args}] = assert_triggered(run, :run_dry_run)

      assert %{
               "tenant" => site_id,
               "actor" => %{"id" => actor_id},
               "site_id" => site_id,
               "actor_id" => actor_id
             } = args

      assert {site_id, actor_id} == {site.id, admin.id}
    end

    test "an import waits for the dry run's report", %{site: site, admin: admin} do
      run = create_run!(site, admin, rows())

      assert {:error, %Ash.Error.Invalid{}} =
               MishkaCmsMigration.start_import(run, actor: admin, tenant: site.id)

      run = dry_run!(run, admin)
      assert run.status == :dry_run

      run = MishkaCmsMigration.start_import!(run, actor: admin, tenant: site.id)
      assert run.status == :importing
      assert_triggered(run, :run_import)
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

      assert {:error, %Ash.Error.Invalid{errors: [%{field: :site_id, message: message}]}} =
               MishkaCmsMigration.start_dry_run(second, actor: admin, tenant: site.id)

      assert message =~ "Another migration of this site"

      assert MishkaCmsMigration.get_run!(second.id, actor: admin, tenant: site.id).status ==
               :pending

      assert [_one] = all_enqueued(queue: :migration)
      refute_triggered(second, :run_dry_run)

      other_site = create_site!()
      other_admin = migration_admin!(other_site)

      assert {:ok, _run} =
               other_site
               |> create_run!(other_admin, rows())
               |> MishkaCmsMigration.start_dry_run(actor: other_admin, tenant: other_site.id)
    end

    test "cancelling a run that is not done cancels its job and frees the site for another", %{
      site: site,
      admin: admin
    } do
      run =
        site
        |> create_run!(admin, rows())
        |> MishkaCmsMigration.start_dry_run!(actor: admin, tenant: site.id)

      [job] = assert_triggered(run, :run_dry_run)
      run = MishkaCmsMigration.cancel_run!(run, actor: admin, tenant: site.id)

      assert {run.status, run.connection_secret} == {:cancelled, nil}
      assert Repo.get!(Oban.Job, job.id).state == "cancelled"
      refute_triggered(run, :run_dry_run)

      assert {:ok, %{status: :dry_running}} =
               site
               |> create_run!(admin, rows())
               |> MishkaCmsMigration.start_dry_run(actor: admin, tenant: site.id)

      assert {:cancel, :trigger_no_longer_applies} = perform_job(DryRunWorker, job.args)

      assert MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id).status ==
               :cancelled
    end

    test "the database itself holds one run of a site dry running or importing", %{
      site: site,
      admin: admin
    } do
      first =
        site
        |> create_run!(admin, rows())
        |> MishkaCmsMigration.start_dry_run!(actor: admin, tenant: site.id)

      second = create_run!(site, admin, rows())

      assert_raise Postgrex.Error, ~r/mishka_cms_migration_runs_one_active_per_site_index/, fn ->
        Repo.query!("UPDATE mishka_cms_migration_runs SET status = 'importing' WHERE id = $1", [
          Ecto.UUID.dump!(second.id)
        ])
      end

      MishkaCmsMigration.cancel_run!(first, actor: admin, tenant: site.id)

      assert {:ok, %{status: :dry_running}} =
               MishkaCmsMigration.start_dry_run(second, actor: admin, tenant: site.id)
    end

    test "a run that is done cannot be cancelled", %{site: site, admin: admin} do
      run = site |> create_run!(admin, rows()) |> dry_run!(admin) |> import!(admin)

      assert {:error, %Ash.Error.Invalid{}} =
               MishkaCmsMigration.cancel_run(run, actor: admin, tenant: site.id)
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
                 MishkaCmsMigration.finish_dry_run(run, Report.done(Report.new()), %{},
                   actor: actor,
                   tenant: site.id
                 )

        assert {:error, %Ash.Error.Forbidden{}} =
                 MishkaCmsMigration.fail_run(run, "stop", actor: actor, tenant: site.id)

        assert {:error, %Ash.Error.Forbidden{}} =
                 run
                 |> Ash.Changeset.for_update(:run_dry_run, %{}, actor: actor, tenant: site.id)
                 |> Ash.update()
      end
    end
  end
end
