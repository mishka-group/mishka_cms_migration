# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.MigrationRunTest do
  @moduledoc """
  A run's own life: what creating one keeps, the order its steps may come in, the job each step
  queues, the one migration job a site may have at a time, and the file a run of a source that
  reads one keeps until it ends.
  """
  use MishkaCmsMigration.DataCase, async: false

  alias MishkaCmsCore.Runtime.Media
  alias MishkaCmsMigration.{MigrationRun, Report}
  alias MishkaCmsMigration.Resources.Changes.SourceFile
  alias MishkaCmsMigration.Workers.DryRunWorker

  alias MishkaCmsMigration.MigrationRun.Options

  setup do
    for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)

    site = create_site!()
    %{site: site, admin: migration_admin!(site)}
  end

  defp rows, do: %{"redirect" => [redirect_row(1, "/old", "/new")]}

  # A WordPress export of one post, written where a test keeps its files.
  defp export!(dir, channel \\ "<wp:wxr_version>1.2</wp:wxr_version>") do
    path = Path.join(dir, "export-#{System.unique_integer([:positive])}.xml")

    File.write!(path, """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:wp="http://wordpress.org/export/1.2/">
    <channel>
    <title>Small blog</title>
    <link>https://small.example.com/</link>
    #{channel}
    <item><title>Hello</title><link>https://small.example.com/hello/</link>
    <wp:post_id>1</wp:post_id><wp:post_name>hello</wp:post_name><wp:status>publish</wp:status>
    <wp:post_type>post</wp:post_type></item>
    </channel>
    </rss>
    """)

    path
  end

  # `path` staged as Gervaz stages a form's upload, as the `file` argument takes it.
  defp upload!(path) do
    staged = Path.join(System.tmp_dir!(), "gervaz_#{System.unique_integer([:positive])}_x.xml")
    File.cp!(path, staged)
    on_exit(fn -> File.rm(staged) end)
    [%{path: staged, client_name: "export.xml", client_type: "text/xml"}]
  end

  defp file_run(site, admin, attrs),
    do:
      attrs
      |> Map.put(:source, "wordpress_file")
      |> MishkaCmsMigration.create_run(actor: admin, tenant: site.id)

  defp kept_files, do: SourceFile.files_dir() |> Path.join("*.xml") |> Path.wildcard()

  describe "creating a run" do
    test "keeps the secret only sealed, on the site, started by the actor", %{
      site: site,
      admin: admin
    } do
      run = create_run!(site, admin, rows(), %{secret: "letmein"})

      assert {run.status, run.site_id, run.user_id} == {:pending, site.id, admin.id}
      refute run.connection_secret == "letmein"
      refute inspect(run) =~ "letmein"
      assert MigrationRun.open_secret(run) == {:ok, "letmein"}
    end

    test "keeps a secret typed into its connection only sealed, never in the connection", %{
      site: site,
      admin: admin
    } do
      for connection <- [
            %{"items" => %{}, "secret" => "letmein"},
            %{items: %{}, secret: "letmein"}
          ] do
        run = create_run!(site, admin, %{}, %{connection: connection, secret: nil})
        stored = MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id)

        assert stored.connection == %{"items" => %{}}
        assert MigrationRun.open_secret(stored) == {:ok, "letmein"}
        refute inspect(stored) =~ "letmein"
      end
    end

    test "takes the secret argument over one typed into its connection", %{
      site: site,
      admin: admin
    } do
      typed = %{"items" => %{}, "secret" => "typed"}
      run = create_run!(site, admin, %{}, %{connection: typed, secret: "letmein"})
      stored = MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id)

      assert stored.connection == %{"items" => %{}}
      assert MigrationRun.open_secret(stored) == {:ok, "letmein"}

      assert {:error, %Ash.Error.Invalid{errors: [%{field: :connection}]}} =
               MishkaCmsMigration.create_run(
                 %{
                   source: "fake",
                   source_host: "old.example.com",
                   connection: %{"items" => %{}, "secret" => "letmein"},
                   secret: "wrong"
                 },
                 actor: admin,
                 tenant: site.id
               )
    end

    test "never broadcasts its secret or its connection", %{site: site, admin: admin} do
      :ok = MishkaCmsMigration.TestEndpoint.subscribe("migration_run:#{site.id}:created")
      run = create_run!(site, admin, rows(), %{secret: "letmein"})
      run_id = run.id

      assert_receive %Phoenix.Socket.Broadcast{payload: %{data: %{id: ^run_id} = data} = payload}
      assert {data.connection_secret, data.connection, payload.changeset} == {nil, %{}, nil}

      sent = :erlang.term_to_binary(payload)
      assert :binary.match(sent, "letmein") == :nomatch
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

    test "asks for the address in words, not as a missing value, when none can be read", %{
      site: site,
      admin: admin
    } do
      assert {:error, %Ash.Error.Invalid{errors: [%{field: :source_host, message: message}]}} =
               MishkaCmsMigration.create_run(%{source: "ghost"}, actor: admin, tenant: site.id)

      assert message =~ "Type the site's address"
    end

    test "needs a site to be created on", %{admin: admin} do
      assert {:error, %Ash.Error.Invalid{}} =
               MishkaCmsMigration.create_run(%{source: "fake", source_host: "old.example.com"},
                 actor: admin
               )
    end
  end

  describe "creating a run connects to its source first" do
    test "and keeps what the source says of itself", %{site: site, admin: admin} do
      facts = %{"version" => "6.5", "name" => "Old blog"}
      run = create_run!(site, admin, %{}, %{connection: %{"items" => %{}, "facts" => facts}})

      assert run.extra == facts
    end

    test "and saves nothing when the source refuses, saying why on the connection", %{
      site: site,
      admin: admin
    } do
      assert {:error, %Ash.Error.Invalid{errors: [%{field: :connection} = error]}} =
               MishkaCmsMigration.create_run(
                 %{source: "fake", source_host: "old.example.com", secret: "wrong"},
                 actor: admin,
                 tenant: site.id
               )

      assert MishkaGervaz.Errors.translate_error(error.message, error.vars) =~
               "Fake did not accept this user and application password"

      assert Ash.read!(MigrationRun, actor: admin, tenant: site.id) == []
    end

    test "and takes the source host from the connection's address when it names none", %{
      site: site,
      admin: admin
    } do
      connection = %{"url" => " https://Old.Example.com/blog ", "items" => %{}}
      run = create_run!(site, admin, %{}, %{source_host: nil, connection: connection})

      assert run.source_host == "old.example.com"

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               MishkaCmsMigration.create_run(
                 %{source: "fake", connection: %{"url" => "old blog"}, secret: "letmein"},
                 actor: admin,
                 tenant: site.id
               )

      assert Enum.any?(errors, &(&1.field == :connection))
    end

    test "sent empty by a master, names the site once and the address in words, and no host", %{
      site: _site
    } do
      master = create_user_with_permissions!(["admin:dashboard:migration"])

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               MigrationRun
               |> Ash.Changeset.for_create(:master_create, %{source: "fake"}, actor: master)
               |> Ash.create()

      fields = Enum.map(errors, &Map.get(&1, :field))

      assert :connection in fields
      refute :source_host in fields
      assert [site_error] = Enum.filter(errors, &(Map.get(&1, :field) == :site_id))
      assert site_error.message =~ "Pick the site"
    end

    test "for a master, on the site the master names", %{site: site} do
      master = create_user_with_permissions!(["admin:dashboard:migration"])

      run =
        MigrationRun
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            site_id: site.id,
            source: "fake",
            source_host: "old.example.com",
            connection: %{"items" => %{}},
            secret: "letmein"
          },
          actor: master
        )
        |> Ash.create!()

      assert {run.site_id, run.user_id, run.status} == {site.id, master.id, :pending}
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

  describe "the source's file" do
    @describetag :tmp_dir

    test "is kept outside the folder the CMS serves, readable by the CMS alone, and is what its job reads",
         %{site: site, admin: admin, tmp_dir: dir} do
      export = export!(dir)
      assert {:ok, run} = file_run(site, admin, %{file: upload!(export)})
      kept = run.connection["file"]
      on_exit(fn -> File.rm(kept) end)

      assert {run.source_host, run.extra["name"]} == {"small.example.com", "Small blog"}
      assert Path.dirname(kept) == SourceFile.files_dir()
      refute String.starts_with?(Path.expand(kept), Path.expand(Media.static_dir()))
      assert File.read!(kept) == File.read!(export)
      assert Bitwise.band(File.stat!(kept).mode, 0o777) == 0o600

      run = dry_run!(run, admin)

      assert [%{kind: "post", source_id: "1", title: "Hello"}] =
               Enum.filter(run.report.entries, &(&1.kind == "post"))
    end

    test "is only ever a file the form staged, never one a connection or a request names",
         %{site: site, admin: admin, tmp_dir: dir} do
      export = export!(dir)

      for attrs <- [
            %{connection: %{"file" => export}},
            %{connection: %{file: export}},
            %{file: [%{path: export, client_name: "export.xml"}]},
            %{file: [%{"path" => "/etc/passwd", "client_name" => "passwd.xml"}]},
            %{}
          ] do
        assert {:error, %Ash.Error.Invalid{errors: [%{field: :file} = error]}} =
                 file_run(site, admin, attrs)

        assert MishkaGervaz.Errors.translate_error(error.message, error.vars) ==
                 "Choose the WordPress export file to read."
      end

      typed = create_run!(site, admin, %{}, %{connection: %{"items" => %{}, "file" => export}})

      assert MishkaCmsMigration.get_run!(typed.id, actor: admin, tenant: site.id).connection ==
               %{"items" => %{}}

      assert [_fake_run_only] = Ash.read!(MigrationRun, actor: admin, tenant: site.id)
    end

    test "that is not an export is refused on the file in words, and no copy of it is kept",
         %{site: site, admin: admin, tmp_dir: dir} do
      before = kept_files()

      for path <- [export!(dir, ""), Path.join(dir, "notes.xml")] do
        File.exists?(path) || File.write!(path, "Some notes, not an export.")

        assert {:error, %Ash.Error.Invalid{errors: [%{field: :file} = error]}} =
                 file_run(site, admin, %{file: upload!(path)})

        assert MishkaGervaz.Errors.translate_error(error.message, error.vars) =~
                 "This is not a WordPress export file, or it is damaged."
      end

      assert kept_files() == before
      assert Ash.read!(MigrationRun, actor: admin, tenant: site.id) == []
    end

    @tag capture_log: true
    test "is deleted once the run ends: cancelled, imported or failed",
         %{site: site, admin: admin, tmp_dir: dir} do
      {:ok, cancelled} = file_run(site, admin, %{file: upload!(export!(dir))})
      MishkaCmsMigration.cancel_run!(cancelled, actor: admin, tenant: site.id)
      refute File.exists?(cancelled.connection["file"])

      {:ok, imported} = file_run(site, admin, %{file: upload!(export!(dir))})
      assert %{status: :dry_run} = imported = dry_run!(imported, admin)
      assert File.exists?(imported.connection["file"])
      assert %{status: :done} = import!(imported, admin)
      refute File.exists?(imported.connection["file"])

      {:ok, failed} = file_run(site, admin, %{file: upload!(export!(dir))})
      failed = MishkaCmsMigration.start_dry_run!(failed, actor: admin, tenant: site.id)
      [job] = assert_triggered(failed, :run_dry_run)
      File.write!(failed.connection["file"], "Damaged since.")

      assert :ok = perform_job(DryRunWorker, job.args, attempt: 3)

      assert %{status: :failed, reason: "unreadable_file"} =
               MishkaCmsMigration.get_run!(failed.id, actor: admin, tenant: site.id)

      refute File.exists?(failed.connection["file"])
    end
  end
end
