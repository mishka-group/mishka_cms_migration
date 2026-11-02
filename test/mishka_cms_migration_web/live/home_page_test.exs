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
  alias MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.Index
  alias MishkaCmsMigrationWeb.SidebarMenu

  @page "/admin/dashboard/migration"

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

  defp new_import!(view) do
    view
    |> element(~s|[data-source="wordpress"] [data-role="migration-new-run"]|)
    |> render_click()
  end

  defp submit!(view, connection, secret) do
    view
    |> form(~s|#migration-run-form-modal form|, %{
      "form" => %{"connection" => connection, "secret" => secret}
    })
    |> render_submit()
  end

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

  defp outcomes(view) do
    pills =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s|[data-role="run-result"] [data-role="run-outcome"]|)

    pills
    |> LazyHTML.attribute("data-outcome")
    |> Enum.zip(pills |> LazyHTML.attribute("data-count") |> Enum.map(&String.to_integer/1))
    |> Map.new()
  end

  defp status(run),
    do: MishkaCmsMigration.get_run!(run.id, tenant: run.site_id, authorize?: false).status

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

      assert MigrationRun.open_secret(run) == {:ok, "app password"}
      assert settled(view) =~ "Connected to Mishka Test Blog."
      assert has_element?(view, ~s|[data-role="run-source"]|, "WordPress")
      assert has_element?(view, "#migration-runs-table", "Mishka Test Blog")
      assert has_element?(view, ~s|[data-role="run-status"][data-status="pending"]|)
    end

    test "keeps the form open with the reason, and saves nothing, when WordPress refuses", %{
      conn: conn,
      site: site
    } do
      stub!(%{"/wp-json/wp/v2/users/me" => "unauthorized-users-me-wrong-password"})
      admin = migration_admin!(site)
      view = open!(conn, admin)

      new_import!(view)
      html = submit!(view, %{"url" => "http://localhost:8089", "user" => "admin"}, "wrong")

      assert html =~ "WordPress did not accept this user and application password"
      assert Ash.read!(MigrationRun, actor: admin, tenant: site.id) == []
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
      assert has_element?(view, ~s|[data-role="run-result"][title*="1 created"]|)
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
      assert has_element?(view, ~s|[data-role="run-report-note"]|, "No dry run yet.")
      assert outcomes(view) == %{}

      assert row_action!(view, "dry_run", run) =~ "Dry run started."
      assert [_job] = assert_triggered(run, :run_dry_run)
      assert has_element?(view, ~s|[data-role="run-status"][data-status="dry_running"]|)
      refute has_element?(view, "#migration-runs-table #{action("dry_run", run)}")

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
      settled(view)

      assert has_element?(
               view,
               ~s|[data-role="run-status"][data-status="dry_run"]|,
               "Dry run ready"
             )

      assert outcomes(view) == %{"skipped" => 57}
      assert has_element?(view, "#migration-runs-table #{action("dry_run", run)}", "Run again")

      for {kind, label, found} <- [
            {"user", "Users", 5},
            {"category", "Categories", 9},
            {"tag", "Tags", 11},
            {"page", "Pages", 11},
            {"post", "Posts", 21}
          ] do
        row = ~s|[data-role="run-report-kind"][data-kind="#{kind}"]|

        assert has_element?(view, row, label)
        assert has_element?(view, ~s|#{row} [data-role="run-report-found"]|, "#{found} found")

        assert has_element?(
                 view,
                 ~s|#{row} [data-role="run-report-outcomes"]|,
                 "#{found} skipped"
               )

        assert has_element?(
                 view,
                 ~s|#{row} [data-role="run-report-reason"]|,
                 "Nothing imports these yet"
               )
      end

      refute has_element?(view, ~s|[data-role="run-report-note"]|)
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

      for run <- [running, done, cancelled],
          do: refute(has_element?(view, action("dry_run", run)))

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

    test "a site admin cannot start or cancel another site's run by a crafted event", %{
      conn: conn,
      admin: admin
    } do
      other = create_site!()
      theirs = create_run!(other, migration_admin!(other), %{})
      view = open!(conn, admin)

      assert crafted!(view, "dry_run", theirs.id) =~ "This record is no longer here."
      assert crafted!(view, "cancel", theirs.id) =~ "This record is no longer here."
      assert status(theirs) == :pending
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
