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
  import MishkaCmsMigration.DataCase, only: [register_plugin!: 2]
  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0]

  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsMigration.{MigrationItem, MigrationRun}

  @admin [
    "admin:dashboard:migration",
    "admin:dashboard:blog:post",
    "admin:dashboard:runtime:page",
    "admin:dashboard:runtime:redirect",
    "admin:dashboard:runtime:media"
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

  # How many items the table says it holds, whatever it has loaded so far.
  defp total(view) do
    ~r/(\d+)\s*$/
    |> Regex.run(view |> parts("#{@table}-total") |> LazyHTML.text() |> String.trim())
    |> List.last()
    |> String.to_integer()
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
      filter!(view, %{"source_kind" => "post"})
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
