# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Live.HomePageTest do
  @moduledoc """
  The migration's admin page and its sidebar entry: who may open the page, where the entry lands,
  the card of each installed source, and the runs table, which shows a site's own runs, follows
  them as they move on, offers the steps each status allows and, expanded, what a dry run found.
  """
  use MishkaCmsMigration.ConnCase, async: false
  use AshOban.Test, repo: MishkaCmsMigration.Repo

  import Phoenix.LiveViewTest
  import MishkaCmsMigration.DataCase, only: [register_plugin!: 2]
  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0, stub!: 1]

  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsMigration.MigrationRun
  alias MishkaCmsMigration.Sources.WordPress
  alias MishkaCmsMigration.Test.Plugins.TokenSource
  alias MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.Index
  alias MishkaCmsMigrationWeb.SidebarMenu

  @page "/admin/dashboard/migration"
  @wordpress_inputs [{"url", "text"}, {"user", "text"}, {"secret", "password"}]

  setup %{conn: conn} do
    site = create_site!(name: "localhost", host: "localhost", master: true)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: true,
        master: true
      })

    {:ok, conn: on_host(conn, "localhost"), site: site}
  end

  describe "the page" do
    test "opens for an admin who may run migrations", %{conn: conn, site: site} do
      admin = migration_admin!(site, ["admin:dashboard:migration"])
      {:ok, view, _html} = conn |> signed_in(admin) |> live(@page)

      assert has_element?(view, "#migration-page h1", "Migration")
    end

    test "is refused to an admin without the migration permission", %{conn: conn, site: site} do
      admin = migration_admin!(site, ["admin:dashboard:runtime:redirect"])

      assert {:error, {_redirect, %{to: _elsewhere}}} = conn |> signed_in(admin) |> live(@page)
    end
  end

  defp open!(conn, user) do
    {:ok, view, _html} = conn |> signed_in(user) |> live(@page)
    render_async(view)
    view
  end

  defp new_import!(view, source \\ "wordpress") do
    view
    |> element(~s|[data-source="#{source}"] [data-role="migration-new-run"]|)
    |> render_click()
  end

  # Sends the form as an admin fills it in: the connection's keys, and the secret typed into the
  # connection's password key.
  defp submit!(view, connection, secret) do
    view
    |> form(~s|#migration-run-form-modal form|, %{
      "form" => %{"connection" => Map.put(connection, "secret", secret)}
    })
    |> render_submit()
  end

  # The connection keys the form draws, in order, each as `{key, input type}`.
  defp connection_inputs(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s|#migration-run-form-modal input[name^="form[connection]["]|)
    |> Enum.map(fn input ->
      [name] = LazyHTML.attribute(input, "name")
      [type] = LazyHTML.attribute(input, "type")
      {name |> String.trim_leading("form[connection][") |> String.trim_trailing("]"), type}
    end)
  end

  # The run's choices the form draws, each as `{chosen value, every value offered}` by its key.
  defp choices(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s|#migration-run-form-modal select[name^="form[options]["]|)
    |> Map.new(fn select ->
      [name] = LazyHTML.attribute(select, "name")
      [chosen] = select |> LazyHTML.query("option[selected]") |> LazyHTML.attribute("value")
      offered = select |> LazyHTML.query("option") |> LazyHTML.attribute("value")

      {name |> String.trim_leading("form[options][") |> String.trim_trailing("]"),
       {chosen, Enum.reject(offered, &(&1 == ""))}}
    end)
  end

  defp secret_input_value(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s|#migration-run-form-modal input[name="form[connection][secret]"]|)
    |> LazyHTML.attribute("value")
  end

  defp stored(run),
    do: MishkaCmsMigration.get_run!(run.id, tenant: run.site_id, authorize?: false)

  defp filter!(view, params) do
    view |> form("#migration-runs-table_migration_runs-filter", params) |> render_change()
    render_async(view)
  end

  defp settled(view) do
    _state = :sys.get_state(view.pid)
    _state = :sys.get_state(view.pid)
    render(view)
  end

  defp action(event, run), do: ~s|[phx-value-event="#{event}"][phx-value-values*="#{run.id}"]|

  defp row_action!(view, event, run) do
    view |> element("#migration-runs-table #{action(event, run)}") |> render_click()
    settled(view)
  end

  defp crafted!(view, event, id) do
    view
    |> with_target("#migration-runs-table")
    |> render_click("custom_event", %{"event" => event, "values" => Jason.encode!(%{"id" => id})})

    settled(view)
  end

  defp expand!(view, run) do
    view
    |> element(~s|#migration-runs-table [phx-click="expand_row"][phx-value-id="#{run.id}"]|)
    |> render_click()

    settled(view)
  end

  @result ~s|[data-role="run-result"]|
  @details ~s|[data-role="run-details"]|

  defp outcomes(view), do: counted(view, @result, "run-outcome", "data-outcome")
  defp kinds(view), do: counted(view, @result, "run-kind", "data-kind")

  # The parts of `role` within `scope` (the Result cells, or the expanded row), as their `key`
  # attribute to their `count` one.
  defp counted(view, scope, role, key, count \\ "data-count") do
    found = parts(view, scope, role)

    found
    |> LazyHTML.attribute(key)
    |> Enum.zip(found |> LazyHTML.attribute(count) |> Enum.map(&String.to_integer/1))
    |> Map.new()
  end

  # The `key` attribute of each part of the expanded row whose `data-role` is `role`, in order.
  defp detailed(view, role, key), do: view |> parts(@details, role) |> LazyHTML.attribute(key)

  # The expanded row's parts of `role`, within `within` when given, as `counted/5` reads them.
  defp detailed_counts(view, role, key, count \\ "data-count", within \\ ""),
    do: counted(view, "#{@details} #{within}", role, key, count)

  defp parts(view, scope, role) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s|#{scope} [data-role="#{role}"]|)
  end

  defp status(run), do: stored(run).status

  describe "the source cards" do
    test "show each installed source", %{conn: conn, site: site} do
      for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)
      view = open!(conn, migration_admin!(site))

      assert has_element?(view, ~s|[data-role="migration-source"][data-source="fake"]|, "Fake")
      refute has_element?(view, ~s|[data-role="migration-no-source"]|)
    end

    test "say so when no source is installed", %{conn: conn, site: site} do
      {:ok, _stopped} = MishkaInstaller.Event.Event.stop(:name, WordPress, false)
      on_exit(fn -> {:ok, _enabled} = MishkaInstaller.Event.Event.enable(WordPress, false) end)

      view = open!(conn, migration_admin!(site))

      assert has_element?(view, ~s|[data-role="migration-no-source"]|)
      refute has_element?(view, ~s|[data-role="migration-source"]|)
    end
  end

  describe "a source's New import" do
    setup do
      Req.Test.set_req_test_to_shared()
      on_exit(&Req.Test.set_req_test_to_private/0)
      :ok
    end

    test "checks the connection, saves the run and shows it", %{conn: conn, site: site} do
      stub!()
      admin = migration_admin!(site)
      view = open!(conn, admin)

      new_import!(view)
      refute has_element?(view, ~s|#migration-run-form-modal [name="form[source]"]|)
      refute has_element?(view, ~s|#migration-run-form-modal [name*="site_id"]|)
      submit!(view, %{"url" => "http://localhost:8089", "user" => "admin"}, "app password")

      assert [run] = Ash.read!(MigrationRun, actor: admin, tenant: site.id)

      assert {run.source, run.source_host, run.status, run.extra["name"]} ==
               {"wordpress", "localhost:8089", :pending, "Mishka Test Blog"}

      assert stored(run).connection == %{"url" => "http://localhost:8089", "user" => "admin"}
      assert MigrationRun.open_secret(run) == {:ok, "app password"}
      assert settled(view) =~ "Connected to Mishka Test Blog."
      assert has_element?(view, ~s|[data-role="run-source"]|, "WordPress")
      assert has_element?(view, "#migration-runs-table", "Mishka Test Blog")
      assert has_element?(view, ~s|[data-role="run-status"][data-status="pending"]|)
    end

    test "asks WordPress's address, user and application password, the password masked", %{
      conn: conn,
      site: site
    } do
      view = open!(conn, migration_admin!(site))
      new_import!(view)

      assert connection_inputs(view) == @wordpress_inputs

      for label <- ["Address", "User", "Application password"],
          do: assert(has_element?(view, "#migration-run-form-modal label", label))
    end

    test "keeps the form open with the reason, and saves nothing, when WordPress refuses", %{
      conn: conn,
      site: site
    } do
      stub!(%{"/wp-json/wp/v2/users/me" => "unauthorized-users-me-wrong-password"})
      admin = migration_admin!(site)
      view = open!(conn, admin)

      new_import!(view)

      html =
        submit!(view, %{"url" => "http://localhost:8089", "user" => "admin"}, "typed-pass-9f3")

      assert html =~ "WordPress did not accept this user and application password"
      refute html =~ "typed-pass-9f3"
      assert secret_input_value(view) in [[], [""]]
      assert Ash.read!(MigrationRun, actor: admin, tenant: site.id) == []
    end
  end

  describe "each source's New import" do
    setup do
      register_plugin!(TokenSource, MishkaCmsMigration.Source.event())
      :ok
    end

    test "asks for that source's own connection keys, each time the form starts over", %{
      conn: conn,
      site: site
    } do
      view = open!(conn, migration_admin!(site))

      new_import!(view)
      assert connection_inputs(view) == @wordpress_inputs

      new_import!(view, "token")

      assert connection_inputs(view) == [
               {"url", "text"},
               {"workspace", "text"},
               {"secret", "password"}
             ]

      assert has_element?(view, "#migration-run-form-modal label", "API token")
      refute has_element?(view, "#migration-run-form-modal label", "Application password")

      new_import!(view)
      assert connection_inputs(view) == @wordpress_inputs
    end

    test "creates a run of that source with its own keys, its token kept only sealed", %{
      conn: conn,
      site: site
    } do
      admin = migration_admin!(site)
      view = open!(conn, admin)

      new_import!(view)
      new_import!(view, "token")

      submit!(
        view,
        %{"url" => "https://notes.example.com", "workspace" => "Team notes"},
        "t0ken"
      )

      assert [run] = Ash.read!(MigrationRun, actor: admin, tenant: site.id)

      assert {run.source, run.source_host, run.extra["name"]} ==
               {"token", "notes.example.com", "Team notes"}

      assert stored(run).connection == %{
               "url" => "https://notes.example.com",
               "workspace" => "Team notes"
             }

      assert MigrationRun.open_secret(run) == {:ok, "t0ken"}
      assert settled(view) =~ "Connected to Team notes."

      new_import!(view)
      assert connection_inputs(view) == @wordpress_inputs
    end
  end

  describe "the New import form" do
    test "asks a master for the site, and a site admin never", %{conn: conn, site: site} do
      master = create_user_with_permissions!(["admin:dashboard:migration"])
      view = open!(conn, master)
      new_import!(view)
      assert has_element?(view, ~s|#migration-run-form-modal [name*="site_id"]|)

      view = open!(build_conn() |> on_host("localhost"), migration_admin!(site))
      new_import!(view)
      refute has_element?(view, ~s|#migration-run-form-modal [name*="site_id"]|)
    end

    test "sent empty, says in words what the address needs and saves nothing", %{
      conn: conn,
      site: site
    } do
      admin = migration_admin!(site)
      view = open!(conn, admin)

      new_import!(view)
      html = submit!(view, %{"url" => "", "user" => ""}, "")

      assert html =~ "Type the site&#39;s address, such as https://example.com."
      refute html =~ "must be present"
      assert Ash.read!(MigrationRun, actor: admin, tenant: site.id) == []
    end

    test "sent empty by a master, asks for the site once", %{conn: conn} do
      master = create_user_with_permissions!(["admin:dashboard:migration"])
      view = open!(conn, master)

      new_import!(view)
      html = submit!(view, %{"url" => "", "user" => ""}, "")

      assert length(String.split(html, "Pick the site the content moves to.")) == 2
      refute html =~ "is required"
      refute html =~ "must be present"
    end

    test "asks for the run's choices, each at its default, and offers no address it cannot keep",
         %{conn: conn, site: site} do
      view = open!(conn, migration_admin!(site))
      new_import!(view)
      {:ok, defaults} = MigrationRun.Options.builder(%{})

      assert choices(view) == %{
               "authors" => {defaults.authors, ["connect", "create"]},
               "pages" => {defaults.pages, ["draft", "publish"]},
               "post_address" => {defaults.post_address, ["blog", "blog_without_redirects"]}
             }

      for label <- ["Choices for this run", "Authors", "Pages", "Post addresses"],
          do: assert(has_element?(view, "#migration-run-form-modal label", label))

      assert has_element?(
               view,
               "#migration-run-form-modal",
               "needs the Blog to serve posts there"
             )
    end

    test "saves what the admin chose into the run's options, and the default of the rest", %{
      conn: conn,
      site: site
    } do
      stub!()
      admin = migration_admin!(site)
      view = open!(conn, admin)
      new_import!(view)

      view
      |> form(~s|#migration-run-form-modal form|, %{
        "form" => %{
          "connection" => %{
            "url" => "http://localhost:8089",
            "user" => "admin",
            "secret" => "app password"
          },
          "options" => %{"authors" => "create", "post_address" => "blog_without_redirects"}
        }
      })
      |> render_submit()

      assert [run] = Ash.read!(MigrationRun, actor: admin, tenant: site.id)

      assert stored(run).options == %{
               "authors" => "create",
               "pages" => "draft",
               "post_address" => "blog_without_redirects",
               "comments" => false
             }
    end
  end

  describe "the runs table" do
    setup do
      for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)
      :ok
    end

    test "is empty before the first run", %{conn: conn, site: site} do
      view = open!(conn, migration_admin!(site))

      assert has_element?(view, "#migration-runs-table", "No runs found")
    end

    test "lists the site's runs with their source, address, status and result", %{
      conn: conn,
      site: site
    } do
      admin = migration_admin!(site)

      site
      |> create_run!(admin, %{"redirect" => [redirect_row(1, "/a", "/b")]})
      |> dry_run!(admin)

      view = open!(conn, admin)

      assert has_element?(view, ~s|[data-role="run-source"]|, "Fake")
      assert has_element?(view, "#migration-runs-table", "old.example.com")
      assert has_element?(view, ~s|[data-role="run-status"][data-status="dry_run"]|)
      assert outcomes(view) == %{"created" => 1}
      assert kinds(view) == %{"redirect" => 1}
    end

    test "shows no other site's runs", %{conn: conn, site: site} do
      other = create_site!()
      other_admin = migration_admin!(other)
      create_run!(other, other_admin, %{}, %{source_host: "elsewhere.example.com"})

      view = open!(conn, migration_admin!(site))

      refute has_element?(view, "#migration-runs-table", "elsewhere.example.com")
      assert has_element?(view, "#migration-runs-table", "No runs found")
    end

    test "shows a new run, and its status as it moves on, without a reload", %{
      conn: conn,
      site: site
    } do
      admin = migration_admin!(site)
      view = open!(conn, admin)

      run = create_run!(site, admin, %{})
      assert settled(view) =~ "old.example.com"
      assert has_element?(view, ~s|[data-role="run-status"][data-status="pending"]|)

      dry_run!(run, admin)
      settled(view)
      assert has_element?(view, ~s|[data-role="run-status"][data-status="dry_run"]|)
    end
  end

  describe "a run's Result while its job runs" do
    setup %{site: site} do
      for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)
      {:ok, admin: migration_admin!(site)}
    end

    defp walked!(run, kind, created) do
      MishkaCmsMigration.record_progress!(
        run,
        %{kind: kind, counts: %{created: created, updated: 0, skipped: 0, failed: 0}},
        tenant: run.site_id,
        authorize?: false
      )
    end

    defp start_dry_run!(run, admin),
      do: MishkaCmsMigration.start_dry_run!(run, actor: admin, tenant: run.site_id)

    test "shows how far the job is in place of the last report, of the items that report counted",
         %{conn: conn, site: site, admin: admin} do
      rows = for id <- 1..3, do: redirect_row(id, "/old-#{id}", "/new-#{id}")
      run = site |> create_run!(admin, %{"redirect" => rows}) |> dry_run!(admin)
      assert run.progress.kind == "redirect"

      view = open!(conn, admin)
      assert outcomes(view) == %{"created" => 3}

      run = start_dry_run!(run, admin)
      settled(view)

      assert has_element?(view, ~s|[data-role="run-progress"][data-done="0"]|)
      refute has_element?(view, ~s|[data-role="run-progress"][data-kind]|)
      assert outcomes(view) == %{}
      assert kinds(view) == %{}

      walked!(run, "redirect", 2)
      settled(view)

      assert has_element?(
               view,
               ~s|[data-role="run-progress"][data-kind="redirect"][data-done="2"][data-total="3"]|
             )

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
      settled(view)

      refute has_element?(view, ~s|[data-role="run-progress"]|)
      assert outcomes(view) == %{"created" => 3}
    end

    test "counts the items met so far, of no total, on a run's first dry run", %{
      conn: conn,
      site: site,
      admin: admin
    } do
      run = site |> create_run!(admin, %{}) |> start_dry_run!(admin)
      view = open!(conn, admin)

      walked!(run, "redirect", 4)
      settled(view)

      assert has_element?(
               view,
               ~s|[data-role="run-progress"][data-kind="redirect"][data-done="4"]|
             )

      refute has_element?(view, ~s|[data-role="run-progress"][data-total]|)
    end
  end

  describe "the runs table filters" do
    setup %{site: site} do
      for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)
      admin = migration_admin!(site)
      create_run!(site, admin, %{}, %{source_host: "waiting.example.com"})

      site
      |> create_run!(admin, %{"redirect" => [redirect_row(1, "/a", "/b")]})
      |> dry_run!(admin)

      {:ok, admin: admin}
    end

    test "offer every status and each installed source", %{conn: conn, admin: admin} do
      view = open!(conn, admin)

      for status <- MigrationRun.status_options() do
        assert has_element?(
                 view,
                 ~s|#migration-runs-table-filter-status option[value="#{elem(status, 1)}"]|
               )
      end

      for source <- MishkaCmsMigration.Source.all() do
        assert has_element?(
                 view,
                 ~s|#migration-runs-table-filter-source option[value="#{source.id()}"]|
               )
      end
    end

    test "narrow the rows to the chosen status, and back again", %{conn: conn, admin: admin} do
      view = open!(conn, admin)
      assert has_element?(view, ~s|[data-role="run-status"]|, "Connected")
      assert has_element?(view, ~s|[data-role="run-status"]|, "Dry run ready")

      filter!(view, %{"status" => "dry_run"})

      assert has_element?(view, "#migration-runs-table", "old.example.com")
      refute has_element?(view, "#migration-runs-table", "waiting.example.com")
      refute has_element?(view, ~s|[data-role="run-status"][data-status="pending"]|)

      filter!(view, %{"status" => ""})

      assert has_element?(view, "#migration-runs-table", "waiting.example.com")
      assert has_element?(view, "#migration-runs-table", "old.example.com")
    end

    test "narrow the rows to the chosen source", %{conn: conn, admin: admin} do
      view = open!(conn, admin)

      filter!(view, %{"source" => "wordpress"})
      assert has_element?(view, "#migration-runs-table", "No runs found")
      refute has_element?(view, ~s|[data-role="run-source"]|)

      filter!(view, %{"source" => "fake"})
      assert has_element?(view, ~s|[data-role="run-source"]|, "Fake")
    end

    test "narrow the rows to the days the run started in", %{conn: conn, admin: admin} do
      view = open!(conn, admin)
      today = Date.utc_today()
      day = fn offset -> today |> Date.add(offset) |> Date.to_iso8601() end

      filter!(view, %{"started_from" => day.(1), "started_to" => day.(2)})
      assert has_element?(view, "#migration-runs-table", "No runs found")

      filter!(view, %{"started_from" => day.(-1), "started_to" => day.(1)})
      assert has_element?(view, "#migration-runs-table", "old.example.com")
    end

    test "keep the status in the address, so a reload shows the same rows", %{
      conn: conn,
      admin: admin
    } do
      {:ok, view, _html} =
        conn |> signed_in(admin) |> live("#{@page}?runs_filter_status=dry_run")

      render_async(view)

      assert has_element?(view, "#migration-runs-table", "old.example.com")
      refute has_element?(view, "#migration-runs-table", "waiting.example.com")
    end

    test "offer the site, and show it in a column, to a master alone", %{
      conn: conn,
      site: site
    } do
      view = open!(conn, create_user_with_permissions!(["admin:dashboard:migration"]))
      assert has_element?(view, "#migration-runs-table-filter-site_id")
      assert has_element?(view, ~s|#migration-runs-table [phx-value-column="site_info"]|)
      assert has_element?(view, "#migration-runs-table", site.name)

      view = open!(build_conn() |> on_host("localhost"), migration_admin!(site))
      refute has_element?(view, "#migration-runs-table-filter-site_id")
      refute has_element?(view, ~s|#migration-runs-table [phx-value-column="site_info"]|)
    end
  end

  describe "a WordPress run's Dry run" do
    setup do
      Req.Test.set_req_test_to_shared()
      on_exit(&Req.Test.set_req_test_to_private/0)
      :ok
    end

    test "queues the job, and once it is done shows what it found, kind by kind, without a reload",
         %{conn: conn, site: site} do
      stub!()
      admin = migration_admin!(site)

      run =
        MishkaCmsMigration.create_run!(
          %{
            source: "wordpress",
            connection: %{"url" => "http://localhost:8089", "user" => "admin"},
            secret: "app password"
          },
          actor: admin,
          tenant: site.id
        )

      view = open!(conn, admin)
      expand!(view, run)
      assert has_element?(view, ~s|[data-role="run-details"][data-status="pending"]|)
      assert has_element?(view, ~s|[data-role="run-details-empty"]|, "No dry run yet")
      assert detailed(view, "run-details-reads", "data-kind") == ~w(user category tag page post)
      assert outcomes(view) == %{}

      assert row_action!(view, "dry_run", run) =~ "Dry run started."
      assert [_job] = assert_triggered(run, :run_dry_run)
      assert has_element?(view, ~s|[data-role="run-status"][data-status="dry_running"]|)
      assert has_element?(view, ~s|[data-role="run-progress"][data-done="0"]|)
      refute has_element?(view, "#migration-runs-table #{action("dry_run", run)}")

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
      settled(view)

      assert has_element?(
               view,
               ~s|[data-role="run-status"][data-status="dry_run"]|,
               "Dry run ready"
             )

      assert outcomes(view) == %{"created" => 41, "skipped" => 16}
      assert has_element?(view, ~s|[data-role="run-outcome"][data-reason="no_target"]|)

      assert kinds(view) == %{
               "user" => 5,
               "category" => 9,
               "tag" => 11,
               "page" => 11,
               "post" => 21
             }

      assert has_element?(view, "#migration-runs-table #{action("dry_run", run)}", "Run again")

      assert detailed_counts(view, "run-details-kind", "data-kind", "data-found") == %{
               "user" => 5,
               "category" => 9,
               "tag" => 11,
               "page" => 11,
               "post" => 21
             }

      assert detailed_counts(view, "run-details-outcome", "data-outcome") ==
               %{"created" => 41, "skipped" => 16}

      refute has_element?(view, ~s|[data-role="run-details-empty"]|)
    end

    test "an expanded run shows what each kind would become and why, its latest items and what the WordPress site said of itself",
         %{conn: conn, site: site} do
      stub!()
      admin = migration_admin!(site)

      run =
        %{
          source: "wordpress",
          connection: %{"url" => "http://localhost:8089", "user" => "admin"},
          secret: "app password"
        }
        |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)
        |> dry_run!(admin)

      view = open!(conn, admin)
      expand!(view, run)

      for {kind, found} <- [{"category", 9}, {"tag", 11}, {"post", 21}] do
        card = ~s|[data-role="run-details-kind"][data-kind="#{kind}"]|

        assert detailed_counts(view, "run-details-segment", "data-outcome", "data-count", card) ==
                 %{"created" => found}

        refute has_element?(view, ~s|#{card} [data-role="run-details-kind-reason"]|)
      end

      for {kind, found, why} <- [
            {"user", 5, "No user with this email on the site"},
            {"page", 11, "Nothing imports these yet"}
          ] do
        card = ~s|[data-role="run-details-kind"][data-kind="#{kind}"]|

        assert detailed_counts(view, "run-details-segment", "data-outcome", "data-count", card) ==
                 %{"skipped" => found}

        assert has_element?(
                 view,
                 ~s|#{card} [data-role="run-details-kind-reason"][data-outcome="skipped"]|,
                 why
               )
      end

      newest_posts =
        "posts"
        |> MishkaCmsMigration.Test.WordPress.recorded()
        |> Enum.map(&to_string(&1["id"]))
        |> Enum.take(-8)
        |> Enum.reverse()

      assert detailed(view, "run-details-item", "data-source-id") == newest_posts
      assert detailed(view, "run-details-item", "data-kind") == List.duplicate("post", 8)
      assert detailed(view, "run-details-item", "data-outcome") == List.duplicate("created", 8)

      assert has_element?(
               view,
               ~s|[data-role="run-details-item"][data-source-id="34"] [data-role="run-details-item-reason"]|,
               "Kept as text: unknown_plugin_shortcode, pullbox"
             )

      assert detailed(view, "run-details-items-more", "data-count") == ["49"]

      for {fact, said} <- [
            {"name", "Mishka Test Blog"},
            {"home", "localhost:8089"},
            {"timezone", "Asia/Tehran"},
            {"signed_in_as", "admin"}
          ],
          do:
            assert(
              has_element?(view, ~s|[data-role="run-details-fact"][data-fact="#{fact}"]|, said)
            )

      assert has_element?(
               view,
               ~s|[data-fact="home"] a[href="http://localhost:8089"][target="_blank"][rel~="noopener"]|
             )

      assert detailed(view, "run-details-option", "data-value") == [
               "connect",
               "draft",
               "blog",
               "false"
             ]
    end
  end

  describe "a WordPress run's Import" do
    @blog_admin ["admin:dashboard:migration", "admin:dashboard:blog:post"]

    setup %{site: site} do
      stub!()
      Req.Test.set_req_test_to_shared()
      on_exit(&Req.Test.set_req_test_to_private/0)
      {:ok, admin: migration_admin!(site, @blog_admin)}
    end

    test "queues the job, and once it is done shows the run as Imported with what it created, without a reload",
         %{conn: conn, site: site, admin: admin} do
      run =
        %{
          source: "wordpress",
          connection: %{"url" => "http://localhost:8089", "user" => "admin"},
          secret: "app password"
        }
        |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)
        |> dry_run!(admin)

      view = open!(conn, admin)
      expand!(view, run)
      assert has_element?(view, ~s|[data-role="run-details"][data-status="dry_run"]|)
      assert has_element?(view, "#migration-runs-table #{action("import", run)}", "Import")
      assert Ash.read!(MishkaBlog.Tag, tenant: site.id, authorize?: false) == []

      assert row_action!(view, "import", run) =~ "Import started."
      assert [_job] = assert_triggered(run, :run_import)
      assert has_element?(view, ~s|[data-role="run-status"][data-status="importing"]|)
      refute has_element?(view, "#migration-runs-table #{action("import", run)}")

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
      settled(view)

      assert has_element?(
               view,
               ~s|[data-role="run-status"][data-status="done"]|,
               "Imported"
             )

      assert outcomes(view) == %{"created" => 41, "skipped" => 16}

      assert has_element?(
               view,
               ~s|[data-role="run-details"][data-status="done"][data-step="import"]|
             )

      assert detailed_counts(view, "run-details-outcome", "data-outcome") ==
               %{"created" => 41, "skipped" => 16}

      for {kind, created} <- [{"category", 9}, {"tag", 11}, {"post", 21}] do
        card = ~s|[data-role="run-details-kind"][data-kind="#{kind}"]|

        assert detailed_counts(view, "run-details-segment", "data-outcome", "data-count", card) ==
                 %{"created" => created}
      end

      assert length(Ash.read!(MishkaBlog.Tag, tenant: site.id, authorize?: false)) == 11
      assert length(Ash.read!(MishkaBlog.BlogPost, tenant: site.id, authorize?: false)) == 21
      refute has_element?(view, "#migration-runs-table #{action("import", run)}")
    end
  end

  describe "a run's expanded row" do
    setup %{site: site} do
      for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)
      {:ok, admin: migration_admin!(site)}
    end

    test "follows a dry run's job as it walks the source's kinds, then shows what it found", %{
      conn: conn,
      site: site,
      admin: admin
    } do
      rows = for id <- 1..3, do: redirect_row(id, "/old-#{id}", "/new-#{id}")
      run = site |> create_run!(admin, %{"redirect" => rows}) |> start_dry_run!(admin)
      view = open!(conn, admin)
      expand!(view, run)

      bar = ~s|[data-role="run-details-progress-bar"]|
      assert has_element?(view, ~s|#{bar}[aria-valuenow="0"][aria-valuemax="4"]|)
      refute has_element?(view, ~s|#{bar}[data-kind]|)
      assert detailed(view, "run-details-progress-step", "data-state") == ~w(next next next next)

      walked!(run, "note", 2)
      settled(view)

      assert has_element?(view, ~s|#{bar}[data-kind="note"][aria-valuenow="1"]|)

      assert detailed(view, "run-details-progress-step", "data-state") ==
               ~w(done current next next)

      assert detailed(view, "run-details-progress-read", "data-count") == ["2"]

      assert detailed_counts(view, "run-details-progress-outcome", "data-outcome") == %{
               "created" => 2
             }

      refute has_element?(view, ~s|[data-role="run-details-kind"]|)

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
      settled(view)

      refute has_element?(view, ~s|[data-role="run-details-progress"]|)

      assert has_element?(
               view,
               ~s|[data-role="run-details"][data-status="dry_run"][data-step="dry_run"]|
             )

      assert detailed_counts(view, "run-details-outcome", "data-outcome") == %{"created" => 3}

      assert detailed_counts(view, "run-details-kind", "data-kind", "data-found") == %{
               "redirect" => 3
             }

      assert detailed(view, "run-details-item", "data-source-id") == ~w(3 2 1)
      refute has_element?(view, ~s|[data-role="run-details-items-more"]|)
    end

    test "shows an import that is done as the import's, with what it wrote", %{
      conn: conn,
      site: site,
      admin: admin
    } do
      rows = [redirect_row(1, "/a", "/b"), redirect_row(2, "/c", "/d")]
      run = migrate!(site, admin, %{"redirect" => rows})
      view = open!(conn, admin)
      expand!(view, run)

      assert has_element?(
               view,
               ~s|[data-role="run-details"][data-status="done"][data-step="import"]|
             )

      assert has_element?(view, ~s|[data-role="run-details-moment"]|, "Import finished")
      assert detailed_counts(view, "run-details-outcome", "data-outcome") == %{"created" => 2}
      assert detailed(view, "run-details-item", "data-outcome") == ~w(created created)
    end

    @tag capture_log: true
    test "says in words why a failed run stopped", %{conn: conn, site: site, admin: admin} do
      run = create_run!(site, admin, %{"redirect" => [redirect_row(1, "/a", "/b")]})

      MishkaCmsMigration.Repo.query!(
        ~s(UPDATE mishka_cms_migration_runs SET connection = connection || '{"revoked": true}' WHERE id = $1),
        [Ecto.UUID.dump!(run.id)]
      )

      run = start_dry_run!(run, admin)
      [job] = assert_triggered(run, :run_dry_run)
      assert :ok = perform_job(MishkaCmsMigration.Workers.DryRunWorker, job.args, attempt: 3)

      view = open!(conn, admin)
      expand!(view, run)

      assert has_element?(view, ~s|[data-role="run-details"][data-status="failed"]|)

      assert has_element?(
               view,
               ~s|[data-role="run-details-reason"][data-reason="unauthorized"]|,
               "Fake no longer accepts the user and password this run signed in with."
             )

      assert has_element?(view, ~s|[data-role="run-details-none"]|)
    end

    test "says so when the source listed nothing, and when a run ended before its dry run", %{
      conn: conn,
      site: site,
      admin: admin
    } do
      empty = site |> create_run!(admin, %{}) |> dry_run!(admin)

      cancelled =
        site
        |> create_run!(admin, %{})
        |> MishkaCmsMigration.cancel_run!(actor: admin, tenant: site.id)

      view = open!(conn, admin)

      expand!(view, empty)
      assert has_element?(view, ~s|[data-role="run-details-total"][data-count="0"]|)

      assert has_element?(
               view,
               ~s|[data-role="run-details-none"]|,
               "The source listed nothing to move."
             )

      refute has_element?(view, ~s|[data-role="run-details-kind"]|)

      expand!(view, cancelled)
      assert has_element?(view, ~s|[data-role="run-details"][data-status="cancelled"]|)
      assert has_element?(view, ~s|[data-role="run-details-none"]|, "ended before a dry run")
      refute has_element?(view, ~s|[data-role="run-details-total"]|)
    end

    test "links the source's address only when it is a web address", %{
      conn: conn,
      site: site,
      admin: admin
    } do
      facts = fn home ->
        %{connection: %{"items" => %{}, "facts" => %{"name" => "Old blog", "home" => home}}}
      end

      script = create_run!(site, admin, %{}, facts.("javascript:alert(1)"))
      web = create_run!(site, admin, %{}, facts.("https://old.example.com/"))
      view = open!(conn, admin)

      expand!(view, script)
      assert has_element?(view, ~s|[data-fact="name"]|, "Old blog")
      assert has_element?(view, ~s|[data-fact="home"]|, "old.example.com")
      refute has_element?(view, ~s|[data-fact="home"] a|)

      expand!(view, web)
      assert has_element?(view, ~s|[data-fact="home"] a[href="https://old.example.com/"]|)
    end
  end

  describe "a run's row actions" do
    setup %{site: site} do
      for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)
      {:ok, admin: migration_admin!(site)}
    end

    test "offer only the steps the run's status allows, and ask before a Cancel", %{
      conn: conn,
      site: site,
      admin: admin
    } do
      pending = create_run!(site, admin, %{})
      ready = site |> create_run!(admin, %{}) |> dry_run!(admin)
      done = migrate!(site, admin, %{})

      cancelled =
        site
        |> create_run!(admin, %{})
        |> MishkaCmsMigration.cancel_run!(actor: admin, tenant: site.id)

      running =
        site
        |> create_run!(admin, %{})
        |> MishkaCmsMigration.start_dry_run!(actor: admin, tenant: site.id)

      view = open!(conn, admin)

      assert has_element?(view, ~s|#{action("dry_run", pending)}[title="Dry run"]|)
      assert has_element?(view, ~s|#{action("dry_run", ready)}[title="Run again"]|)
      assert has_element?(view, ~s|#{action("import", ready)}[title="Import"][data-confirm]|)

      for run <- [running, done, cancelled],
          do: refute(has_element?(view, action("dry_run", run)))

      for run <- [pending, running, done, cancelled],
          do: refute(has_element?(view, action("import", run)))

      for run <- [pending, ready, running],
          do: assert(has_element?(view, "#{action("cancel", run)}[data-confirm]"))

      for run <- [done, cancelled], do: refute(has_element?(view, action("cancel", run)))
    end

    test "Run again, clicked the moment a dry run finishes live, starts the next dry run", %{
      conn: conn,
      site: site,
      admin: admin
    } do
      run = create_run!(site, admin, %{"redirect" => [redirect_row(1, "/a", "/b")]})
      view = open!(conn, admin)
      expand!(view, run)

      assert row_action!(view, "dry_run", run) =~ "Dry run started."
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
      settled(view)
      assert has_element?(view, action("dry_run", run), "Run again")

      assert row_action!(view, "dry_run", run) =~ "Dry run started."
      assert status(run) == :dry_running
      assert [_job] = assert_triggered(run, :run_dry_run)
      assert has_element?(view, ~s|[data-role="run-status"][data-status="dry_running"]|)
    end

    test "a second dry run while one of the site's runs is running is refused in words, and Cancel frees the site",
         %{conn: conn, site: site, admin: admin} do
      first =
        site
        |> create_run!(admin, %{}, %{source_host: "first.example.com"})
        |> MishkaCmsMigration.start_dry_run!(actor: admin, tenant: site.id)

      second = create_run!(site, admin, %{}, %{source_host: "second.example.com"})
      view = open!(conn, admin)

      assert row_action!(view, "dry_run", second) =~
               "Another migration of this site is still waiting or running."

      assert status(second) == :pending

      assert row_action!(view, "cancel", first) =~ "Run cancelled."
      assert status(first) == :cancelled
      refute has_element?(view, action("cancel", first))

      assert row_action!(view, "dry_run", second) =~ "Dry run started."
      assert status(second) == :dry_running
    end

    test "a master starts and cancels a run of any site", %{conn: conn} do
      other = create_site!()
      run = create_run!(other, migration_admin!(other), %{})
      view = open!(conn, create_user_with_permissions!(["admin:dashboard:migration"]))

      assert row_action!(view, "dry_run", run) =~ "Dry run started."
      assert status(run) == :dry_running

      assert row_action!(view, "cancel", run) =~ "Run cancelled."
      assert status(run) == :cancelled
    end

    test "a master imports a run of any site", %{conn: conn} do
      other = create_site!()

      run =
        other |> create_run!(migration_admin!(other), %{}) |> dry_run!(migration_admin!(other))

      view = open!(conn, create_user_with_permissions!(["admin:dashboard:migration"]))

      assert row_action!(view, "import", run) =~ "Import started."
      assert status(run) == :importing
      assert [_job] = assert_triggered(run, :run_import)
    end

    test "a site admin cannot start, import or cancel another site's run by a crafted event", %{
      conn: conn,
      admin: admin
    } do
      other = create_site!()
      other_admin = migration_admin!(other)
      theirs = create_run!(other, other_admin, %{})
      their_ready = other |> create_run!(other_admin, %{}) |> dry_run!(other_admin)
      view = open!(conn, admin)

      assert crafted!(view, "dry_run", theirs.id) =~ "This record is no longer here."
      assert crafted!(view, "cancel", theirs.id) =~ "This record is no longer here."
      assert crafted!(view, "import", their_ready.id) =~ "This record is no longer here."
      assert status(theirs) == :pending
      assert status(their_ready) == :dry_run
    end

    test "an Import of a run whose dry run is not ready is refused in words", %{
      conn: conn,
      site: site,
      admin: admin
    } do
      pending = create_run!(site, admin, %{})
      view = open!(conn, admin)

      assert crafted!(view, "import", pending.id) =~ "The run cannot do that while it is pending."
      assert status(pending) == :pending
    end
  end

  describe "the runs table's columns" do
    setup do
      for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)
      :ok
    end

    # The domain's Tailwind adapter draws a row action as a 30px button, 4px from the next, in a
    # cell with 16px of padding either side.
    defp actions_width(0), do: 32
    defp actions_width(buttons), do: buttons * 30 + (buttons - 1) * 4 + 32

    defp px_min(track),
      do: ~r/^(?:minmax\()?(\d+)px/ |> Regex.run(track) |> List.last() |> String.to_integer()

    # A run in each of the seven statuses, the importing one `other`'s, since a site runs one dry
    # run or import at a time. The jobs that finish runs are drained before any is left queued.
    defp run_in_every_status!(site, other) do
      admin = migration_admin!(site)
      other_admin = migration_admin!(other)
      ready = site |> create_run!(admin, %{}) |> dry_run!(admin)
      done = migrate!(site, admin, %{})
      other_ready = other |> create_run!(other_admin, %{}) |> dry_run!(other_admin)

      failed =
        site
        |> create_run!(admin, %{})
        |> MishkaCmsMigration.start_dry_run!(actor: admin, tenant: site.id)
        |> MishkaCmsMigration.fail_run!("stop", tenant: site.id, authorize?: false)

      [
        ready,
        done,
        failed,
        create_run!(site, admin, %{}),
        site
        |> create_run!(admin, %{})
        |> MishkaCmsMigration.cancel_run!(actor: admin, tenant: site.id),
        site
        |> create_run!(admin, %{})
        |> MishkaCmsMigration.start_dry_run!(actor: admin, tenant: site.id),
        MishkaCmsMigration.start_import!(other_ready, actor: other_admin, tenant: other.id)
      ]
    end

    test "keep their widths whatever each row's status, so a row moving on moves none of them", %{
      conn: conn,
      site: site
    } do
      runs = run_in_every_status!(site, create_site!())

      assert runs |> Enum.map(&status/1) |> Enum.sort() ==
               Enum.sort(MigrationRun.status_options() |> Enum.map(&elem(&1, 1)))

      html =
        conn
        |> open!(create_user_with_permissions!(["admin:dashboard:migration"]))
        |> render()
        |> LazyHTML.from_fragment()

      [style] =
        html
        |> LazyHTML.query(~s|#migration-runs-table [id$="-grid"]|)
        |> LazyHTML.attribute("style")

      [_, template] = Regex.run(~r/grid-template-columns: ([^;]+);/, style)
      tracks = String.split(template)

      for track <- tracks do
        assert track =~ ~r/^(\d+px|minmax\(\d+px,[^)]+\))$/,
               "#{track} has no fixed width, so its cells size it"
      end

      buttons =
        for run <- runs do
          html
          |> LazyHTML.query(
            ~s|#migration-runs-table [id$="-#{run.id}"] [data-role="gervaz-row-actions"] button|
          )
          |> Enum.count()
        end

      assert actions_width(Enum.max(buttons)) <= tracks |> List.last() |> px_min()
    end
  end

  describe "the sidebar" do
    test "has one entry, in Plugins, gated by the migration permission" do
      assert [item] = SidebarMenu.items()
      assert {item.key, item.path, item.group} == {"migration", @page, "plugins"}
      assert SidebarMenu.permissions("migration") == ["admin:dashboard:migration"]
      assert Enum.any?(MishkaCmsCore.Sidebar.collect().items, &(&1.key == "migration"))
      assert MishkaCmsCore.Sidebar.permissions_for_module(Index) == ["admin:dashboard:migration"]
    end
  end
end
