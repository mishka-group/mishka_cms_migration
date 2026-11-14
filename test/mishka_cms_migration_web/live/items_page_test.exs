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
  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0, stub!: 1]

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Admin
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

  # An `:event` row action names its row in `phx-value-values`.
  defp item_action(event, item),
    do: ~s|#{@table} [phx-value-event="#{event}"][phx-value-values*="#{item.id}"]|

  defp item_action!(view, event, item) do
    view |> element(item_action(event, item)) |> render_click()
    settled(view)
  end

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

  defp reason_of(view, item),
    do:
      view
      |> parts(~s|#{@table} [id$="#{item.id}"] [data-role="item-reason"]|)
      |> LazyHTML.text()

  defp last_import_of(view, item),
    do:
      view
      |> parts(~s|#{@table} [id$="#{item.id}"] [data-role="item-outcome"]|)
      |> LazyHTML.text()

  defp plan_of(view, item) do
    view
    |> parts(~s|#{@table} [id$="#{item.id}"] [data-role="item-plan"]|)
    |> LazyHTML.attribute("data-plan")
    |> List.first()
  end

  @map_field "#migration_item_map_form-form_mapped_id"

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

  defp decision_value(view),
    do:
      view
      |> parts(~s|#migration-item-map-modal input[type="hidden"][name="decision"]|)
      |> LazyHTML.attribute("value")

  # gervaz opens a search select through its `.SearchSelect` hook on the select's root, which the
  # browser fires on a click or a Tab into the box.
  defp open_select!(view, scope, field) do
    view
    |> element(~s|#{scope} [phx-hook=".SearchSelect"][phx-value-filter="#{field}"]|)
    |> render_hook("relation_focus", %{"filter" => field})
  end

  # What Decide… offers, once its field is opened, by label.
  defp decision_choices(view) do
    open_select!(view, "#migration-item-map-modal", "decision")

    view
    |> parts(~s|#migration-item-map-modal [role="option"]|)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp decide!(view, choice) do
    open_select!(view, "#migration-item-map-modal", "decision")

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

  # An empty setting is not the site's own, so a second source's tagline has nothing to decide.
  defp empty_tagline!(site) do
    {:ok, _tagline} = MishkaCmsCore.Settings.put("site.tagline", "", site_id: site.id)
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

  # A later run of the same source, now running Polylang Free, whose pages say no language: Our
  # Story (#125) with Our Crew (#127) under it, and their Persian editions, each waiting for a
  # decision, dry run.
  defp polylang_run!(site, admin, run) do
    index =
      "index"
      |> MishkaCmsMigration.Test.WordPress.recorded()
      |> Map.update!("namespaces", &["pll/v1" | &1])
      |> Jason.encode!()

    stub!(%{
      "/wp-json/" => {"application/json", index},
      "/wp-json/wp/v2/pages" => "polylang-pages"
    })

    site |> later_run!(admin, run) |> dry_run!(admin)
  end

  defp page(site, source_id),
    do: Enum.find(stored(site), &({&1.source_kind, &1.source_id} == {"page", source_id}))

  # Our Crew decided and imported alone, so it waits for Our Story.
  defp crew_waits!(site, admin, later) do
    crew = page(site, "127")
    MishkaCmsMigration.decide_item!(crew, "import", actor: admin, tenant: site.id)
    MishkaCmsMigration.import_items!(later, [crew.id], actor: admin, tenant: site.id)
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
    item!(crew)
  end

  # The expanded row's branch, each item as `{source id, where it stands}`, the top one first.
  defp branch(view) do
    nodes = parts(view, ~s|[data-role="item-branch-node"]|)

    Enum.zip(
      LazyHTML.attribute(nodes, "data-source-id"),
      LazyHTML.attribute(nodes, "data-standing")
    )
  end

  defp branch_click!(view, selector) do
    view |> element(selector) |> render_click()
    settled(view)
  end

  defp panel_settled(view) do
    settled(view)
    settled(view)
  end

  # The core refuses every page from now on, as a deployment with hand-written templates off does,
  # so a page's import fails with the core's sentence.
  defp pages_code_off! do
    previous = Application.fetch_env(:mishka_cms_core, :page_code)
    Application.put_env(:mishka_cms_core, :page_code, :off)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:mishka_cms_core, :page_code, value)
        :error -> Application.delete_env(:mishka_cms_core, :page_code)
      end
    end)
  end

  # How many UPDATEs of the items the repository runs from now on, in any process, read once.
  defp updates_counted do
    test = self()
    handler = "items-updates-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:mishka_cms_migration, :repo, :query],
      &__MODULE__.items_update/4,
      {test, handler}
    )

    fn ->
      :telemetry.detach(handler)
      counted(handler, 0)
    end
  end

  @doc false
  def items_update(_event, _measurements, %{query: query}, {test, handler}) do
    if query =~ ~s|UPDATE "mishka_cms_migration_items"|, do: send(test, {:items_update, handler})
  end

  defp counted(handler, count) do
    receive do
      {:items_update, ^handler} -> counted(handler, count + 1)
    after
      0 -> count
    end
  end

  describe "the cancelled run alert" do
    test "is between the filters and the table of a cancelled run, and not on a run that is done",
         %{conn: conn, site: site, admin: admin, run: run} do
      refute has_element?(open!(conn, admin, run), @table <> " [role=\"alert\"]", "cancelled")

      cancelled = MishkaCmsMigration.cancel_run!(run, actor: admin, tenant: site.id)
      view = open!(conn, admin, cancelled)

      assert has_element?(view, @table <> " [role=\"alert\"]", "This run was cancelled.")
      assert has_element?(view, @table <> " [role=\"alert\"]", "WordPress password")
      assert has_element?(view, @table <> " [role=\"alert\"]", "Start a New import")
    end
  end

  describe "a run that put everything in one language" do
    test "says so in one line, and a run that kept the source's languages says nothing",
         %{conn: conn, site: site, admin: admin, run: run} do
      refute has_element?(open!(conn, admin, run), @table <> " [role=\"alert\"]", "no language")

      one =
        MishkaCmsMigration.create_run!(
          %{
            source: "wordpress",
            source_host: "other.example.com",
            connection: %{"url" => "http://localhost:8089", "user" => "admin"},
            secret: "app password",
            options: %{one_language: "en"}
          },
          actor: admin,
          tenant: site.id
        )

      view = open!(conn, admin, one)

      assert has_element?(view, @table <> " [role=\"alert\"]", "puts every item with no language")
      assert has_element?(view, @table <> " [role=\"alert\"]", "English")
    end
  end

  describe "the site's own settings" do
    test "are listed like any item, and a row's Leave out and Bring back reach them",
         %{conn: conn, site: site, admin: admin, run: run} do
      view = open!(conn, admin, run)
      filter!(view, %{"source_kind" => "setting"})

      icon = Enum.find(stored(site), &(&1.source_kind == "setting" and &1.source_id == "icon"))

      assert Enum.sort(rows(view)) |> Enum.map(&elem(&1, 1)) == [
               "app_icon",
               "icon",
               "logo",
               "tagline",
               "title"
             ]

      row_action!(view, "leave_out", icon)
      assert %{left_out: true} = item!(icon)
      assert plan_of(view, icon) == "left_out"

      row_action!(view, "bring_back", icon)
      assert %{left_out: false} = item!(icon)
    end
  end

  describe "the language addresses warning" do
    @warning ~s|[data-role="language-urls-warning"]|

    test "is on the head of a site that gives every language a prefix, and not on any other",
         %{conn: conn, site: site, admin: admin, run: run} do
      refute has_element?(open!(conn, admin, run), @warning)

      MishkaCmsCore.Settings.put("site.language_urls", "prefix_all",
        site_id: site.id,
        category: "general"
      )

      view = open!(conn, admin, run)

      assert has_element?(view, ~s|#{@warning}[data-cause="prefix_all"]|)
      assert has_element?(view, ~s|#{@warning} [role="alert"]|, "Tip:")
      assert has_element?(view, ~s|#{@warning} [role="alert"]|, "Suggestion:")
      refute has_element?(view, ~s|#{@warning} [data-role="language-editions"]|)
    end

    test "is on the head of a run whose source runs a language plugin, and says how its translations are imported",
         %{conn: conn, site: site, admin: admin, run: run} do
      body =
        "index"
        |> MishkaCmsMigration.Test.WordPress.recorded()
        |> Map.update!("namespaces", &["wpml/v1" | &1])
        |> Jason.encode!()

      stub!(%{"/wp-json/" => {"application/json", body}})
      later = later_run!(site, admin, run)

      view = open!(conn, admin, later)

      assert has_element?(view, ~s|#{@warning}[data-cause="wpml"]|)
      assert has_element?(view, ~s|#{@warning} [data-role="language-editions"]|, "export file")
      assert has_element?(view, ~s|#{@warning}|, "press Run again and Import")
    end

    test "says plainly that Polylang Free shares no language over REST", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      body =
        "index"
        |> MishkaCmsMigration.Test.WordPress.recorded()
        |> Map.update!("namespaces", &["pll/v1" | &1])
        |> Jason.encode!()

      stub!(%{"/wp-json/" => {"application/json", body}})
      view = open!(conn, admin, later_run!(site, admin, run))

      assert has_element?(view, ~s|#{@warning}[data-cause="polylang"]|)

      assert has_element?(
               view,
               ~s|#{@warning} [data-role="language-editions"]|,
               "Polylang Free doesn't share languages over REST: upload the WordPress export file to bring translations."
             )
    end
  end

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

    test "fits its columns beside the sidebar on a 1280px screen, so Actions covers none of them",
         %{conn: conn, admin: admin, run: run} do
      view = open!(conn, admin, run)

      [style] = view |> parts(~s|[style*="grid-template-columns"]|) |> LazyHTML.attribute("style")

      tracks =
        ~r/(?:minmax\((\d+)px|(?<![\w(,])(\d+)px)/
        |> Regex.scan(style, capture: :all_but_first)
        |> Enum.map(fn parts ->
          parts |> Enum.reject(&(&1 == "")) |> hd() |> String.to_integer()
        end)

      # 1280px less the 266px sidebar and the page's padding.
      assert Enum.sum(tracks) <= 900

      # Wide enough for "Comments" or "Stylesheets" beside its icon, and for the "CMS record"
      # and "Updated" headers with their sort arrow, so none of them is cut.
      [_checkbox, _expand, kind, _title, _plan, _result, record, updated, _actions] = tracks
      assert kind >= 126
      assert record >= 90
      assert updated >= 102
    end

    test "says in words why an item was skipped", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      view = open!(conn, admin, run)

      # A kind whose skipped items all share one reason, so whichever of them the page shows first
      # says it.
      {kind, [reason]} =
        for(%{outcome: :skipped, reason: reason} = item <- stored(site), reason, do: item)
        |> Enum.group_by(& &1.source_kind, & &1.reason)
        |> Enum.map(fn {kind, reasons} -> {kind, Enum.uniq(reasons)} end)
        |> Enum.sort()
        |> Enum.find(&match?({_kind, [_one]}, &1))

      filter!(view, %{"source_kind" => kind, "outcome" => "skipped"})

      assert view |> texts("item-reason") |> Enum.uniq() == [MigrationRun.reason_label(reason)]
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

    test "says what the last dry run would do before an import, and what it planned once an import met the item",
         %{conn: conn, site: site, admin: admin, run: run} do
      tag = Enum.find(stored(site), &(&1.source_kind == "tag" and &1.plan == :created))
      assert tag.outcome in [:created, :updated, :skipped]

      for template <- ["", "&items_template=item_tree"] do
        view = open!(conn, admin, run, "?items_filter_source_kind=tag" <> template)

        plan =
          view
          |> parts(
            ~s|[id$="#{tag.id}"] [data-role="item-plan"], | <>
              ~s|[data-item-id="#{tag.id}"] > div [data-role="item-plan"]|
          )
          |> LazyHTML.text()

        refute plan =~ MigrationItem.plan_word(:created)
        assert plan =~ MigrationItem.planned_word(:created)
      end

      fresh =
        site
        |> create_run!(admin, %{"redirect" => [redirect_row(1, "/a", "/b")]})
        |> dry_run!(admin)

      view = open!(conn, admin, fresh)
      assert texts(view, "item-plan") |> Enum.join() =~ MigrationItem.plan_word(:created)
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
      assert has_element?(view, "#flash-success", "Left out: #{tag.title}.")
      assert plan_of(view, tag) == "left_out"
      refute has_element?(view, row_button("leave_out", tag))
      settled(other_tab)
      assert plan_of(other_tab, tag) == "left_out"

      Admin.clear_flashes(view)
      row_action!(view, "bring_back", tag)

      assert %{left_out: false} = item!(tag)
      assert has_element?(view, "#flash-success", "Brought back: #{tag.title}.")
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
      assert has_element?(view, "#flash-info", "Not done.")
      refute has_element?(view, "#flash-error")
      Admin.clear_flashes(view)

      pick!(view, tag)
      assert bulk!(view, "leave_out") =~ "is running"
      assert has_element?(view, "#flash-info", "Not done.")
      refute has_element?(view, "#flash-error")

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

  describe "Dry run this item and Import this item" do
    test "run the run's job for the item alone, draw its row again live, and leave the rest as it was",
         %{conn: conn, site: site, admin: admin, run: run} do
      tag = Enum.find(stored(site), &({&1.source_kind, &1.source_id} == {"tag", "13"}))
      others = Enum.reject(stored(site), &(&1.id == tag.id))
      view = open!(conn, admin, run)
      filter!(view, %{"source_kind" => "tag"})

      assert plan_of(view, tag) == "created"
      assert has_element?(view, "#{item_action("import_item", tag)}[data-confirm]")

      assert item_action!(view, "dry_run_item", tag) =~ "Dry run of the item started."
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
      settled(view)

      assert plan_of(view, tag) == "skipped"
      assert item!(tag).plan_reason == "unchanged"

      assert item_action!(view, "import_item", tag) =~ "Import of the item started."
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
      settled(view)

      assert %{outcome: :skipped, reason: "unchanged", run_id: run_id} = item!(tag)
      assert run_id == run.id
      assert Enum.reject(stored(site), &(&1.id == tag.id)) == others
      assert MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id).status == :done
    end

    test "say what came of the item once its job settled it, each time: a page under one that waits names that page, in a flash and live in its row",
         %{conn: conn, site: site, admin: admin, run: run} do
      index =
        "index"
        |> MishkaCmsMigration.Test.WordPress.recorded()
        |> Map.update!("namespaces", &["pll/v1" | &1])
        |> Jason.encode!()

      stub!(%{
        "/wp-json/" => {"application/json", index},
        "/wp-json/wp/v2/pages" => "polylang-pages"
      })

      later = site |> later_run!(admin, run) |> dry_run!(admin)
      crew = Enum.find(stored(site), &({&1.source_kind, &1.source_id} == {"page", "127"}))
      MishkaCmsMigration.decide_item!(crew, "import", actor: admin, tenant: site.id)
      view = open!(conn, admin, later, "?items_filter_source_kind=page")

      for _click <- 1..2 do
        item_action!(view, "import_item", crew)
        assert Admin.flashes(view) =~ "Import of the item started."
        assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
        settled(view)

        assert Admin.flashes(view) =~ "Our Crew"
        assert Admin.flashes(view) =~ "Skipped"
        assert Admin.flashes(view) =~ "Our Story (#125) needs your decision"
        assert reason_of(view, crew) =~ "Our Story (#125) needs your decision"
        Admin.clear_flashes(view)
      end

      item_action!(view, "dry_run_item", crew)
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
      settled(view)

      assert Admin.flashes(view) =~ "Dry run of Our Crew"
      assert Admin.flashes(view) =~ "Our Story (#125) needs your decision"
    end

    test "are not offered on a run whose password an earlier release cleared, and say why when asked",
         %{conn: conn, site: site, admin: admin, run: run} do
      MishkaCmsMigration.Repo.query!(
        "UPDATE mishka_cms_migration_runs SET connection_secret = NULL WHERE id = $1",
        [Ecto.UUID.dump!(run.id)]
      )

      tag = Enum.find(stored(site), &(&1.source_kind == "tag"))
      view = open!(conn, admin, run)
      filter!(view, %{"source_kind" => "tag"})

      refute has_element?(view, item_action("dry_run_item", tag))
      refute has_element?(view, item_action("import_item", tag))
      assert has_element?(view, row_button("leave_out", tag))

      view
      |> with_target(@table)
      |> render_click("custom_event", %{
        "event" => "dry_run_item",
        "values" => Jason.encode!(%{"id" => tag.id})
      })

      assert settled(view) =~
               "This run no longer holds its WordPress password. Start a New import."

      assert item!(tag) == tag
    end

    test "Import the picked items imports the picked rows in one job", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      [first, second | _] =
        stored(site) |> Enum.filter(&(&1.source_kind == "tag")) |> Enum.sort_by(& &1.source_id)

      view = open!(conn, admin, run)
      filter!(view, %{"source_kind" => "tag"})
      pick!(view, first)
      pick!(view, second)

      assert bulk!(view, "import_items") =~ "Import of 2 items started."
      Admin.clear_flashes(view)
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
      settled(view)

      assert Enum.map([first, second], &item!(&1).reason) == ["unchanged", "unchanged"]

      flash = Admin.flashes(view)
      assert flash =~ ~r/\AImport of 2 items: .+ skipped: Unchanged\.\z/
      assert flash =~ first.title
      assert flash =~ second.title
    end

    test "say in a notice, not as a failure, that they did not start while another run of the site is running, and are not offered on an item left out",
         %{conn: conn, site: site, admin: admin, run: run} do
      [tag, left_out | _] = Enum.filter(stored(site), &(&1.source_kind == "tag"))
      view = open!(conn, admin, run)
      filter!(view, %{"source_kind" => "tag"})

      row_action!(view, "leave_out", left_out)
      refute has_element?(view, item_action("dry_run_item", left_out))
      refute has_element?(view, item_action("import_item", left_out))

      site
      |> later_run!(admin, run)
      |> MishkaCmsMigration.start_dry_run!(actor: admin, tenant: site.id)

      for event <- ["import_item", "dry_run_item"] do
        Admin.clear_flashes(view)
        item_action!(view, event, tag)

        assert has_element?(view, "#flash-info", "Not started.")
        assert has_element?(view, "#flash-info", "still waiting or running")
        refute has_element?(view, "#flash-error")
      end

      Admin.clear_flashes(view)
      pick!(view, tag)
      bulk!(view, "import_items")

      assert has_element?(view, "#flash-info", "Not started.")
      refute has_element?(view, "#flash-error")
      assert item!(tag) == tag
      assert MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id).status == :done
    end

    test "a second Import this item while the first one's job runs starts nothing, and says so in a notice",
         %{conn: conn, site: site, admin: admin, run: run} do
      tag = Enum.find(stored(site), &({&1.source_kind, &1.source_id} == {"tag", "13"}))
      view = open!(conn, admin, run)
      filter!(view, %{"source_kind" => "tag"})

      assert item_action!(view, "import_item", tag) =~ "Import of the item started."
      item_action!(view, "import_item", tag)

      assert has_element?(view, "#flash-info", "Not started.")
      assert has_element?(view, "#flash-info", "An import of this run is running.")
      refute has_element?(view, "#flash-error")

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
      settled(view)

      assert has_element?(view, "#flash-warning", "Import of #{tag.title}: Skipped.")
      assert %{outcome: :skipped, reason: "unchanged"} = item!(tag)
    end
  end

  describe "Decide…" do
    test "a setting the site has its own of needs a decision, and Decide… keeps the admin's choice",
         %{conn: conn, site: site, admin: admin} do
      empty_tagline!(site)
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

    test "a redirect deleted for good in the CMS says so above Import it again and Leave it out",
         %{conn: conn, site: site, admin: admin, run: run} do
      item =
        Enum.find(stored(site), &(&1.source_kind == "post_redirect" and is_binary(&1.target_id)))

      MishkaCmsCore.Runtime.Redirect
      |> Ash.get!(item.target_id, tenant: site.id, authorize?: false)
      |> Ash.destroy!(action: :permanent_destroy, tenant: site.id, authorize?: false)

      later = site |> later_run!(admin, run) |> dry_run!(admin)

      view =
        open!(
          conn,
          admin,
          later,
          "?items_filter_source_kind=post_redirect&items_filter_plan=undecided"
        )

      assert plan_of(view, item) == "undecided"
      row_action!(view, "decide", item)

      modal = view |> parts("#migration-item-map-modal") |> LazyHTML.text()
      assert modal =~ "This redirect was deleted in Mishka CMS after it was imported"
      refute modal =~ "already has something in its place"

      assert decision_choices(view) == ["Import it again", "Leave it out"]
    end

    test "Import this item, once confirmed, imports an item that waits for a decision, and one left out deleted, with a flash and its outcome",
         %{conn: conn, site: site, admin: admin, run: run} do
      item =
        Enum.find(stored(site), &(&1.source_kind == "post_redirect" and is_binary(&1.target_id)))

      MishkaCmsCore.Runtime.Redirect
      |> Ash.get!(item.target_id, tenant: site.id, authorize?: false)
      |> Ash.destroy!(action: :permanent_destroy, tenant: site.id, authorize?: false)

      site |> later_run!(admin, run) |> dry_run!(admin)

      view =
        open!(
          conn,
          admin,
          run,
          "?items_filter_source_kind=post_redirect&items_filter_search=#{item.source_id}"
        )

      assert has_element?(view, "#{item_action("import_item", item)}[data-confirm]")
      assert item_action!(view, "import_item", item) =~ "Import of the item started."
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
      assert %{outcome: :undecided, reason: "deleted_in_cms"} = item!(item)

      settled(view)
      row_action!(view, "decide", item)
      decide!(view, "keep")

      assert item_action!(view, "import_item", item) =~ "Import of the item started."
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
      assert %{outcome: :skipped, reason: "target_missing"} = item!(item)
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

    test "the Plan filter's Decided lists the items whose waiting decision is answered, and not the ones still waiting",
         %{conn: conn, site: site, admin: admin, run: run} do
      [footer, navigation] =
        for id <- ["23", "navigation-105"],
            do: Enum.find(stored(site), &({&1.source_kind, &1.source_id} == {"menu", id}))

      view = open!(conn, admin, run, "?items_filter_source_kind=menu")

      filter!(view, %{"plan" => "decided"})
      assert total(view) == 0

      filter!(view, %{"plan" => ""})
      row_action!(view, "decide", footer)
      decide!(view, "footer")

      filter!(view, %{"plan" => "decided"})
      assert [{"menu", "23", _outcome}] = rows(view)

      filter!(view, %{"plan" => "undecided"})
      assert "navigation-105" in Enum.map(rows(view), &elem(&1, 1))
      assert navigation.plan == :undecided
    end

    test "Decide… on a post whose scripts an admin decided opens with that choice picked", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      post = Enum.find(stored(site), &(&1.source_kind == "post" and &1.plan == :created))

      MigrationItem
      |> Ash.Changeset.for_create(:record_outcome, %{
        source_host: post.source_host,
        source_kind: "post",
        source_id: post.source_id,
        run_id: run.id,
        outcome: :undecided,
        reason: "scripts: script, onclick on a"
      })
      |> Ash.create!(tenant: site.id, authorize?: false)

      view = open!(conn, admin, run, "?items_filter_source_kind=post")
      row_action!(view, "decide", post)
      decide!(view, "import")
      assert %{decisions: %{"scripts" => "import"}} = item!(post)

      row_action!(view, "decide", post)
      assert decision_value(view) == ["import"]
    end

    test "Decide… on a decided item opens with the current choice picked", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      footer = Enum.find(stored(site), &({&1.source_kind, &1.source_id} == {"menu", "23"}))
      view = open!(conn, admin, run, "?items_filter_source_kind=menu")

      row_action!(view, "decide", footer)
      assert decision_value(view) in [[], [""]]
      decide!(view, "footer")

      row_action!(view, "decide", footer)
      assert decision_value(view) == ["footer"]
    end

    test "the Plan filter's Needs your decision lists an item only its last import left waiting, and Would create does not",
         %{conn: conn, site: site, admin: admin, run: run} do
      tag = Enum.find(stored(site), &(&1.source_kind == "tag" and &1.plan == :created))

      MigrationItem
      |> Ash.Changeset.for_create(:record_outcome, %{
        source_host: tag.source_host,
        source_kind: "tag",
        source_id: tag.source_id,
        run_id: run.id,
        outcome: :undecided,
        reason: "same_file: Hero image"
      })
      |> Ash.create!(tenant: site.id, authorize?: false)

      view = open!(conn, admin, run, "?items_filter_source_kind=tag")
      assert plan_of(view, tag) == "undecided"

      filter!(view, %{"plan" => "undecided"})
      assert {"tag", tag.source_id, "undecided"} in rows(view)

      filter!(view, %{"plan" => "created"})
      refute Enum.any?(rows(view), &(elem(&1, 1) == tag.source_id))
    end

    test "deciding one item tells the runs of its source, with what waits and what was decided now",
         %{conn: conn, site: site, admin: admin, run: run} do
      footer = Enum.find(stored(site), &({&1.source_kind, &1.source_id} == {"menu", "23"}))

      waiting =
        MigrationRun.fetch(run.id, admin) |> elem(1) |> Ash.load!([:decisions], actor: admin)

      assert %{decided: 0, waiting: before} = waiting.decisions

      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "migration_run:#{site.id}:updated")
      view = open!(conn, admin, run, "?items_filter_source_kind=menu")
      row_action!(view, "decide", footer)
      decide!(view, "footer")

      assert_receive %Phoenix.Socket.Broadcast{
        payload: %Ash.Notifier.Notification{data: %{id: id, decisions: decisions}}
      }

      assert id == run.id
      assert decisions == %{decided: 1, waiting: before - 1}
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

    test "an import that waited for a decision reads as waited once the item is decided or left out, as its Plan says",
         %{conn: conn, site: site, admin: admin, run: run} do
      [footer, navigation] =
        for id <- ["23", "navigation-105"],
            do: Enum.find(stored(site), &({&1.source_kind, &1.source_id} == {"menu", id}))

      view = open!(conn, admin, run, "?items_filter_source_kind=menu")

      for menu <- [footer, navigation] do
        assert %{outcome: :undecided} = menu
        assert last_import_of(view, menu) =~ "Needs your decision"
      end

      row_action!(view, "decide", footer)
      decide!(view, "footer")

      assert plan_of(view, footer) == "decided"
      refute last_import_of(view, footer) =~ "Needs your decision"
      assert reason_of(view, footer) =~ "Footer links"

      row_action!(view, "leave_out", navigation)

      refute last_import_of(view, navigation) =~ "Needs your decision"
      assert reason_of(view, navigation) =~ "Left out by you"
      assert %{outcome: :undecided} = item!(navigation)
    end

    test "the picked rows are decided together, and one with nothing to decide is left as it is",
         %{conn: conn, site: site, admin: admin} do
      empty_tagline!(site)
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

  describe "Where it sits" do
    test "an item that waits for its parent names its parents in its row and its expanded row, where the parent is decided and the branch imported, parents first",
         %{conn: conn, site: site, admin: admin, run: run} do
      later = polylang_run!(site, admin, run)
      crew = crew_waits!(site, admin, later)
      story = page(site, "125")
      assert crew.reason == "parent_undecided: Our Story (#125)"

      view = open!(conn, admin, later, "?items_filter_source_kind=page")

      assert view
             |> parts(~s|#{@table} [id$="#{crew.id}"] [data-role="item-waits-node"]|)
             |> LazyHTML.attribute("data-source-id") == ["125"]

      expand!(view, crew)

      assert has_element?(
               view,
               ~s|[data-role="item-branch"][data-waits="true"] [data-role="item-branch-waits"]|,
               "Our Story (#125) needs your decision"
             )

      assert branch(view) == [{"125", "undecided"}, {"127", "decided"}]
      refute has_element?(view, ~s|[data-role="item-branch-import-all"]|)

      branch_click!(
        view,
        ~s|[data-role="item-branch-node"][data-source-id="125"] [data-role="item-branch-decide"][data-choice="import"]|
      )

      assert Admin.flashes(view) =~ "Decided"
      assert %{decisions: %{"language_unknown" => "import"}} = item!(story)
      assert item!(crew).reason == "parent_undecided: Our Story (#125)"
      assert branch(view) == [{"125", "decided"}, {"127", "decided"}]
      assert has_element?(view, ~s|[data-role="item-branch-waits"]|, "is not imported yet")
      refute has_element?(view, ~s|[data-role="item-branch-waits"]|, "needs your decision")

      Admin.clear_flashes(view)
      branch_click!(view, ~s|[data-role="item-branch-import-all"]|)
      assert Admin.flashes(view) =~ "Import of 2 items started."
      Admin.clear_flashes(view)
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
      settled(view)

      assert Admin.flashes(view) =~ "Import of 2 items: Our Story and Our Crew created."
      assert %{outcome: :created, target_id: story_page} = item!(story)

      assert %{title: "Our Story"} =
               Ash.get!(MishkaCmsCore.Runtime.Page, story_page,
                 tenant: site.id,
                 authorize?: false
               )

      assert %{outcome: :created, reason: nil} = item!(crew)
      assert branch(view) == [{"125", "imported"}, {"127", "imported"}]
      refute has_element?(view, ~s|#{@table} [id$="#{crew.id}"] [data-role="item-waits-node"]|)
    end

    test "Import the branch says every item's result in one flash once its job is done, a failed parent first, and the open branch follows live",
         %{conn: conn, site: site, admin: admin, run: run} do
      later = polylang_run!(site, admin, run)
      crew = crew_waits!(site, admin, later)
      MishkaCmsMigration.decide_item!(page(site, "125"), "import", actor: admin, tenant: site.id)
      view = open!(conn, admin, later, "?items_filter_source_kind=page")
      expand!(view, crew)
      pages_code_off!()

      branch_click!(view, ~s|[data-role="item-branch-import-all"]|)
      assert Admin.flashes(view) =~ "Import of 2 items started."
      assert has_element?(view, ~s|[data-role="item-branch-busy"]|)
      assert has_element?(view, ~s|[data-role="item-branch-import-all"][disabled]|)

      Admin.clear_flashes(view)
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
      settled(view)

      assert has_element?(view, "#flash-error")

      assert Admin.flashes(view) =~
               ~r/Import of 2 items: Our Story failed: .+; Our Crew skipped: its parent was not imported\./

      refute Admin.flashes(view) =~ "Import of Our Crew"

      assert branch(view) == [{"125", "decided"}, {"127", "decided"}]
      assert has_element?(view, ~s|[data-source-id="125"] [data-role="item-branch-failed"]|)
      assert has_element?(view, ~s|[data-role="item-branch-node"][data-source-id="125"]|, "ready")
      refute has_element?(view, ~s|[data-role="item-branch-busy"]|)
      assert %{outcome: :skipped, reason: "parent_missing: Our Story (#125)"} = item!(crew)
    end

    test "marks the recommended choice, says to decide the parents first, and asks once per click",
         %{conn: conn, site: site, admin: admin, run: run} do
      later = polylang_run!(site, admin, run)
      crew = crew_waits!(site, admin, later)
      view = open!(conn, admin, later, "?items_filter_source_kind=page")
      expand!(view, crew)

      assert has_element?(view, ~s|[data-role="item-branch-node"][data-source-id="127"]|, "ready")
      assert has_element?(view, ~s|[data-role="item-branch-decide-parents"]|)

      assert view
             |> parts(~s|[data-source-id="125"] [data-role="item-branch-decide"]|)
             |> LazyHTML.attribute("data-recommended") == ["true", "false"]

      assert view
             |> parts(~s|[data-role="item-branch"] [data-confirm]|)
             |> LazyHTML.attribute("phx-disable-with")
             |> Enum.all?(&(&1 == ""))

      branch_click!(
        view,
        ~s|[data-source-id="125"] [data-role="item-branch-decide"][data-recommended="true"]|
      )

      refute has_element?(view, ~s|[data-role="item-branch-decide-parents"]|)
      assert has_element?(view, ~s|[data-role="item-branch-import-all"][phx-disable-with]|)
    end

    test "a decision or an import from the branch while another run of the site is running says in a notice that nothing changed",
         %{conn: conn, site: site, admin: admin, run: run} do
      later = polylang_run!(site, admin, run)
      crew = crew_waits!(site, admin, later)
      view = open!(conn, admin, later, "?items_filter_source_kind=page")
      expand!(view, crew)

      site
      |> later_run!(admin, later)
      |> MishkaCmsMigration.start_dry_run!(actor: admin, tenant: site.id)

      branch_click!(
        view,
        ~s|[data-role="item-branch-node"][data-source-id="125"] [data-role="item-branch-decide"][data-choice="import"]|
      )

      assert has_element?(view, "#flash-info", "Not decided.")
      assert has_element?(view, "#flash-info", "is running")
      refute has_element?(view, "#flash-error")
      assert %{decisions: %{}} = item!(page(site, "125"))

      Admin.clear_flashes(view)
      branch_click!(view, ~s|[data-role="item-branch-import-anyway"]|)

      assert has_element?(view, "#flash-info", "Not started.")
      refute has_element?(view, "#flash-error")
      assert item!(crew).decisions == %{"language_unknown" => "import"}
    end

    test "Import anyway writes the item without its parent and says so; the parent waits as it was",
         %{conn: conn, site: site, admin: admin, run: run} do
      later = polylang_run!(site, admin, run)
      crew = crew_waits!(site, admin, later)
      view = open!(conn, admin, later, "?items_filter_source_kind=page")
      expand!(view, crew)

      branch_click!(view, ~s|[data-role="item-branch-import-anyway"]|)
      assert Admin.flashes(view) =~ "Import of the item started."
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
      settled(view)

      assert Admin.flashes(view) =~ "Import of Our Crew: Created."
      assert Admin.flashes(view) =~ "without its parent Our Story (#125)"
      assert %{outcome: :created, reason: "without_parent: Our Story (#125)"} = item!(crew)
      assert %{target_id: nil, decisions: %{}} = item!(page(site, "125"))
      assert branch(view) == [{"125", "undecided"}, {"127", "imported"}]

      wait = ~s|[data-role="item-branch-wait"]|
      assert view |> parts(wait) |> LazyHTML.attribute("data-confirm") |> hd() =~ "stays where"

      Admin.clear_flashes(view)
      branch_click!(view, wait)

      assert Admin.flashes(view) =~ "It waits for its parent again"
      assert Admin.flashes(view) =~ "stays where it is"
      refute Admin.flashes(view) =~ "failed"
      assert %{decisions: %{"parent_missing" => "keep"}, target_id: page_id} = item!(crew)

      assert %{title: "Our Crew"} =
               Ash.get!(MishkaCmsCore.Runtime.Page, page_id, tenant: site.id, authorize?: false)

      refute has_element?(view, wait)
    end

    test "a run broadcast that does not move the status, arriving after the import finished, leaves the branch's buttons enabled",
         %{conn: conn, site: site, admin: admin, run: run} do
      later = polylang_run!(site, admin, run)
      crew = crew_waits!(site, admin, later)
      view = open!(conn, admin, later, "?items_filter_source_kind=page")
      expand!(view, crew)

      branch_click!(view, ~s|[data-role="item-branch-import-anyway"]|)
      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "migration_run:#{site.id}:updated")
      MigrationRun.refresh_decisions(later, admin)
      run_id = later.id

      assert_receive %Phoenix.Socket.Broadcast{
                       payload: %Ash.Notifier.Notification{
                         data: %MigrationRun{id: ^run_id, status: :importing}
                       }
                     } = stale

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :migration)
      settled(view)
      send(view.pid, stale)
      settled(view)

      refute has_element?(view, ~s|[data-role="item-branch-busy"]|)
      assert has_element?(view, ~s|[data-role="item-branch-wait"]:not([disabled])|)
    end

    test "an item whose parent the list does not hold is drawn under it in the Map view, which says it waits",
         %{conn: conn, site: site, admin: admin, run: run} do
      later = polylang_run!(site, admin, run)
      crew_waits!(site, admin, later)

      view =
        open!(
          conn,
          admin,
          later,
          "?items_template=item_tree&items_filter_source_kind=page&items_filter_outcome=skipped"
        )

      assert has_element?(
               view,
               ~s|[data-role="item-tree-node"][data-ghost="true"][data-source-id="125"] [data-role="item-tree-node"][data-source-id="127"]|
             )

      assert has_element?(
               view,
               ~s|[data-role="item-tree-node"][data-source-id="127"] [data-role="item-tree-waits"]|,
               "Our Story (#125)"
             )

      refute has_element?(
               view,
               ~s|[data-role="item-tree-node"][data-ghost="true"] > div input[name="select_row"]|
             )

      assert has_element?(
               view,
               ~s|[data-role="item-tree-node"][data-source-id="127"] > div input[name="select_row"]|
             )
    end
  end

  describe "the Decisions panel" do
    test "groups what waits for a decision, and its recommended choice decides a whole group at once",
         %{conn: conn, site: site, admin: admin, run: run} do
      later = polylang_run!(site, admin, run)
      {:ok, groups} = MigrationItem.waiting_groups(later, admin)

      waiting =
        groups
        |> Enum.filter(&(&1.conflict == "language_unknown"))
        |> Enum.map(& &1.count)
        |> Enum.sum()

      assert waiting >= 4
      view = open!(conn, admin, later)
      panel_settled(view)

      group = ~s|[data-role="decision-group"][data-conflict="language_unknown"]|
      assert view |> parts(group) |> LazyHTML.attribute("data-count") == [to_string(waiting)]

      assert view
             |> parts(group <> ~s| [data-role="decision-choice"][data-recommended="true"]|)
             |> LazyHTML.attribute("data-choice") == ["import"]

      assert view
             |> parts(group <> ~s| [data-role="decision-choice"]|)
             |> LazyHTML.attribute("phx-disable-with")
             |> Enum.all?(&(&1 == ""))

      updates = updates_counted()

      view
      |> element(group <> ~s| [data-role="decision-choice"][data-choice="import"]|)
      |> render_click()

      panel_settled(view)

      assert updates.() == 1
      assert Admin.flashes(view) =~ "#{waiting} items decided."
      assert {:ok, rest} = MigrationItem.waiting_groups(later, admin)
      refute Enum.any?(rest, &(&1.conflict == "language_unknown"))
      assert %{decisions: %{"language_unknown" => "import"}} = page(site, "128")
      assert plan_of(view, page(site, "128")) == "decided"
      refute has_element?(view, group)
    end

    test "names each card's conflict in words, not by its code",
         %{conn: conn, site: site, admin: admin, run: run} do
      created = Enum.filter(stored(site), &(&1.plan == :created))

      waiting =
        for {reason, item} <-
              Enum.zip(
                [
                  "draft_pages: Team",
                  "same_file: Hero image",
                  "language_urls: polylang",
                  "scripts: script"
                ],
                created
              ) do
          MigrationItem
          |> Ash.Changeset.for_create(:record_outcome, %{
            source_host: item.source_host,
            source_kind: item.source_kind,
            source_id: item.source_id,
            run_id: run.id,
            outcome: :undecided,
            reason: reason
          })
          |> Ash.create!(tenant: site.id, authorize?: false)

          reason |> String.split(": ") |> hd()
        end

      assert length(waiting) == 4
      view = open!(conn, admin, run)
      panel_settled(view)

      for conflict <- waiting do
        [title] =
          view
          |> parts(~s|[data-role="decision-group"][data-conflict="#{conflict}"] h3|)
          |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

        assert title == MigrationRun.reason_label(conflict)
        refute title == conflict
      end
    end

    test "says so in one line once nothing waits any more, instead of vanishing",
         %{conn: conn, site: site, admin: admin, run: run} do
      later = polylang_run!(site, admin, run)
      view = open!(conn, admin, later)
      panel_settled(view)
      refute has_element?(view, ~s|[data-role="decisions-done"]|)

      for _group <- 1..10, has_element?(view, ~s|[data-role="decision-group"]|) do
        view
        |> element(~s|[data-role="decision-group"]:first-child [data-recommended="true"]|)
        |> render_click()

        panel_settled(view)
      end

      assert {:ok, []} = MigrationItem.waiting_groups(later, admin)
      refute has_element?(view, ~s|[data-role="decisions"]|)

      assert has_element?(
               view,
               ~s|[data-role="decisions-done"]|,
               "Nothing needs your decision now."
             )
    end

    test "Advanced decides only the rules that are on, narrowed by a title, once its counts are previewed",
         %{conn: conn, site: site, admin: admin, run: run} do
      later = polylang_run!(site, admin, run)
      {:ok, groups} = MigrationItem.waiting_groups(later, admin)
      view = open!(conn, admin, later)
      panel_settled(view)

      view |> element(~s|[data-role="decisions-mode"][data-mode="advanced"]|) |> render_click()

      rules =
        Map.new(groups, fn group ->
          {"#{group.kind}:#{group.conflict}",
           %{
             "on" => to_string(group.kind == "page" and group.conflict == "language_unknown"),
             "choice" => "import"
           }}
        end)

      form = element(view, ~s|[data-role="decision-rules"]|)
      render_change(form, %{"search" => "our", "rules" => rules})
      render_submit(form, %{"search" => "our", "rules" => rules})

      assert view |> parts(~s|[data-role="decision-preview"]|) |> LazyHTML.attribute("data-count") ==
               ["2"]

      assert view
             |> parts(~s|[data-role="decision-preview-rule"]|)
             |> LazyHTML.attribute("data-key") == ["page:language_unknown"]

      off = Enum.reject(groups, &(&1.kind == "page" and &1.conflict == "language_unknown"))

      for group <- off do
        assert has_element?(
                 view,
                 ~s|[data-role="decision-rule"][data-key="#{group.kind}:#{group.conflict}"]|,
                 "off, not counted"
               )
      end

      view |> element(~s|[data-role="decision-apply"]|) |> render_click()
      panel_settled(view)

      assert Admin.flashes(view) =~ "2 items decided."

      assert %{"language_unknown" => "import"} = page(site, "125").decisions
      assert %{"language_unknown" => "import"} = page(site, "127").decisions
      assert page(site, "126").decisions == %{}
      assert page(site, "128").decisions == %{}
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

    test "search the source id as the rows show it, with or without its #", %{
      conn: conn,
      site: site,
      admin: admin,
      run: run
    } do
      view = open!(conn, admin, run)
      post = Enum.find(stored(site), &(&1.source_kind == "post"))

      filter!(view, %{"search" => post.source_id})
      plain = rows(view)
      assert {"post", post.source_id, to_string(post.outcome)} in plain

      filter!(view, %{"search" => "#" <> post.source_id})
      assert rows(view) == plain
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

      assert has_element?(
               view,
               ~s|details[data-role="item-technical"]:not([open]) [data-role="item-details-note"]|,
               "read from the source again"
             )

      assert has_element?(
               view,
               ~s|details[data-role="item-technical"] summary|,
               "Technical details"
             )

      assert has_element?(view, ~s|details[data-role="item-technical"] [data-role="item-json"]|)

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
