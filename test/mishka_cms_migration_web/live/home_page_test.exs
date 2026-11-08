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
  import MishkaCmsMigration.DataCase, only: [register_plugin!: 2, without_blog!: 0]
  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0, stub!: 1]

  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsMigration.{MigrationRun, Report}
  alias MishkaCmsMigration.Test.Plugins.TokenSource
  alias MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.{Index, RunDetails}
  alias MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item
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
  # connection's password key, then Next through the steps and Start the dry run (`finish!/2`).
  defp submit!(view, connection, secret),
    do: finish!(view, %{"connection" => Map.put(connection, "secret", secret)})

  # Fills the New import window with `params`, presses Next (the form's submit, as Enter in a field
  # does) on each step and Start the dry run on the review. Each press sends `params` again, as a
  # browser sends every input of the form, the password the server never draws back included. A
  # step that refuses is where it stops. Returns the page as the last press left it.
  defp finish!(view, params), do: view |> press!(params) |> walked(view, params, "from")

  defp press!(view, params),
    do: view |> form(~s|#migration-run-form-modal form|, %{"form" => params}) |> render_submit()

  defp walked(html, view, params, left) do
    case shown_step(view) do
      ^left -> html
      "review" -> press!(view, params)
      step -> view |> press!(params) |> walked(view, params, step)
    end
  end

  # The step of the New import window that shows: the one `data-step` of its form not hidden.
  defp shown_step(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s|#migration-run-form-modal form [data-step]:not([hidden])|)
    |> LazyHTML.attribute("data-step")
    |> List.first()
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

  defp decided(view),
    do: view |> parts(@result, "run-decided") |> LazyHTML.attribute("data-count")

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

    test "keep New import on one line beside a long source name", %{conn: conn, site: site} do
      view = open!(conn, migration_admin!(site))
      button = ~s|[data-source="wordpress_file"] [data-role="migration-new-run"]|

      assert has_element?(view, button <> ".whitespace-nowrap.shrink-0")

      assert has_element?(
               view,
               ~s|[data-source="wordpress_file"] .flex-wrap > [data-role="migration-source-name"].whitespace-nowrap|
             )
    end

    test "show WordPress and its export file, each with its own New import", %{
      conn: conn,
      site: site
    } do
      view = open!(conn, migration_admin!(site))

      assert has_element?(view, ~s|[data-source="wordpress"] [data-role="migration-new-run"]|)

      assert has_element?(
               view,
               ~s|[data-source="wordpress_file"] [data-role="migration-new-run"]|
             )

      assert has_element?(view, ~s|[data-source="wordpress_file"]|, "WordPress export file")
    end

    test "say so when no source is installed", %{conn: conn, site: site} do
      for source <- MishkaCmsMigration.Application.sources() do
        {:ok, _stopped} = MishkaInstaller.Event.Event.stop(:name, source, false)
        on_exit(fn -> {:ok, _enabled} = MishkaInstaller.Event.Event.enable(source, false) end)
      end

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

      assert {run.source, run.source_host, run.extra["name"]} ==
               {"wordpress", "localhost:8089", "Mishka Test Blog"}

      assert status(run) == :dry_running

      assert stored(run).connection == %{"url" => "http://localhost:8089", "user" => "admin"}
      assert MigrationRun.open_secret(run) == {:ok, "app password"}
      assert settled(view) =~ "Connected to Mishka Test Blog. The dry run started"
      assert has_element?(view, ~s|[data-role="run-source"]|, "WordPress")
      assert has_element?(view, "#migration-runs-table", "Mishka Test Blog")
      assert has_element?(view, ~s|[data-role="run-status"][data-status="dry_running"]|)
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

    test "sent empty, says in words what each connection key needs and saves nothing", %{
      conn: conn,
      site: site
    } do
      admin = migration_admin!(site)
      view = open!(conn, admin)

      new_import!(view)
      html = submit!(view, %{"url" => "", "user" => ""}, "")

      assert html =~ "Enter the address."
      assert html =~ "Enter the application password."
      refute html =~ "must be present"
      assert Ash.read!(MigrationRun, actor: admin, tenant: site.id) == []
    end

    test "sent empty by a master, asks for the site once", %{conn: conn} do
      master = create_user_with_permissions!(["admin:dashboard:migration"])
      view = open!(conn, master)

      new_import!(view)
      html = submit!(view, %{"url" => "", "user" => ""}, "")

      assert length(String.split(html, "Pick a site.")) == 2
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
               "post_address" =>
                 {defaults.post_address, ["keep", "blog", "blog_without_redirects"]},
               "posts_page" => {defaults.posts_page, ["source", "front", "blog"]}
             }

      for label <- [
            "Choices for this run",
            "Authors",
            "Pages",
            "Post addresses",
            "Posts list page"
          ],
          do: assert(has_element?(view, "#migration-run-form-modal label", label))

      comments = ~s|#migration-run-form-modal input[name="form[bring][comments]"]|
      assert has_element?(view, comments)
      refute has_element?(view, comments <> "[checked]")
      assert has_element?(view, "#migration-run-form-modal", "Comments")

      confirm = ~s|#migration-run-form-modal input[name="form[options][confirm_users]"]|
      assert has_element?(view, confirm <> "[checked]")
      assert has_element?(view, "#migration-run-form-modal", "Confirm imported users' email")

      assert has_element?(
               view,
               "#migration-run-form-modal",
               "every old address the site does not serve as it was is sent on with a 301 redirect"
             )

      assert has_element?(view, "#migration-run-form-modal", "off by default")

      assert has_element?(
               view,
               "#migration-run-form-modal",
               "counts as having confirmed their email"
             )

      assert has_element?(view, "#migration-run-form-modal", "the name and email the guest gave")
      refute has_element?(view, "#migration-run-form-modal", "a guest's is left out")
    end

    test "asks for the pages alone on a node without the Blog", %{conn: conn, site: site} do
      without_blog!()
      view = open!(conn, migration_admin!(site))
      new_import!(view)

      assert Map.keys(choices(view)) == ["pages"]

      refute has_element?(
               view,
               ~s|#migration-run-form-modal input[name="form[options][comments]"]|
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

      finish!(
        view,
        %{
          "connection" => %{
            "url" => "http://localhost:8089",
            "user" => "admin",
            "secret" => "app password"
          },
          "options" => %{"authors" => "create", "post_address" => "blog_without_redirects"}
        }
      )

      assert [run] = Ash.read!(MigrationRun, actor: admin, tenant: site.id)

      assert stored(run).options == %{
               "authors" => "create",
               "pages" => "draft",
               "post_address" => "blog_without_redirects",
               "posts_page" => "source",
               "confirm_users" => true,
               "comments" => false,
               "bring_users" => true,
               "bring_terms" => true,
               "bring_media" => true,
               "bring_pages" => true,
               "bring_posts" => true,
               "bring_menus" => true,
               "site_title" => true,
               "site_logo" => true,
               "site_icon" => true,
               "one_language" => nil
             }
    end

    test "saves the confirm users choice when it is switched off", %{conn: conn, site: site} do
      stub!()
      admin = migration_admin!(site)
      view = open!(conn, admin)
      new_import!(view)

      finish!(
        view,
        %{
          "connection" => %{
            "url" => "http://localhost:8089",
            "user" => "admin",
            "secret" => "app password"
          },
          "options" => %{"confirm_users" => "false"}
        }
      )

      assert [run] = Ash.read!(MigrationRun, actor: admin, tenant: site.id)
      assert %{"confirm_users" => false} = stored(run).options
    end

    test "saves the comments choice when it is switched on", %{conn: conn, site: site} do
      stub!()
      admin = migration_admin!(site)
      view = open!(conn, admin)
      new_import!(view)

      finish!(
        view,
        %{
          "connection" => %{
            "url" => "http://localhost:8089",
            "user" => "admin",
            "secret" => "app password"
          },
          "bring" => %{"comments" => "true"}
        }
      )

      assert [run] = Ash.read!(MigrationRun, actor: admin, tenant: site.id)
      assert %{"comments" => true, "authors" => "connect"} = stored(run).options
    end
  end

  describe "the New import steps" do
    @modal "#migration-run-form-modal"
    @connection %{"url" => "http://localhost:8089", "user" => "admin", "secret" => "app password"}
    @refused %{"/wp-json/wp/v2/users/me" => "unauthorized-users-me-wrong-password"}

    setup do
      for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)
      Req.Test.set_req_test_to_shared()
      on_exit(&Req.Test.set_req_test_to_private/0)
      stub!()
      :ok
    end

    defp review(view) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s|#{@modal} [data-role="import-review"]|)
      |> LazyHTML.text()
    end

    defp typed!(view, params) do
      view
      |> form("#{@modal} form", %{"form" => params})
      |> render_change(%{"_target" => ["form", "bring", "bring_posts"]})
    end

    # Presses Next, as Enter in a field does: the form's submit, sending the connection typed on
    # Where from, as a browser sends every input of the form.
    defp next!(view, params \\ %{"connection" => @connection}),
      do: view |> form("#{@modal} form", %{"form" => params}) |> render_submit()

    test "are a wizard: one step shown at a time, Next or Enter moves on, and only the review starts the run",
         %{conn: conn, site: site} do
      admin = migration_admin!(site)
      view = open!(conn, admin)
      new_import!(view)

      assert shown_step(view) == "from"

      for label <- ["Where from", "What to bring", "Languages", "Review"],
          do: assert(has_element?(view, "#{@modal} nav li", label))

      for {step, heading} <- [
            {"from", "1 of 4: Where from"},
            {"bring", "2 of 4: What to bring"},
            {"language", "3 of 4: Languages"}
          ],
          do: assert(has_element?(view, ~s|#{@modal} [data-step="#{step}"] legend|, heading))

      refute has_element?(view, ~s|#{@modal} [data-role="gervaz-step-back"]|)
      refute has_element?(view, "#{@modal} button[type=submit]", "Start the dry run")

      next!(view, %{"connection" => @connection})
      assert shown_step(view) == "bring"
      assert Ash.read!(MigrationRun, actor: admin, tenant: site.id) == []

      next!(view)
      assert shown_step(view) == "language"
      next!(view)
      assert shown_step(view) == "review"

      assert has_element?(view, ~s|#{@modal} [data-role="import-review"] h3|, "4 of 4: Review")

      assert has_element?(
               view,
               ~s|#{@modal} button[type="submit"][phx-disable-with="Checking the source…"]|,
               "Start the dry run"
             )

      view |> element(~s|#{@modal} [data-role="gervaz-step-back"]|) |> render_click()
      assert shown_step(view) == "language"
      assert Ash.read!(MigrationRun, actor: admin, tenant: site.id) == []
    end

    test "Next on Where from asks for a blank password in words, before it tries the connection",
         %{conn: conn, site: site} do
      view = open!(conn, migration_admin!(site))
      new_import!(view)

      html = next!(view, %{"connection" => %{@connection | "secret" => ""}})

      assert shown_step(view) == "from"
      assert html =~ "Enter the application password."
      refute html =~ "did not accept"
      refute_received {:wordpress_request, _conn}
      assert has_element?(view, ~s|#{@modal} nav [data-step="from"][data-status="error"]|)
    end

    test "Next on Where from tries the connection, and stays with the reason the source refuses it for",
         %{conn: conn, site: site} do
      stub!(@refused)
      view = open!(conn, migration_admin!(site))
      new_import!(view)

      html = next!(view, %{"connection" => @connection})

      assert shown_step(view) == "from"
      assert html =~ "WordPress did not accept this user and application password"
      refute html =~ "app password"
    end

    test "a connection refused by Start the dry run returns to Where from with the reason and a flash naming the step",
         %{conn: conn, site: site} do
      admin = migration_admin!(site)
      view = open!(conn, admin)
      new_import!(view)

      next!(view, %{"connection" => @connection})
      next!(view)
      next!(view)
      assert shown_step(view) == "review"

      stub!(@refused)
      next!(view)
      html = settled(view)

      assert shown_step(view) == "from"
      assert html =~ "WordPress did not accept this user and application password"
      assert html =~ "Check it on step 1, Where from."
      assert has_element?(view, ~s|#{@modal} nav [data-step="from"][data-status="error"]|)
      assert Ash.read!(MigrationRun, actor: admin, tenant: site.id) == []
    end

    test "keep the answers when the window is opened again, until Start over", %{
      conn: conn,
      site: site
    } do
      view = open!(conn, migration_admin!(site))
      new_import!(view)
      next!(view, %{"connection" => @connection})

      new_import!(view)

      assert shown_step(view) == "bring"
      url = ~s|#{@modal} input[name="form[connection][url]"]|
      assert has_element?(view, url <> ~s|[value="http://localhost:8089"]|)

      view |> element(~s|#{@modal} [data-role="import-start-over"]|) |> render_click()
      settled(view)

      assert shown_step(view) == "from"
      refute has_element?(view, url <> ~s|[value="http://localhost:8089"]|)
    end

    test "ask for the kinds as switches that are on, comments off, and the languages of the site with the source's kept",
         %{conn: conn, site: site} do
      view = open!(conn, migration_admin!(site))
      new_import!(view)

      for name <- ~w(bring_posts bring_pages bring_media bring_terms bring_users bring_menus) do
        assert has_element?(
                 view,
                 ~s|#{@modal} input[type="checkbox"][name="form[bring][#{name}]"][checked]|
               )
      end

      assert has_element?(
               view,
               ~s|#{@modal} input[type="checkbox"][name="form[bring][comments]"]|
             )

      refute has_element?(view, ~s|#{@modal} input[name="form[bring][comments]"][checked]|)

      language = ~s|#{@modal} [data-step="language"] select[name="form[language]"]|
      assert has_element?(view, language <> " option", "Keep the source's languages")
      assert has_element?(view, language <> ~s| option[value="en"]|, "English")
    end

    test "review what the run will do in plain words, as the answers change", %{
      conn: conn,
      site: site
    } do
      view = open!(conn, migration_admin!(site))
      new_import!(view)

      assert review(view) =~ "4 of 4: Review"
      assert review(view) =~ "Bringing: Posts, Pages"
      assert review(view) =~ "Not bringing: Comments."
      assert review(view) =~ "kept as the source gives them"
      assert review(view) =~ "a test run that changes nothing on your site"
      refute review(view) =~ "Authors:"

      typed!(view, %{
        "bring" => %{"bring_posts" => "false"},
        "language" => "en",
        "options" => %{
          "site_icon" => "false",
          "authors" => "create",
          "confirm_users" => "false"
        }
      })

      assert review(view) =~ "Not bringing: Posts, Comments."
      assert review(view) =~ "Left out of the site's own settings: Site icon (favicon)."
      assert review(view) =~ "Authors: Match by email, create the rest."
      assert review(view) =~ "Confirm imported users' email: off."
      refute review(view) =~ "Pages: Drafts"
      assert review(view) =~ "in English"
    end

    test "keep the advanced options in a closed group of the review, and need none of them",
         %{conn: conn, site: site} do
      admin = migration_admin!(site)
      view = open!(conn, admin)
      new_import!(view)

      advanced = ~s|#{@modal} [data-step="review"] [data-group="options"] details|
      assert has_element?(view, advanced <> " summary", "Advanced options")
      refute has_element?(view, advanced <> "[open]")

      for label <- ["Authors", "Pages", "Post addresses", "Site title", "Site logo", "Site icon"],
          do: assert(has_element?(view, advanced, label))

      submit!(view, %{"url" => "http://localhost:8089", "user" => "admin"}, "app password")

      assert [run] = Ash.read!(MigrationRun, actor: admin, tenant: site.id)
      assert {:ok, defaults} = MigrationRun.Options.builder(%{})
      assert {:ok, saved} = MigrationRun.Options.builder(stored(run).options)
      assert saved == defaults
    end

    test "save the switches, the language and the advanced answers into the run's options, and start its dry run",
         %{conn: conn, site: site} do
      admin = migration_admin!(site)
      view = open!(conn, admin)
      new_import!(view)

      finish!(
        view,
        %{
          "connection" => %{"url" => "http://localhost:8089", "user" => "admin", "secret" => "pw"},
          "bring" => %{"bring_pages" => "false", "comments" => "true"},
          "language" => "en",
          "options" => %{"site_icon" => "false", "authors" => "create"}
        }
      )

      assert [run] = Ash.read!(MigrationRun, actor: admin, tenant: site.id)

      assert %{
               "bring_pages" => false,
               "bring_posts" => true,
               "comments" => true,
               "one_language" => "en",
               "site_icon" => false,
               "site_logo" => true,
               "authors" => "create"
             } = stored(run).options

      assert settled(view) =~ "The dry run started"
      assert status(run) == :dry_running
    end

    test "keep the run Connected and say why when the site is busy with another run", %{
      conn: conn,
      site: site
    } do
      admin = migration_admin!(site)
      busy = create_run!(site, admin, %{})
      MishkaCmsMigration.start_dry_run!(busy, actor: admin, tenant: site.id)

      view = open!(conn, admin)
      new_import!(view)
      submit!(view, %{"url" => "http://localhost:8089", "user" => "admin"}, "app password")

      assert [run] =
               MigrationRun
               |> Ash.read!(actor: admin, tenant: site.id)
               |> Enum.filter(&(&1.source == "wordpress"))

      assert settled(view) =~ "but the dry run did not start"
      assert status(run) == :pending
    end

    test "refuse a language that is not one of the site's, under the language", %{site: site} do
      admin = migration_admin!(site)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               MishkaCmsMigration.create_run(
                 %{
                   source: "fake",
                   source_host: "old.example.com",
                   language: "de"
                 },
                 actor: admin,
                 tenant: site.id
               )

      assert [%{field: :language}] = errors
      assert Ash.read!(MigrationRun, actor: admin, tenant: site.id) == []
    end
  end

  describe "the New import's Site" do
    @modal "#migration-run-form-modal"
    @search ~s|#migration-run-form-modal input[name="_search_site_id"]|
    @connection %{"url" => "http://localhost:8089", "user" => "admin", "secret" => "app password"}

    setup do
      for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)
      Req.Test.set_req_test_to_shared()
      on_exit(&Req.Test.set_req_test_to_private/0)
      stub!()

      master = create_user_with_permissions!(["admin:dashboard:migration"])
      site_a = create_site!(name: "site-a", host: "a.test")
      site_b = create_site!(name: "site-b", host: "b.test")
      %{master: master, site_a: site_a, site_b: site_b}
    end

    defp sites_listed(view) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s|#{@modal} [role="option"]|)
      |> LazyHTML.attribute("phx-value-label")
      |> Enum.sort()
    end

    # What the browser sends when text enters the Site search box, typed or pasted: the form's
    # change, aimed at the box, carrying every input of the form.
    defp searched!(view, text, form \\ %{}) do
      view
      |> form("#{@modal} form", %{"_search_site_id" => text, "form" => form})
      |> render_change(%{"_target" => ["_search_site_id"]})
    end

    test "narrows the list to the sites the text names, typed or pasted", %{
      conn: conn,
      master: master
    } do
      view = open!(conn, master)
      new_import!(view)
      view |> element(@search) |> render_focus()

      assert sites_listed(view) == ["localhost", "site-a", "site-b"]

      searched!(view, "localhost")
      assert sites_listed(view) == ["localhost"]

      searched!(view, "site")
      assert sites_listed(view) == ["site-a", "site-b"]
    end

    test "keeps the window open when the page sends Languages in another shape", %{
      conn: conn,
      master: master
    } do
      view = open!(conn, master)
      new_import!(view)

      view
      |> element("#{@modal} form")
      |> render_change(%{
        "_search_site_id" => "loc",
        "_target" => ["_search_site_id"],
        "form" => %{"language" => %{"one_language" => "", "_unused_one_language" => ""}}
      })

      assert shown_step(view) == "from"
      assert has_element?(view, @search)
    end

    test "Next with nothing filled shows a master every refusal of the step at once", %{
      conn: conn,
      master: master
    } do
      view = open!(conn, master)
      new_import!(view)

      html = next!(view, %{"connection" => %{"url" => "", "user" => "", "secret" => ""}})

      assert shown_step(view) == "from"

      for refusal <- [
            "Pick a site.",
            "Enter the address.",
            "Enter the user.",
            "Enter the application password."
          ],
          do: assert(html =~ refusal)

      refute_received {:wordpress_request, _conn}
    end

    test "a site picked with the mouse after a search stays picked, and the run goes to it", %{
      conn: conn,
      master: master,
      site_b: site_b
    } do
      view = open!(conn, master)
      new_import!(view)
      view |> element(@search) |> render_focus()
      searched!(view, "site-b")

      view |> element(~s|#{@modal} [role="option"][phx-value-label="site-b"]|) |> render_click()
      searched!(view, "site-b", %{"connection" => @connection})

      assert has_element?(view, ~s|#{@modal} input[name="site_id"][value="#{site_b.id}"]|)
      refute render(view) =~ "Pick a site."

      finish!(view, %{"connection" => @connection})

      assert [run] = Ash.read!(MigrationRun, tenant: site_b.id, authorize?: false)
      assert run.site_id == site_b.id
    end

    test "is never shown to a site admin, whose run goes to their own site even when a site is sent",
         %{conn: conn, site: site, site_b: site_b} do
      admin = migration_admin!(site)
      view = open!(conn, admin)
      new_import!(view)

      refute has_element?(view, @search)
      refute has_element?(view, ~s|#{@modal} [name*="site_id"]|)

      view
      |> form("#{@modal} form", %{"form" => %{"connection" => @connection}})
      |> render_submit(%{"site_id" => site_b.id, "form" => %{"site_id" => site_b.id}})

      finish!(view, %{"connection" => @connection})

      assert [run] = Ash.read!(MigrationRun, actor: admin, tenant: site.id)
      assert run.site_id == site.id
      assert Ash.read!(MigrationRun, tenant: site_b.id, authorize?: false) == []
    end
  end

  describe "the WordPress export file's New import" do
    @describetag :tmp_dir

    defp export_input(view, content) do
      upload =
        MishkaGervaz.Form.Web.UploadHelpers.namespaced_upload_name(
          :file,
          MishkaGervaz.Resource.Info.Form.component_id(MigrationRun)
        )

      file_input(view, "#migration-run-form-modal form", upload, [
        %{name: "mishka.WordPress.2026-11-02.xml", content: content, type: "text/xml"}
      ])
    end

    defp send_export!(view, content) do
      view |> export_input(content) |> render_upload("mishka.WordPress.2026-11-02.xml")
      finish!(view, %{})
    end

    test "asks for the export file and no connection, and WordPress's asks for no file", %{
      conn: conn,
      site: site
    } do
      view = open!(conn, migration_admin!(site))

      new_import!(view, "wordpress_file")

      assert has_element?(view, ~s|#migration-run-form-modal input[type="file"][accept=".xml"]|)
      assert has_element?(view, "#migration-run-form-modal label", "Export file")
      assert connection_inputs(view) == []
      refute has_element?(view, "#migration-run-form-modal label", "Connection")

      new_import!(view)
      refute has_element?(view, ~s|#migration-run-form-modal input[type="file"]|)
      assert connection_inputs(view) == @wordpress_inputs
    end

    test "reads the uploaded export, keeps it for the run, and its dry run reads it; cancelled, the file is gone",
         %{conn: conn, site: site} do
      export = File.read!(Path.expand("../../fixtures/wordpress/wxr/all-content.xml", __DIR__))
      admin = migration_admin!(site)
      view = open!(conn, admin)

      new_import!(view, "wordpress_file")
      send_export!(view, export)

      assert [run] = Ash.read!(MigrationRun, actor: admin, tenant: site.id)
      kept = stored(run).connection["file"]
      on_exit(fn -> File.rm(kept) end)

      assert {run.source, run.source_host, run.extra["name"]} ==
               {"wordpress_file", "localhost:8089", "Mishka Test Blog"}

      assert File.read!(kept) == export
      assert settled(view) =~ "Connected to Mishka Test Blog."
      assert has_element?(view, ~s|[data-role="run-source"]|, "WordPress export file")

      assert status(run) == :dry_running
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
      settled(view)

      assert Map.take(kinds(view), ~w(post page media)) == %{
               "post" => 21,
               "page" => 11,
               "media" => 18
             }

      row_action!(view, "cancel", run)
      assert status(run) == :cancelled
      refute File.exists?(kept)
    end

    test "refuses a file that is not an export, or that declares entities, under the file and saves nothing",
         %{conn: conn, site: site} do
      admin = migration_admin!(site)
      view = open!(conn, admin)

      for content <- [
            "Some notes, not an export.",
            ~s(<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY x SYSTEM "file:///etc/passwd">]>) <>
              "<rss><channel><link>&x;</link></channel></rss>"
          ] do
        new_import!(view, "wordpress_file")
        html = send_export!(view, content)

        assert html =~ "This is not a WordPress export file, or it is damaged."
        refute html =~ "root:"
      end

      assert Ash.read!(MigrationRun, actor: admin, tenant: site.id) == []
    end

    @tag capture_log: true
    test "a run whose export was damaged since says in words why it stopped, and keeps the file until it is cancelled",
         %{conn: conn, site: site} do
      admin = migration_admin!(site)
      staged = Path.join(System.tmp_dir!(), "gervaz_#{System.unique_integer([:positive])}_x.xml")
      File.cp!(Path.expand("../../fixtures/wordpress/wxr/posts-only.xml", __DIR__), staged)
      on_exit(fn -> File.rm(staged) end)

      run =
        MishkaCmsMigration.create_run!(
          %{source: "wordpress_file", file: [%{path: staged, client_name: "export.xml"}]},
          actor: admin,
          tenant: site.id
        )

      File.write!(run.connection["file"], staged |> File.read!() |> binary_part(0, 500))
      run = start_dry_run!(run, admin)
      [job] = assert_triggered(run, :run_dry_run)

      assert {:ok, %{status: :failed}} =
               perform_job(MishkaCmsMigration.Workers.DryRunWorker, job.args, attempt: 3)

      view = open!(conn, admin)
      expand!(view, run)

      assert has_element?(
               view,
               ~s|[data-role="run-details-reason"][data-reason="unreadable_file"]|,
               "The file this run was given is not a WordPress export file, or it is damaged."
             )

      assert File.exists?(run.connection["file"])
      row_action!(view, "cancel", run)
      refute File.exists?(run.connection["file"])
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

    test "adds a new run above the runs it already shows, and follows it, without a reload", %{
      conn: conn,
      site: site
    } do
      admin = migration_admin!(site)

      for n <- 1..3,
          do: create_run!(site, admin, %{}, %{source_host: "old#{n}.example.com"})

      view = open!(conn, admin)
      run = create_run!(site, admin, %{}, %{source_host: "new.example.com"})

      assert settled(view) =~ "new.example.com"
      assert render(view) =~ "old1.example.com"

      dry_run!(run, admin)
      settled(view)

      assert statuses(view) == ["dry_run", "pending", "pending", "pending"]
    end

    # The status of each row the runs table shows, top to bottom.
    defp statuses(view) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s|#migration-runs-table [data-role="run-status"]|)
      |> LazyHTML.attribute("data-status")
    end

    test "shows a master a new run of any site, and its status as it moves on, without a reload",
         %{conn: conn, site: site} do
      master = create_user_with_permissions!(["admin:dashboard:migration"])
      view = open!(conn, master)
      admin = migration_admin!(site)

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
        %{
          kind: kind,
          counts: %{created: created, updated: 0, skipped: 0, failed: 0, undecided: 0}
        },
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

    test "warns in the expanded row when the site gives every language a prefix",
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

      MishkaCmsCore.Settings.put("site.language_urls", "prefix_all",
        site_id: site.id,
        category: "general"
      )

      view = open!(conn, admin)
      expand!(view, run)

      assert has_element?(
               view,
               ~s|#{@details} [data-role="language-urls-warning"][data-cause="prefix_all"]|
             )
    end

    test "says in the expanded row that a cancelled run was cancelled, and not for a run that is not",
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
      refute has_element?(view, ~s|#{@details} [data-role="cancelled-run-notice"]|)

      row_action!(view, "cancel", run)
      expand!(view, run)
      expand!(view, run)

      assert has_element?(
               view,
               ~s|#{@details} [data-role="cancelled-run-notice"]|,
               "This run was cancelled."
             )
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

      assert detailed(view, "run-details-reads", "data-kind") ==
               ~w(user category tag media setting stylesheet page post comment post_redirect menu)

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

      assert outcomes(view) == %{"created" => 258, "skipped" => 80, "undecided" => 5}
      assert has_element?(view, ~s|[data-role="run-outcome"][data-reason="same_address"]|)

      assert kinds(view) == %{
               "user" => 5,
               "category" => 9,
               "tag" => 11,
               "media" => 18,
               "setting" => 4,
               "page" => 11,
               "post" => 21,
               "comment" => 13,
               "post_redirect" => 248,
               "menu" => 3
             }

      assert has_element?(view, "#migration-runs-table #{action("dry_run", run)}", "Run again")

      assert detailed_counts(view, "run-details-kind", "data-kind", "data-found") == %{
               "user" => 5,
               "category" => 9,
               "tag" => 11,
               "media" => 18,
               "setting" => 4,
               "page" => 11,
               "post" => 21,
               "comment" => 13,
               "post_redirect" => 248,
               "menu" => 3
             }

      assert detailed_counts(view, "run-details-outcome", "data-outcome") ==
               %{"created" => 258, "skipped" => 80, "undecided" => 5}

      assert has_element?(
               view,
               ~s|[data-role="run-details-outcome"][data-outcome="undecided"]|,
               "5 need your decision"
             )

      refute has_element?(view, ~s|[data-role="run-details-empty"]|)
    end

    test "the Result chips show what waits for a decision now, and how many were decided, as the admin decides",
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
      assert %{"undecided" => 5} = outcomes(view)
      assert decided(view) == []

      {:ok, groups} = MishkaCmsMigration.MigrationItem.waiting_groups(run, admin)
      [%{conflict: conflict, count: count} = group | _rest] = groups
      choice = hd(MishkaCmsMigration.MigrationItem.choices(conflict))

      assert {:ok, ^count} =
               MishkaCmsMigration.MigrationItem.decide_waiting(run, admin, conflict, choice,
                 kinds: [group.kind]
               )

      settled(view)
      assert outcomes(view)["undecided"] == 5 - count
      assert decided(view) == ["#{count}"]

      for %{conflict: conflict, kind: kind} <- tl(groups) do
        choice = hd(MishkaCmsMigration.MigrationItem.choices(conflict))

        assert {:ok, _count} =
                 MishkaCmsMigration.MigrationItem.decide_waiting(run, admin, conflict, choice,
                   kinds: [kind]
                 )
      end

      settled(view)
      assert outcomes(view)["undecided"] == 0
      assert decided(view) == ["5"]
    end

    test "an expanded run shows what each kind would become and why, its latest items and what the WordPress site said of itself",
         %{conn: conn, site: site} do
      stub!()
      admin = migration_admin!(site)

      run =
        %{
          source: "wordpress",
          connection: %{"url" => "http://localhost:8089", "user" => "admin"},
          secret: "app password",
          options: %{post_address: "blog_without_redirects"}
        }
        |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)
        |> dry_run!(admin)

      view = open!(conn, admin)
      expand!(view, run)

      for {kind, found} <- [{"category", 9}, {"tag", 11}, {"page", 11}] do
        card = ~s|[data-role="run-details-kind"][data-kind="#{kind}"]|

        assert detailed_counts(view, "run-details-segment", "data-outcome", "data-count", card) ==
                 %{"created" => found}

        refute has_element?(view, ~s|#{card} [data-role="run-details-kind-reason"]|)
      end

      post = ~s|[data-role="run-details-kind"][data-kind="post"]|

      assert detailed_counts(view, "run-details-segment", "data-outcome", "data-count", post) ==
               %{"created" => 18, "undecided" => 3}

      assert has_element?(
               view,
               ~s|#{post} [data-role="run-details-kind-reason"][data-outcome="undecided"]|,
               "Sites pages may embed"
             )

      media = ~s|[data-role="run-details-kind"][data-kind="media"]|

      assert detailed_counts(view, "run-details-segment", "data-outcome", "data-count", media) ==
               %{"created" => 17, "skipped" => 1}

      assert has_element?(
               view,
               ~s|#{media} [data-role="run-details-kind-reason"][data-outcome="skipped"]|,
               "Media cannot keep this type of file"
             )

      assert detailed_counts(view, "run-details-kind-reason", "data-outcome", "data-count", media) ==
               %{"skipped" => 1}

      for {kind, found, why} <- [
            {"user", 5, "No user with this email on the site"},
            {"post_redirect", 248, "Left out by this run's choices"}
          ] do
        card = ~s|[data-role="run-details-kind"][data-kind="#{kind}"]|

        assert detailed_counts(view, "run-details-segment", "data-outcome", "data-count", card) ==
                 %{"skipped" => found}

        assert has_element?(
                 view,
                 ~s|#{card} [data-role="run-details-kind-reason"][data-outcome="skipped"]|,
                 why
               )

        assert detailed_counts(
                 view,
                 "run-details-kind-reason",
                 "data-outcome",
                 "data-count",
                 card
               ) ==
                 %{"skipped" => found}
      end

      # The latest items are the menus, then the last addresses the redirect kind lists, WordPress's
      # sitemaps.
      assert ["navigation-105", "23", "22", "archive:/wp-sitemap-users-1.xml" | _rest] =
               detailed(view, "run-details-item", "data-source-id")

      assert detailed(view, "run-details-item", "data-kind") ==
               ["menu", "menu", "menu" | List.duplicate("post_redirect", 5)]

      assert detailed(view, "run-details-item", "data-outcome") ==
               ["undecided", "undecided" | List.duplicate("skipped", 6)]

      assert has_element?(
               view,
               ~s|[data-role="run-details-item"][data-source-id="archive:/wp-sitemap-users-1.xml"] [data-role="run-details-item-reason"]|,
               "Left out by this run's choices"
             )

      assert detailed(view, "run-details-items-more", "data-count") == ["335"]

      for {fact, said} <- [
            {"name", "Mishka Test Blog"},
            {"home", "localhost:8089"},
            {"timezone", "Asia/Tehran"},
            {"signed_in_as", "admin"},
            {"structure", "/%year%/%monthnum%/%postname%/"}
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
               "blog_without_redirects",
               "source",
               "true",
               "false"
             ]

      assert has_element?(
               view,
               ~s|[data-role="run-details-option"][data-option="post_address"]|,
               "Under /blog, with no redirect from the old addresses"
             )
    end
  end

  describe "a WordPress run's Import" do
    @blog_admin [
      "admin:dashboard:migration",
      "admin:dashboard:blog:post",
      "admin:dashboard:runtime:page",
      "admin:dashboard:runtime:redirect",
      "admin:dashboard:runtime:media",
      "admin:dashboard:setting"
    ]

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

      assert outcomes(view) == %{"created" => 194, "skipped" => 147, "undecided" => 2}

      assert has_element?(
               view,
               ~s|[data-role="run-details"][data-status="done"][data-step="import"]|
             )

      assert detailed_counts(view, "run-details-outcome", "data-outcome") ==
               %{"created" => 194, "skipped" => 147, "undecided" => 2}

      for {kind, counts} <- [
            {"media", %{"created" => 17, "skipped" => 1}},
            {"setting", %{"created" => 3, "skipped" => 1}},
            {"category", %{"created" => 9}},
            {"tag", %{"created" => 11}},
            {"page", %{"created" => 11}},
            {"post", %{"created" => 21}},
            # The site routes no Blog page, so no post, term or author is served: only the files,
            # pages, lists and sitemap are redirected to.
            {"post_redirect", %{"created" => 122, "skipped" => 126}}
          ] do
        card = ~s|[data-role="run-details-kind"][data-kind="#{kind}"]|

        assert detailed_counts(view, "run-details-segment", "data-outcome", "data-count", card) ==
                 counts
      end

      assert length(Ash.read!(MishkaBlog.Tag, tenant: site.id, authorize?: false)) == 11

      assert length(Ash.read!(MishkaCmsCore.Runtime.Page, tenant: site.id, authorize?: false)) ==
               11

      assert length(Ash.read!(MishkaBlog.BlogPost, tenant: site.id, authorize?: false)) == 21

      assert length(Ash.read!(MishkaCmsCore.Runtime.Redirect, tenant: site.id, authorize?: false)) ==
               122

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

    test "a kind's card says how many of it failed, else were skipped, and whether one reason covers them",
         %{site: site, admin: admin} do
      settled = fn kind, outcome, reason, times ->
        for id <- 1..times, do: Report.entry(kind, "#{id}", "Item #{id}", outcome, reason)
      end

      report =
        [
          settled.("redirect", :created, nil, 3),
          settled.("redirect", :skipped, "no_old_address", 2),
          settled.("media", :skipped, "not_chosen", 2),
          settled.("media", :skipped, "unchanged", 1),
          settled.("post", :failed, "Timed out", 2),
          settled.("post", :skipped, "unchanged", 1)
        ]
        |> List.flatten()
        |> Enum.reduce(Report.new(), &Report.add(&2, &1))
        |> Report.done()

      run = %{create_run!(site, admin, %{}) | status: :dry_run, report: report}

      panel = LazyHTML.from_fragment(render_component(&RunDetails.panel/1, run: run))

      reason = fn kind ->
        LazyHTML.query(panel, ~s|[data-kind="#{kind}"] [data-role="run-details-kind-reason"]|)
      end

      assert reason.("redirect") |> LazyHTML.attribute("data-count") == ["2"]
      assert reason.("redirect") |> LazyHTML.attribute("data-outcome") == ["skipped"]

      assert reason.("redirect") |> LazyHTML.text() =~
               "2 skipped: No public address at the source"

      assert reason.("media") |> LazyHTML.attribute("data-count") == ["3"]
      assert reason.("media") |> LazyHTML.text() =~ "3 skipped, most often: Left out by"

      assert reason.("post") |> LazyHTML.attribute("data-outcome") == ["failed"]
      assert reason.("post") |> LazyHTML.attribute("data-count") == ["2"]
      assert reason.("post") |> LazyHTML.text() =~ "2 failed: Timed out"
    end

    test "a dry run that would bring files says duplicate files are found only by the import",
         %{site: site, admin: admin} do
      report = fn entries ->
        entries |> Enum.reduce(Report.new(), &Report.add(&2, &1)) |> Report.done()
      end

      files = [
        Report.entry("media", "1", "Hero", :created, "same_file_checked_at_download"),
        Report.entry("redirect", "2", "Old", :created, nil)
      ]

      no_files = [Report.entry("redirect", "2", "Old", :created, nil)]
      run = create_run!(site, admin, %{})
      panel = fn run -> render_component(&RunDetails.panel/1, run: run) end

      shown? = fn status, entries ->
        %{run | status: status, report: report.(entries)}
        |> panel.()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s|[data-role="run-details-duplicate-files"]|)
        |> Enum.any?()
      end

      assert shown?.(:dry_run, files)
      refute shown?.(:dry_run, no_files)
      refute shown?.(:done, files)
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

      assert {:ok, %{status: :failed}} =
               perform_job(MishkaCmsMigration.Workers.DryRunWorker, job.args, attempt: 3)

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

      for run <- [ready, done],
          do: assert(has_element?(view, ~s|#{action("dry_run", run)}[title="Run again"]|))

      assert has_element?(view, ~s|#{action("import", ready)}[title="Import"][data-confirm]|)

      for run <- [running, cancelled],
          do: refute(has_element?(view, action("dry_run", run)))

      for run <- [pending, running, done, cancelled],
          do: refute(has_element?(view, action("import", run)))

      for run <- [pending, ready, running, done],
          do: assert(has_element?(view, "#{action("cancel", run)}[data-confirm]"))

      refute has_element?(view, action("cancel", cancelled))
    end

    test "offer no Run again on a run whose password an earlier release cleared, and say why when asked",
         %{conn: conn, site: site, admin: admin} do
      register_plugin!(TokenSource, MishkaCmsMigration.Source.event())

      done =
        %{source: "token", connection: %{"url" => "https://t.example"}, secret: "t0ken"}
        |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)
        |> dry_run!(admin)
        |> import!(admin)

      MishkaCmsMigration.Repo.query!(
        "UPDATE mishka_cms_migration_runs SET connection_secret = NULL WHERE id = $1",
        [Ecto.UUID.dump!(done.id)]
      )

      view = open!(conn, admin)

      refute has_element?(view, action("dry_run", done))
      assert has_element?(view, "#{action("cancel", done)}[data-confirm]")

      assert crafted!(view, "dry_run", done.id) =~
               "This run no longer holds its Token password. Start a New import."

      assert status(done) == :done
    end

    test "Run again on an imported run dry runs it again, and its Import brings what changed since",
         %{conn: conn, site: site, admin: admin} do
      done = migrate!(site, admin, %{"redirect" => [redirect_row(1, "/a", "/b")]})
      view = open!(conn, admin)

      assert row_action!(view, "dry_run", done) =~ "Dry run started."
      assert status(done) == :dry_running
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
      settled(view)

      assert has_element?(view, ~s|[data-role="run-status"][data-status="dry_run"]|)
      assert outcomes(view) == %{"skipped" => 1}
      assert row_action!(view, "import", done) =~ "Import started."
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
      assert status(done) == :done
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
      assert has_element?(view, "#flash-error", "no longer here")
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

      assert crafted!(view, "import", pending.id) =~
               "The run has no dry run yet. Run a dry run first."

      assert has_element?(view, "#flash-info", "no dry run yet")
      refute has_element?(view, "#flash-error")

      assert status(pending) == :pending
    end
  end

  describe "the runs table's columns" do
    setup do
      for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)
      :ok
    end

    # The domain's Tailwind adapter draws a row action, a button or a link, as a 30px square, 4px
    # from the next, in a cell with 16px of padding either side.
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
            ~s|#migration-runs-table [id$="-#{run.id}"] [data-role="gervaz-row-actions"] :is(button, a)|
          )
          |> Enum.count()
        end

      assert actions_width(Enum.max(buttons)) <= tracks |> List.last() |> px_min()
    end
  end

  describe "the Logs" do
    setup do
      for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)
      :ok
    end

    defp open_logs!(view) do
      view |> element("#migration-runs-table #migration-activity-toggle") |> render_click()
      render_async(view)
    end

    test "beside the runs table open the core's feed over the site's run steps, newest first", %{
      conn: conn,
      site: site
    } do
      admin = migration_admin!(site)

      site
      |> create_run!(admin, %{"redirect" => [redirect_row(1, "/a", "/b")]})
      |> dry_run!(admin)

      view = open!(conn, admin)
      assert has_element?(view, "#migration-activity-toggle", "Logs")
      refute has_element?(view, "#migration-activity-panel", "Connected to old.example.com.")

      html = open_logs!(view)

      assert [finished, started, connected] =
               html
               |> LazyHTML.from_fragment()
               |> LazyHTML.query(~s|#migration-activity-list > [id^="activity-migration-"]|)
               |> Enum.map(&LazyHTML.text/1)

      assert finished =~ "Dry run of old.example.com finished: 1 created."
      assert finished =~ to_string(admin.email)
      assert started =~ "Dry run of old.example.com started."
      assert connected =~ "Connected to old.example.com."
    end

    test "show no other site's steps, and a new step of the site's without a reload", %{
      conn: conn,
      site: site
    } do
      admin = migration_admin!(site)
      other = create_site!()
      create_run!(other, migration_admin!(other), %{}, %{source_host: "elsewhere.example.com"})

      view = open!(conn, admin)
      refute open_logs!(view) =~ "elsewhere.example.com"

      create_run!(site, admin, %{})

      assert settled(view) =~ "Connected to old.example.com."
    end
  end

  describe "a run's Items link and latest items" do
    setup %{site: site} do
      stub!()
      Req.Test.set_req_test_to_shared()
      on_exit(&Req.Test.set_req_test_to_private/0)
      admin = migration_admin!(site, @blog_admin)

      run =
        %{
          source: "wordpress",
          connection: %{"url" => "http://localhost:8089", "user" => "admin"},
          secret: "app password"
        }
        |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)
        |> dry_run!(admin)

      {:ok, admin: admin, run: run}
    end

    defp items_link(run), do: ~s|#migration-runs-table a[href="#{MigrationRun.items_path(run)}"]|

    test "every run's row links to its Items page, which the link opens", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      pending =
        MishkaCmsMigration.create_run!(
          %{
            source: "wordpress",
            source_host: "waiting.example.com",
            connection: %{"url" => "http://localhost:8089", "user" => "admin"},
            secret: "app password"
          },
          actor: admin,
          tenant: site.id
        )

      view = open!(conn, admin)

      assert has_element?(view, items_link(run))
      assert has_element?(view, items_link(pending))

      assert {:ok, items, _html} =
               view
               |> element(items_link(run))
               |> render_click()
               |> follow_redirect(signed_in(conn, admin))

      render_async(items)
      assert has_element?(items, ~s|[data-role="items-source"][data-run-id="#{run.id}"]|)
    end

    test "the latest items end with a link to the rest, on the Items page", %{
      conn: conn,
      admin: admin,
      run: run
    } do
      run = import!(run, admin)
      view = open!(conn, admin)
      expand!(view, run)

      assert length(detailed(view, "run-details-item", "data-source-id")) == 8
      assert [more] = detailed(view, "run-details-items-link", "href")
      assert more == MigrationRun.items_path(run)
    end

    test "the latest items link to their CMS record, when they have one", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      run = import!(run, admin)
      view = open!(conn, admin)
      expand!(view, run)

      items = MishkaCmsMigration.MigrationItem |> Ash.read!(tenant: site.id, authorize?: false)
      panel = LazyHTML.from_fragment(render(view))
      rows = LazyHTML.query(panel, ~s|#{@details} [data-role="run-details-item"]|)

      linked =
        for row <- rows do
          [kind] = LazyHTML.attribute(row, "data-kind")
          [source_id] = LazyHTML.attribute(row, "data-source-id")
          item = Enum.find(items, &({&1.source_kind, &1.source_id} == {kind, source_id}))

          hrefs =
            row |> LazyHTML.query(~s|[data-role="record-admin"]|) |> LazyHTML.attribute("href")

          assert is_nil(item.target_id) == (hrefs == []), "#{kind} #{source_id}"
          hrefs
        end

      assert length(linked) == 8
      assert List.flatten(linked) != []

      assert Enum.all?(
               List.flatten(linked),
               &String.starts_with?(&1, "/admin/dashboard/runtime/redirects?")
             )
    end
  end

  describe "the sidebar" do
    test "has one entry, in Plugins, gated by the migration permission, and a page beside it" do
      assert [item, items] = SidebarMenu.items()
      assert {item.key, item.path, item.group} == {"migration", @page, "plugins"}
      assert {items.key, items.nav} == {"migration.items", false}
      assert SidebarMenu.permissions("migration") == ["admin:dashboard:migration"]
      assert Enum.any?(MishkaCmsCore.Sidebar.collect().items, &(&1.key == "migration"))
      assert MishkaCmsCore.Sidebar.permissions_for_module(Index) == ["admin:dashboard:migration"]

      assert MishkaCmsCore.Sidebar.permissions_for_module(Item.Index) == [
               "admin:dashboard:migration"
             ]
    end
  end
end
