# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Live.ItemsPageTest do
  @moduledoc """
  A run's Items page, over a WordPress site imported through the real source's recordings: it lists
  every item the migration keeps of the run's source on the run's site with its kind, outcome and
  reason, narrows them by kind, outcome, title and the run that met them last, loads them a page
  at a time, expands one to what is kept of it, links each to its CMS record, and is never opened
  for another site's run.
  """
  use MishkaCmsMigration.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsMigration.DataCase, only: [register_plugin!: 2, without_blog!: 0]
  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0]

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsMigration.{MigrationItem, MigrationRun}

  @admin [
    "admin:dashboard:migration",
    "admin:dashboard:blog:post",
    "admin:dashboard:runtime:page",
    "admin:dashboard:runtime:redirect",
    "admin:dashboard:runtime:media",
    "admin:dashboard:setting"
  ]
  @table "#migration-items-table"
  @filter "migration-items-table_migration_items-filter"

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

    stub!()
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)
    admin = migration_admin!(site, @admin)

    run =
      %{
        source: "wordpress",
        connection: %{"url" => "http://localhost:8089", "user" => "admin"},
        secret: "app password"
      }
      |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)
      |> dry_run!(admin)
      |> import!(admin)

    {:ok, conn: on_host(conn, "localhost"), site: site, admin: admin, run: run}
  end

  defp stored(site),
    do: MigrationItem |> Ash.read!(tenant: site.id, authorize?: false) |> Enum.sort_by(& &1.id)

  defp later_run!(site, admin, run) do
    MishkaCmsMigration.create_run!(
      %{
        source: "wordpress",
        source_host: run.source_host,
        connection: %{"url" => "http://localhost:8089", "user" => "admin"},
        secret: "app password"
      },
      actor: admin,
      tenant: site.id
    )
  end

  defp open!(conn, user, run), do: open!(conn, user, run, "")

  defp open!(conn, user, run, query) do
    {:ok, view, _html} = conn |> signed_in(user) |> live(MigrationRun.items_path(run) <> query)
    render_async(view)
    view
  end

  defp settled(view) do
    _state = :sys.get_state(view.pid)
    _state = :sys.get_state(view.pid)
    render_async(view)
    render(view)
  end

  defp filter!(view, params) do
    view |> form("##{@filter}", params) |> render_change()
    settled(view)
  end

  defp load_more!(view) do
    view |> element("#{@table} button[phx-click=load_more]") |> render_click()
    settled(view)
  end

  defp expand!(view, item) do
    view
    |> element(~s|#{@table} [phx-click="expand_row"][phx-value-id="#{item.id}"]|)
    |> render_click()

    settled(view)
  end

  defp parts(view, selector),
    do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp attributes(view, role, attribute),
    do: view |> parts(~s|#{@table} [data-role="#{role}"]|) |> LazyHTML.attribute(attribute)

  defp texts(view, role),
    do:
      view
      |> parts(~s|#{@table} [data-role="#{role}"]|)
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

  # The items the table shows, each as `{kind, source id, outcome}`, in the order it lists them.
  defp rows(view) do
    ids = view |> texts("item-source-id") |> Enum.map(&String.trim_leading(String.trim(&1), "#"))
    kinds = attributes(view, "item-kind", "data-kind")
    outcomes = attributes(view, "item-outcome", "data-outcome")

    Enum.zip_with([kinds, ids, outcomes], fn [kind, id, outcome] -> {kind, id, outcome} end)
  end

  defp kept(items), do: Enum.map(items, &{&1.source_kind, &1.source_id, to_string(&1.outcome)})

  defp planned(%{plan: :skipped, plan_reason: "connected"}), do: "connected"
  defp planned(item), do: to_string(item.plan)

  # How many items the table says it holds, whatever it has loaded so far.
  defp total(view) do
    ~r/(\d+)\s*$/
    |> Regex.run(view |> parts("#{@table}-total") |> LazyHTML.text() |> String.trim())
    |> List.last()
    |> String.to_integer()
  end

  defp item!(item), do: Ash.get!(MigrationItem, item.id, tenant: item.site_id, authorize?: false)

  defp migrate_run!(run, admin), do: run |> dry_run!(admin) |> import!(admin)

  # An `:update` row action names its row by `phx-value-id`, an `:edit` one in the push its
  # `phx-click` commands end with.
  defp row_button(action, item),
    do:
      ~s|#{@table} [phx-value-event="#{action}"][phx-value-id="#{item.id}"], | <>
        ~s|#{@table} [phx-click*='"event":"#{action}"'][phx-click*='"id":"#{item.id}"']|

  defp row_action!(view, action, item) do
    view |> element(row_button(action, item)) |> render_click()
    settled(view)
  end

  # What a row's Map to… shows on the client when it is clicked, before the server answers.
  defp map_to_shows(view, item) do
    for click <- view |> parts(row_button("map_to", item)) |> LazyHTML.attribute("phx-click"),
        {:ok, commands} <- [Jason.decode(click)],
        ["show", %{"to" => to}] <- commands,
        do: to
  end

  defp map_value(view),
    do:
      view
      |> parts(~s|#migration-item-map-modal input[type="hidden"][name="mapped_id"]|)
      |> LazyHTML.attribute("value")

  defp pick!(view, item) do
    view
    |> element(~s|#{@table} [phx-click="toggle_select"][phx-value-id="#{item.id}"]|)
    |> render_click()

    settled(view)
  end

  defp pick_all!(view) do
    view |> element("#{@table} input[name=select_all]") |> render_click()
    settled(view)
  end

  defp bulk!(view, action) do
    view
    |> element(~s|#{@table} [phx-click="bulk_action"][phx-value-action="#{action}"]|)
    |> render_click()

    settled(view)
  end

  defp plan_of(view, item) do
    view
    |> parts(~s|#{@table} [id$="#{item.id}"] [data-role="item-plan"]|)
    |> LazyHTML.attribute("data-plan")
    |> List.first()
  end

  @map_field "#migration_item_map_form-form_mapped_id"
  @decision_field "#migration_item_map_form-form_decision"

  # What Map to… offers, once its search field is focused, by label.
  defp map_choices(view) do
    view |> element(@map_field) |> render_focus()

    view
    |> parts(~s|#migration-item-map-modal [role="option"]|)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp save_map!(view, id) do
    view |> element(@map_field) |> render_focus()

    view
    |> element(~s|#migration-item-map-modal [role="option"][phx-value-id="#{id}"]|)
    |> render_click()

    view |> element("#migration-item-map-modal form") |> render_submit()
    settled(view)
  end

  # What Decide… offers, once its field is focused, by label.
  defp decision_choices(view) do
    view |> element(@decision_field) |> render_focus()

    view
    |> parts(~s|#migration-item-map-modal [role="option"]|)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp decide!(view, choice) do
    view |> element(@decision_field) |> render_focus()

    view
    |> element(~s|#migration-item-map-modal [role="option"][phx-value-id="#{choice}"]|)
    |> render_click()

    view |> element("#migration-item-map-modal form") |> render_submit()
    settled(view)
  end

  # A second WordPress site moved into the same site: its items meet what the first one wrote.
  defp second_source!(site, admin) do
    %{
      source: "wordpress",
      source_host: "second.example",
      connection: %{"url" => "http://localhost:8089", "user" => "admin"},
      secret: "app password"
    }
    |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)
    |> dry_run!(admin)
  end

  defp second_item(site, kind, source_id),
    do:
      Enum.find(
        stored(site),
        &({&1.source_host, &1.source_kind, &1.source_id} == {"second.example", kind, source_id})
      )

  defp tree_roots(view) do
    view
    |> parts(~s|[data-role="item-tree-kind"] > ul > [data-role="item-tree-node"]|)
    |> LazyHTML.attribute("data-source-id")
  end

  defp children_of(view, source_id) do
    view
    |> parts(
      ~s|[data-role="item-tree-node"][data-source-id="#{source_id}"] > [data-role="item-tree-children"] > [data-role="item-tree-node"]|
    )
    |> LazyHTML.attribute("data-source-id")
  end

  defp node_plan(view, item) do
    view
    |> parts(
      ~s|[data-role="item-tree-node"][data-item-id="#{item.id}"] > div [data-role="item-plan"]|
    )
    |> LazyHTML.attribute("data-plan")
    |> List.first()
  end

  defp json(view),
    do: view |> parts(~s|#{@table} [data-role="item-json"]|) |> LazyHTML.text() |> Jason.decode!()

  describe "the page" do
    test "lists every item the import kept, with its kind, outcome and title", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      items = stored(site)
      view = open!(conn, admin, run)

      assert has_element?(view, "#migration-items-page h1", "Items")
      assert has_element?(view, ~s|[data-role="items-source"]|, "localhost:8089")
      assert total(view) == length(items)
      assert length(items) == run.report.counts |> Map.values() |> Enum.sum()

      for {kind, of_kind} <- Enum.group_by(items, & &1.source_kind), length(of_kind) <= 20 do
        filter!(view, %{"source_kind" => kind})

        assert Enum.sort(rows(view)) == Enum.sort(kept(of_kind))

        assert texts(view, "item-title") |> Enum.sort() ==
                 of_kind |> Enum.map(& &1.title) |> Enum.sort()
      end
    end

    test "says in words why an item was skipped", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      view = open!(conn, admin, run)
      skipped = Enum.find(stored(site), &(&1.outcome == :skipped and &1.reason))

      filter!(view, %{"source_kind" => skipped.source_kind, "outcome" => "skipped"})

      assert view |> texts("item-reason") |> Enum.join(" ") =~
               MigrationRun.reason_label(skipped.reason)
    end

    test "shows every item of the run's source on its site, whichever run met an item last", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      later = later_run!(site, admin, run)

      assert total(open!(conn, admin, later)) == length(stored(site))
    end
  end

  describe "the plan" do
    setup do
      for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)
      :ok
    end

    test "shows what the last dry run would do with each item, beside what the last import did",
         %{conn: conn, site: site, admin: admin, run: run} do
      later = site |> later_run!(admin, run) |> dry_run!(admin)
      view = open!(conn, admin, later)
      items = stored(site)

      for {kind, of_kind} <- Enum.group_by(items, & &1.source_kind), length(of_kind) <= 20 do
        filter!(view, %{"source_kind" => kind})

        assert view |> attributes("item-plan", "data-plan") |> Enum.sort() ==
                 of_kind |> Enum.map(&planned/1) |> Enum.sort()

        assert view |> attributes("item-outcome", "data-outcome") |> Enum.sort() ==
                 of_kind |> Enum.map(&to_string(&1.outcome)) |> Enum.sort()
      end

      filter!(view, %{"source_kind" => "tag"})

      assert Enum.uniq(texts(view, "item-plan-reason")) == [
               MigrationRun.reason_label("unchanged")
             ]
    end

    test "lists the items a dry run met before any import, as not imported yet", %{
      conn: conn,
      site: site,
      admin: admin
    } do
      rows = [redirect_row(1, "/a", "/b"), redirect_row(2, "/c", "/d")]

      run =
        site
        |> create_run!(admin, %{"redirect" => rows, "note" => [%{"id" => 9}]})
        |> dry_run!(admin)

      view = open!(conn, admin, run)

      assert total(view) == 3

      assert Enum.sort(attributes(view, "item-plan", "data-plan")) == [
               "created",
               "created",
               "skipped"
             ]

      assert attributes(view, "item-outcome", "data-outcome") == ["", "", ""]
      assert texts(view, "item-plan-reason") == [MigrationRun.reason_label("no_target")]

      filter!(view, %{"plan" => "created"})
      assert Enum.sort(rows(view)) == [{"redirect", "1", ""}, {"redirect", "2", ""}]

      filter!(view, %{"plan" => "", "this_run" => "true"})
      assert total(view) == 0
    end
  end

  describe "leaving out" do
    setup do
      for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)
      :ok
    end

    test "a row's Leave out leaves the item out, and Bring back brings it back, in every open tab",
         %{conn: conn, site: site, admin: admin, run: run} do
      view = open!(conn, admin, run)
      other_tab = open!(conn, admin, run)
      tag = Enum.find(stored(site), &(&1.source_kind == "tag"))
      for tab <- [view, other_tab], do: filter!(tab, %{"source_kind" => "tag"})

      row_action!(view, "leave_out", tag)

      assert %{left_out: true} = item!(tag)
      assert plan_of(view, tag) == "left_out"
      refute has_element?(view, row_button("leave_out", tag))
      settled(other_tab)
      assert plan_of(other_tab, tag) == "left_out"

      row_action!(view, "bring_back", tag)

      assert %{left_out: false} = item!(tag)
      assert plan_of(view, tag) == "created"
      settled(other_tab)
      assert plan_of(other_tab, tag) == "created"
    end

    test "the picked rows are left out together, and the rest are not", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      view = open!(conn, admin, run)
      [one, two | rest] = Enum.filter(stored(site), &(&1.source_kind == "tag"))
      filter!(view, %{"source_kind" => "tag"})

      for item <- [one, two], do: pick!(view, item)
      html = bulk!(view, "leave_out")

      assert html =~ "2 items left out."
      assert Enum.map([one, two], &item!(&1).left_out) == [true, true]
      assert Enum.all?(rest, &(not item!(&1).left_out))
      assert view |> attributes("item-plan", "data-plan") |> Enum.count(&(&1 == "left_out")) == 2
      refute has_element?(view, "#{@table} input[name=select_row][checked]")

      for item <- [one, two], do: pick!(view, item)
      bulk!(view, "bring_back")
      assert Enum.all?(stored(site), &(not &1.left_out))
    end

    test "picking every row leaves out what the filters find, of this run's source and site alone",
         %{conn: conn, site: site, admin: admin, run: run} do
      migrate!(site, admin, %{"redirect" => [redirect_row(1, "/a", "/b")]})
      other = create_site!()
      other_admin = migration_admin!(other)

      theirs =
        create_run!(other, other_admin, %{"redirect" => [redirect_row(2, "/c", "/d")]}, %{
          source_host: run.source_host
        })

      migrate_run!(theirs, other_admin)

      for user <- [admin, create_user_with_permissions!(["admin:dashboard:migration"])] do
        view = open!(conn, user, run)
        filter!(view, %{"source_kind" => "tag"})
        pick_all!(view)
        assert bulk!(view, "leave_out") =~ "11 items left out."

        left_out = Enum.filter(stored(site) ++ stored(other), & &1.left_out)

        assert Enum.all?(
                 left_out,
                 &({&1.site_id, &1.source_host, &1.source_kind} ==
                     {site.id, run.source_host, "tag"})
               )

        assert length(left_out) == 11

        pick_all!(view)
        bulk!(view, "bring_back")
        assert Enum.all?(stored(site), &(not &1.left_out))
      end
    end

    test "is refused while a dry run of the site is running, and changes nothing", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      view = open!(conn, admin, run)
      tag = Enum.find(stored(site), &(&1.source_kind == "tag"))
      filter!(view, %{"source_kind" => "tag"})

      site
      |> later_run!(admin, run)
      |> MishkaCmsMigration.start_dry_run!(actor: admin, tenant: site.id)

      assert row_action!(view, "leave_out", tag) =~ "is running"
      pick!(view, tag)
      assert bulk!(view, "leave_out") =~ "is running"

      assert %{left_out: false} = item!(tag)
      assert plan_of(view, tag) == "created"
    end

    test "Run again then says on the run's card how many the admin left out", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      view = open!(conn, admin, run)
      filter!(view, %{"source_kind" => "tag"})
      pick_all!(view)
      bulk!(view, "leave_out")

      later = site |> later_run!(admin, run) |> dry_run!(admin)

      card =
        (&MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.RunDetails.panel/1)
        |> render_component(run: later)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s|[data-kind="tag"] [data-role="run-details-kind-reason"]|)

      assert LazyHTML.attribute(card, "data-count") == ["11"]
      assert LazyHTML.text(card) =~ "11 skipped: Left out by you"

      assert Enum.all?(
               stored(site),
               &(&1.source_kind != "tag" or &1.plan_reason == "left_out_by_admin")
             )
    end
  end

  describe "Decide…" do
    test "a setting the site has its own of needs a decision, and Decide… keeps the admin's choice",
         %{conn: conn, site: site, admin: admin} do
      second = second_source!(site, admin)
      title = second_item(site, "setting", "title")
      view = open!(conn, admin, second, "?items_filter_source_kind=setting")

      assert plan_of(view, title) == "undecided"

      assert view
             |> parts(~s|#{@table} [id$="#{title.id}"] [data-role="item-plan-reason"]|)
             |> LazyHTML.text() =~ "already has its own"

      refute has_element?(view, row_button("map_to", title))
      refute has_element?(view, row_button("decide", second_item(site, "setting", "tagline")))

      row_action!(view, "decide", title)
      assert decision_choices(view) == ["Keep the site's own", "Use the WordPress one"]
      assert decide!(view, "import") =~ "Decided."

      assert item!(title).decisions == %{"site_has_own" => "import"}
      assert plan_of(view, title) == "decided"

      row_action!(view, "decide", title)
      decide!(view, "keep")

      assert item!(title).decisions == %{"site_has_own" => "keep"}
    end

    test "a category or a page whose address the site has offers Connect or Import as new, in place of Map to…",
         %{conn: conn, site: site, admin: admin} do
      second = second_source!(site, admin)

      for {kind, source_id} <- [{"category", "6"}, {"page", "29"}] do
        item = second_item(site, kind, source_id)
        view = open!(conn, admin, second, "?items_filter_source_kind=#{kind}")

        assert plan_of(view, item) == "undecided"
        refute has_element?(view, row_button("map_to", item))
        row_action!(view, "decide", item)

        assert decision_choices(view) ==
                 ["Connect to the existing record", "Import as new with another slug"]
      end
    end

    test "is shown while the decision has not taken effect, and gone once an import wrote the item by it",
         %{conn: conn, site: site, admin: admin} do
      second = second_source!(site, admin)
      tag = second_item(site, "tag", "10")
      MishkaCmsMigration.decide_item!(tag, "import", actor: admin, tenant: site.id)

      view = open!(conn, admin, second, "?items_filter_source_kind=tag")
      assert has_element?(view, row_button("decide", tag))

      site |> later_run!(admin, second) |> migrate_run!(admin)
      view = open!(conn, admin, second, "?items_filter_source_kind=tag")

      assert %{outcome: :created} = item!(tag)
      refute has_element?(view, row_button("decide", tag))
      assert has_element?(view, row_button("map_to", tag))
    end

    test "an item the Blog would write, on a node without it, offers Wait for the Blog or Leave out",
         %{conn: conn, site: site, admin: admin} do
      without_blog!()
      second = second_source!(site, admin)
      tag = second_item(site, "tag", "10")
      view = open!(conn, admin, second, "?items_filter_source_kind=tag")

      assert plan_of(view, tag) == "undecided"
      row_action!(view, "decide", tag)
      assert decision_choices(view) == ["Wait for the Blog", "Leave out"]
      decide!(view, "leave_out")

      assert %{left_out: true, decisions: %{}} = item!(tag)
      assert plan_of(view, tag) == "left_out"
    end

    test "a main menu that links pages that are not live names them, and offers to publish them or leave their links out",
         %{conn: conn, site: site, run: run} do
      admin = migration_admin!(site, @admin ++ ["admin:dashboard:runtime:layout"])

      create_layout!(
        site_id: site.id,
        name: "site-main",
        path: "/layouts/site-main",
        template:
          ~s(<.component component_name="site-header" site="localhost"></.component><main>{@inner_content}</main>)
      )

      later = site |> later_run!(admin, run) |> dry_run!(admin)
      menu = Enum.find(stored(site), &(&1.source_kind == "menu" and &1.source_id == "22"))
      view = open!(conn, admin, later, "?items_filter_source_kind=menu")

      assert plan_of(view, menu) == "undecided"

      assert view
             |> parts(~s|#{@table} [id$="#{menu.id}"] [data-role="item-plan-reason"]|)
             |> LazyHTML.text() =~ "Links to pages that are not live: About, Team, Leadership"

      row_action!(view, "decide", menu)

      assert decision_choices(view) ==
               ["Leave those links out of the menu", "Publish the linked pages"]

      decide!(view, "import")

      assert item!(menu).decisions == %{"draft_pages" => "import"}
      assert plan_of(view, menu) == "decided"
    end

    test "the picked rows are decided together, and one with nothing to decide is left as it is",
         %{conn: conn, site: site, admin: admin} do
      second = second_source!(site, admin)
      [title, tagline] = for id <- ["title", "tagline"], do: second_item(site, "setting", id)
      view = open!(conn, admin, second, "?items_filter_source_kind=setting")

      for item <- [title, tagline], do: pick!(view, item)

      assert bulk!(view, "decide_import") =~
               "1 item decided. 1 left as it was: nothing on it takes this choice."

      assert item!(title).decisions == %{"site_has_own" => "import"}
      assert item!(tagline).decisions == %{}

      pick!(view, title)
      assert bulk!(view, "decide_keep") =~ "1 item decided."
      assert item!(title).decisions == %{"site_has_own" => "keep"}
    end

    test "the Plan filter finds them, and the run's card says how many need a decision", %{
      conn: conn,
      site: site,
      admin: admin
    } do
      second = second_source!(site, admin)

      waiting =
        Enum.filter(stored(site), &(&1.source_host == "second.example" and &1.plan == :undecided))

      view = open!(conn, admin, second)
      filter!(view, %{"plan" => "undecided"})
      assert [_ | _] = waiting
      assert total(view) == length(waiting)

      card =
        (&MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.RunDetails.panel/1)
        |> render_component(run: second)
        |> LazyHTML.from_fragment()

      pill = LazyHTML.query(card, ~s|[data-role="run-details-outcome"][data-outcome="undecided"]|)
      assert LazyHTML.attribute(pill, "data-count") == ["#{length(waiting)}"]
      assert LazyHTML.text(pill) =~ "need"

      assert card
             |> LazyHTML.query(~s|[data-kind="setting"] [data-role="run-details-kind-reason"]|)
             |> LazyHTML.text() =~ "your decision: The site already has its own"
    end
  end

  describe "Map to…" do
    test "lists the site's categories in the language it leads with, and saving maps the item, or imports it as its own",
         %{conn: conn, site: site, admin: admin, run: run} do
      view = open!(conn, admin, run)

      releases =
        Enum.find(stored(site), &(&1.source_kind == "category" and &1.title == "Releases"))

      collections = Ash.read!(MishkaBlog.Collection, tenant: site.id, authorize?: false)
      news = Enum.find(collections, &(&1.name == "News"))

      MishkaBlog.Collection
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Only in Persian", slug: "only-fa", status: :active, language: "fa"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.create!()

      filter!(view, %{"source_kind" => "category"})

      refute has_element?(
               view,
               row_button("map_to", Enum.find(stored(site), &(&1.source_kind == "post")))
             )

      row_action!(view, "map_to", releases)

      assert map_choices(view) ==
               ["Import as its own" | collections |> Enum.map(& &1.name) |> Enum.sort()]

      save_map!(view, news.id)

      assert %{mapped_id: mapped_id} = item!(releases)
      assert mapped_id == news.id
      assert plan_of(view, releases) == "mapped"

      assert view
             |> parts(~s|#{@table} [id$="#{releases.id}"] [data-role="item-plan-reason"]|)
             |> LazyHTML.text() =~ "News"

      row_action!(view, "map_to", releases)
      save_map!(view, "__nil__")

      assert %{mapped_id: nil} = item!(releases)
      assert plan_of(view, releases) == "created"
    end

    test "Run again then reports the mapped category as connected, and Import writes none", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      view = open!(conn, admin, run)
      news = Enum.find(stored(site), &(&1.source_kind == "category" and &1.title == "News"))

      tutorials =
        Ash.read!(MishkaBlog.Collection, tenant: site.id, authorize?: false)
        |> Enum.find(&(&1.name == "Tutorials"))

      filter!(view, %{"source_kind" => "category"})
      row_action!(view, "map_to", news)
      save_map!(view, tutorials.id)

      later = site |> later_run!(admin, run) |> dry_run!(admin)

      assert Enum.find(
               later.report.entries,
               &(&1.kind == "category" and &1.source_id == news.source_id)
             ).reason == "connected"
    end

    test "shows the modal from a row in the List and in the Map view, with that item's form in it",
         %{conn: conn, site: site, admin: admin, run: run} do
      phoenix = Enum.find(stored(site), &(&1.source_kind == "tag" and &1.title == "Phoenix"))
      language = Languages.primary(site.id)

      tags =
        MishkaBlog.Tag
        |> Ash.read!(tenant: site.id, authorize?: false)
        |> Enum.filter(&(&1.language == language))

      elixir = Enum.find(tags, &(&1.name == "Elixir"))
      list = open!(conn, admin, run, "?items_filter_source_kind=tag")
      tree = open!(conn, admin, run, "?items_template=item_tree&items_filter_source_kind=tag")

      assert has_element?(tree, ~s|#{@table}[data-role="item-tree"]|)

      for view <- [list, tree] do
        assert "#migration-item-map-modal" in map_to_shows(view, phoenix)
      end

      row_action!(tree, "map_to", phoenix)
      assert ["Import as its own" | names] = map_choices(tree)
      assert Enum.sort(names) == tags |> Enum.map(& &1.name) |> Enum.sort()
      save_map!(tree, elixir.id)

      assert item!(phoenix).mapped_id == elixir.id

      row_action!(list, "map_to", phoenix)
      assert map_value(list) == [elixir.id]
    end

    test "Cancel closes the modal and leaves the item as it was", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      phoenix = Enum.find(stored(site), &(&1.source_kind == "tag" and &1.title == "Phoenix"))
      view = open!(conn, admin, run, "?items_filter_source_kind=tag")

      row_action!(view, "map_to", phoenix)
      view |> element("#migration-item-map-modal button", "Cancel") |> render_click()

      assert_push_event(view, "gervaz:exec-js", %{target: "migration-item-map-modal", js: js})
      assert js =~ "#migration-item-map-modal-container"
      assert item!(phoenix).mapped_id == nil
    end
  end

  describe "the Map view" do
    test "draws the categories as WordPress nests them, each with its plan, and folds a parent's children",
         %{conn: conn, admin: admin, run: run} do
      view =
        open!(conn, admin, run, "?items_template=item_tree&items_filter_source_kind=category")

      assert has_element?(view, ~s|#{@table}[data-role="item-tree"]|)
      assert tree_roots(view) == ["2", "5", "1", "9"]
      assert children_of(view, "2") == ["4", "3"]
      assert children_of(view, "5") == ["6", "7"]
      assert children_of(view, "7") == ["8"]
      assert children_of(view, "8") == []

      assert view |> attributes("item-plan", "data-plan") |> Enum.uniq() == ["created"]

      for parent <- ["2", "5", "7"] do
        assert view
               |> parts(
                 ~s|[data-role="item-tree-node"][data-source-id="#{parent}"] > div [data-role="item-tree-fold"]|
               )
               |> LazyHTML.attribute("phx-click")
               |> hd() =~ "-children"
      end
    end

    test "is one click from the List, and a row's choice shows in the tree at once", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      view = open!(conn, admin, run)
      filter!(view, %{"source_kind" => "category"})

      view
      |> element(~s|#{@table} [phx-click="switch_template"][phx-value-template="item_tree"]|)
      |> render_click()

      settled(view)

      assert has_element?(view, ~s|#{@table}[data-role="item-tree"]|)

      news = Enum.find(stored(site), &(&1.source_kind == "category" and &1.title == "News"))
      row_action!(view, "leave_out", news)

      assert node_plan(view, news) == "left_out"
      pick!(view, news)
      bulk!(view, "bring_back")
      assert node_plan(view, news) == "created"
    end

    test "Map categories in the head opens the Map view on the categories", %{
      conn: conn,
      admin: admin,
      run: run
    } do
      view = open!(conn, admin, run)

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element(~s|[data-role="items-map-categories"]|) |> render_click()

      query = URI.parse(to).query

      assert %{"items_template" => "item_tree", "items_filter_source_kind" => "category"} =
               URI.decode_query(query)

      tree = open!(conn, admin, run, "?" <> query)
      assert has_element?(tree, ~s|#{@table}[data-role="item-tree"]|)

      assert tree |> parts(~s|[data-role="item-tree-kind"]|) |> LazyHTML.attribute("data-kind") ==
               ["category"]
    end
  end

  describe "the filters" do
    test "narrow the items to the chosen kind, and back again", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      view = open!(conn, admin, run)
      all = total(view)

      for {kind, items} <- Enum.group_by(stored(site), & &1.source_kind) do
        filter!(view, %{"source_kind" => kind})
        assert total(view) == length(items)
      end

      filter!(view, %{"source_kind" => ""})
      assert total(view) == all
    end

    test "narrow the items to the chosen outcome", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      view = open!(conn, admin, run)

      for outcome <- [:skipped, :created] do
        filter!(view, %{"outcome" => to_string(outcome)})

        assert total(view) == Enum.count(stored(site), &(&1.outcome == outcome))
        assert view |> rows() |> Enum.map(&elem(&1, 2)) |> Enum.uniq() == ["#{outcome}"]
      end

      filter!(view, %{"outcome" => "failed"})
      assert total(view) == 0
      assert has_element?(view, @table, "No items found")
    end

    test "search the title", %{conn: conn, site: site, admin: admin, run: run} do
      view = open!(conn, admin, run)
      items = stored(site)
      post = Enum.find(items, &(&1.source_kind == "post" and &1.title))
      word = post.title |> String.split() |> Enum.max_by(&String.length/1) |> String.downcase()
      matching = Enum.filter(items, &String.contains?(String.downcase(&1.title || ""), word))

      filter!(view, %{"search" => word})

      assert total(view) == length(matching)
      assert length(matching) in 1..(length(items) - 1)
      assert Enum.sort(rows(view)) == Enum.sort(kept(matching))
    end

    test "narrow the items to the ones this run met last", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      later = open!(conn, admin, later_run!(site, admin, run))
      filter!(later, %{"this_run" => "true"})
      assert total(later) == 0

      view = open!(conn, admin, run)
      filter!(view, %{"this_run" => "true"})
      assert total(view) == length(stored(site))
    end

    test "are read from the address, so a reload shows the same items", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      view = open!(conn, admin, run, "?items_filter_outcome=skipped&items_filter_source_kind=tag")
      assert total(view) == 0

      view = open!(conn, admin, run, "?items_filter_outcome=skipped")
      assert total(view) == Enum.count(stored(site), &(&1.outcome == :skipped))
      assert view |> rows() |> Enum.map(&elem(&1, 2)) |> Enum.uniq() == ["skipped"]
    end
  end

  describe "the pages" do
    test "load a page at a time, and the last one ends the list", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      view = open!(conn, admin, run)
      all = length(stored(site))

      assert length(rows(view)) == 20
      load_more!(view)
      assert length(rows(view)) == 40

      for _more <- 3..ceil(all / 20), do: load_more!(view)

      assert Enum.sort(rows(view)) == Enum.sort(kept(stored(site)))
      refute has_element?(view, "#{@table} button[phx-click=load_more]")
    end
  end

  describe "an expanded item" do
    test "shows what is kept of it as JSON, and says what is not", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      view = open!(conn, admin, run)
      post = Enum.find(stored(site), &(&1.source_kind == "post" and map_size(&1.extra) > 0))
      filter!(view, %{"source_kind" => "post", "search" => post.title})
      expand!(view, post)

      assert has_element?(view, ~s|[data-role="item-details"][data-item-id="#{post.id}"]|)
      assert has_element?(view, ~s|[data-role="item-details-note"]|, "read from the source again")

      assert %{
               "source_kind" => "post",
               "source_id" => source_id,
               "title" => title,
               "target_id" => target_id,
               "content_hash" => content_hash,
               "outcome" => "created",
               "extra" => extra
             } = json(view)

      assert {source_id, title, target_id, content_hash} ==
               {post.source_id, post.title, post.target_id, post.content_hash}

      assert Map.keys(extra) |> Enum.sort() == Map.keys(post.extra) |> Enum.sort()
    end

    test "is escaped, and hides a value named like a secret, however deep", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      view = open!(conn, admin, run)
      post = Enum.find(stored(site), &(&1.source_kind == "post"))

      MishkaCmsMigration.record_item!(
        %{
          source_host: post.source_host,
          source_kind: post.source_kind,
          source_id: post.source_id,
          run_id: post.run_id,
          title: "<b>bold</b>",
          target_resource: post.target_resource,
          target_id: post.target_id,
          outcome: post.outcome,
          extra: %{
            "password" => "hunter2",
            "meta" => %{"api_key" => "abc123", "color" => "blue"},
            "tokens" => ["t0k3n"]
          }
        },
        tenant: site.id,
        authorize?: false
      )

      filter!(view, %{"source_kind" => "post"})
      expand!(view, post)

      html = render(view)
      assert html =~ "&lt;b&gt;bold&lt;/b&gt;"
      refute html =~ "<b>bold</b>"
      refute html =~ "hunter2"
      refute html =~ "abc123"
      refute html =~ "t0k3n"

      assert %{"title" => "<b>bold</b>", "extra" => extra} = json(view)

      assert extra == %{
               "password" => "[hidden]",
               "meta" => %{"api_key" => "[hidden]", "color" => "blue"},
               "tokens" => "[hidden]"
             }
    end
  end

  describe "who may open it" do
    setup do
      for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)
      :ok
    end

    test "is refused to an admin without the migration permission", %{
      conn: conn,
      site: site,
      run: run
    } do
      reader = migration_admin!(site, ["admin:dashboard:runtime:redirect"])

      assert {:error, {_redirect, %{to: _elsewhere}}} =
               conn |> signed_in(reader) |> live(MigrationRun.items_path(run))
    end

    test "sends a site admin who types another site's run back to the Migration page", %{
      conn: conn,
      admin: admin
    } do
      other = create_site!()
      theirs = create_run!(other, migration_admin!(other), %{})

      assert {:error, {:live_redirect, %{to: "/admin/dashboard/migration", flash: flash}}} =
               conn |> signed_in(admin) |> live(MigrationRun.items_path(theirs))

      assert flash["error"] =~ "not there"
    end

    test "sends anyone who types an id that is no run's back to the Migration page", %{
      conn: conn,
      admin: admin
    } do
      for id <- [Ecto.UUID.generate(), "nonsense"] do
        assert {:error, {:live_redirect, %{to: "/admin/dashboard/migration"}}} =
                 conn |> signed_in(admin) |> live("/admin/dashboard/migration/runs/#{id}/items")
      end
    end

    test "shows a master the run's own site alone, though another site holds items of the same host",
         %{conn: conn, site: site, run: run} do
      other = create_site!()
      other_admin = migration_admin!(other)

      theirs =
        create_run!(
          other,
          other_admin,
          %{"redirect" => [redirect_row(1, "/a", "/b"), redirect_row(2, "/c", "/d")]},
          %{source_host: run.source_host}
        )

      import!(dry_run!(theirs, other_admin), other_admin)
      master = create_user_with_permissions!(["admin:dashboard:migration"])

      assert total(open!(conn, master, theirs)) == 2
      assert total(open!(conn, master, run)) == length(stored(site))
    end
  end

  describe "the links to the CMS record" do
    test "open the record's place in the admin, and its page on the site where it has one", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      view = open!(conn, admin, run)
      records = Ash.read!(MishkaBlog.BlogPost, tenant: site.id, authorize?: false)
      record = Enum.find(records, &(&1.status == :published))
      post = Enum.find(stored(site), &(&1.target_id == record.id))
      filter!(view, %{"search" => post.title, "source_kind" => "post"})

      hrefs =
        view |> parts(~s|#{@table} [data-role="record-links"] a|) |> LazyHTML.attribute("href")

      assert "/admin/dashboard/blog/posts?posts_search=#{URI.encode_www_form(record.slug)}" in hrefs
      assert "/blog/#{record.slug}" in hrefs
    end

    test "name each kind's own list, found by the record", %{
      conn: conn,
      admin: admin,
      run: run
    } do
      view = open!(conn, admin, run)

      for {kind, list} <- [
            {"page", "/admin/dashboard/runtime/pages?pages_search="},
            {"media", "/admin/dashboard/runtime/medias?search="},
            {"post_redirect", "/admin/dashboard/runtime/redirects?redirects_search="},
            {"category", "/admin/dashboard/blog/collections?collections_search="},
            {"tag", "/admin/dashboard/blog/tags?tags_search="}
          ] do
        filter!(view, %{"source_kind" => kind})

        hrefs = attributes(view, "record-admin", "href")
        assert hrefs != [], kind
        assert Enum.all?(hrefs, &String.starts_with?(&1, list)), "#{kind}: #{inspect(hrefs)}"
      end
    end

    test "are left out for an item with no record and for a record that was deleted", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      view = open!(conn, admin, run)
      items = stored(site)

      skipped = Enum.find(items, &(&1.source_kind == "post_redirect" and is_nil(&1.target_id)))
      filter!(view, %{"source_kind" => "post_redirect", "search" => skipped.source_id})
      assert {"post_redirect", skipped.source_id, "skipped"} in rows(view)
      refute has_element?(view, ~s|#{@table} [data-role="record-links"]|)

      gone = Enum.find(items, &(&1.source_kind == "tag"))
      tag = Ash.get!(MishkaBlog.Tag, gone.target_id, tenant: site.id, authorize?: false)
      Ash.destroy!(tag, tenant: site.id, authorize?: false)

      filter!(view, %{"source_kind" => "tag", "search" => gone.title})
      assert {"tag", gone.source_id, "created"} in rows(view)
      refute has_element?(view, ~s|#{@table} [data-role="record-links"]|)
    end

    test "are left out for a record the admin may not read", %{
      conn: conn,
      site: site,
      run: run
    } do
      reader = migration_admin!(site, ["admin:dashboard:migration"])
      view = open!(conn, reader, run)

      filter!(view, %{"source_kind" => "post"})
      assert rows(view) != []
      refute has_element?(view, ~s|#{@table} [data-role="record-links"]|)
    end
  end
end
