# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Sources.WordPressTest do
  @moduledoc """
  The WordPress source against what the seeded WordPress answered: signing in and each way a
  connection is refused, what each kind lists and becomes as an item, how it pages, and a dry run
  of a whole site.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0, stub!: 1, recorded: 1]

  alias MishkaCmsMigration.Source
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Sources.WordPress

  @connection %{"url" => "http://localhost:8089", "user" => "admin"}
  @context %{site_id: nil, run_id: nil, source_host: "localhost:8089", options: %{}}
  @recordings %{
    "user" => "users",
    "category" => "categories",
    "tag" => "tags",
    "page" => "pages",
    "post" => "posts"
  }

  defp connected! do
    {:ok, conn} = WordPress.connect(@connection, "app password")
    conn
  end

  defp items!(kind) do
    stub!()
    assert {:ok, rows, nil} = WordPress.list(connected!(), kind, nil)

    Map.new(rows, fn row ->
      assert {:ok, attrs} = WordPress.normalize(row, kind, @context)
      assert {:ok, item} = attrs |> Map.put(:kind, kind) |> Item.build()
      {item.source_id, item}
    end)
  end

  defp recorded_ids(recording), do: recording |> recorded() |> Enum.map(&to_string(&1["id"]))

  describe "connecting" do
    test "signs in and keeps what the site says of itself" do
      stub!()

      assert {:ok, conn} = WordPress.connect(@connection, "app password")

      assert WordPress.extra(conn) == %{
               "name" => "Mishka Test Blog",
               "home" => "http://localhost:8089",
               "timezone" => "Asia/Tehran",
               "signed_in_as" => "admin"
             }
    end

    test "signs in with the user and the application password" do
      stub!()

      {:ok, _conn} = WordPress.connect(@connection, "app password")

      assert_received {:wordpress_request, %{request_path: "/wp-json/wp/v2/users/me"} = request}
      assert ["Basic " <> basic] = Plug.Conn.get_req_header(request, "authorization")
      assert Base.decode64!(basic) == "admin:app password"
    end

    test "reads a site in a folder under that folder" do
      stub!()

      assert {:ok, _conn} =
               WordPress.connect(%{@connection | "url" => " http://localhost:8089/blog/ "}, "pw")

      assert_received {:wordpress_request, %{request_path: "/blog/wp-json/"}}
    end

    test "is refused for a wrong password or an unknown user" do
      for recording <- [
            "unauthorized-users-me-wrong-password",
            "unauthorized-users-me-unknown-user"
          ] do
        stub!(%{"/wp-json/wp/v2/users/me" => recording})
        assert WordPress.connect(@connection, "wrong") == {:error, :unauthorized}
      end
    end

    test "is refused without a user or a password, without signing in" do
      stub!()

      for {connection, secret} <- [
            {@connection, nil},
            {@connection, ""},
            {Map.delete(@connection, "user"), "pw"},
            {%{@connection | "user" => ""}, "pw"}
          ] do
        assert WordPress.connect(connection, secret) == {:error, :unauthorized}
        refute_received {:wordpress_request, %{request_path: "/wp-json/wp/v2/users/me"}}
      end
    end

    test "says what is wrong with the address before asking for a password" do
      stub!(%{"/wp-json/" => :unreachable})

      assert WordPress.connect(%{"url" => "ftp://example.com"}, nil) == {:error, :invalid_address}
      assert WordPress.connect(%{"url" => "http://localhost:1"}, nil) == {:error, :unreachable}
    end

    test "says no WordPress answers where the address has no REST API" do
      stub!(%{"/wp-json/" => :no_site})

      assert WordPress.connect(@connection, "pw") == {:error, :no_site}
    end

    test "says nothing answered when the site cannot be reached" do
      stub!(%{"/wp-json/" => :unreachable})

      assert WordPress.connect(@connection, "pw") == {:error, :unreachable}
    end

    test "refuses an address that is not a web address" do
      stub!()

      for url <- ["example.com", "ftp://example.com", "https://", ""] do
        assert WordPress.connect(%{@connection | "url" => url}, "pw") ==
                 {:error, :invalid_address}
      end

      assert WordPress.connect(%{}, "pw") == {:error, :invalid_address}
      assert WordPress.connect(%{"url" => 8089}, "pw") == {:error, :invalid_address}
      refute_received {:wordpress_request, _conn}
    end
  end

  describe "the source" do
    test "keeps the host of the address as the run's source host" do
      assert WordPress.host(%{"url" => " https://Blog.Example.com/news/ "}) == "blog.example.com"
      assert WordPress.host(%{"url" => "https://blog.example.com:443"}) == "blog.example.com"
      assert WordPress.host(%{"url" => "http://localhost:8089"}) == "localhost:8089"
      assert WordPress.host(%{"url" => "example.com"}) == nil
      assert WordPress.host(%{}) == nil
    end

    test "is installed with the extension, and lists authors and terms before what points at them" do
      assert {:ok, WordPress} = Source.fetch("wordpress")
      assert WordPress.kinds() == ["user", "category", "tag", "page", "post"]
    end
  end

  describe "listing" do
    test "asks each kind's route for its raw fields, 100 a page, pages and posts in any status" do
      stub!()
      conn = connected!()

      for {kind, route, status} <- [
            {"user", "/wp-json/wp/v2/users", nil},
            {"category", "/wp-json/wp/v2/categories", nil},
            {"tag", "/wp-json/wp/v2/tags", nil},
            {"page", "/wp-json/wp/v2/pages", "any"},
            {"post", "/wp-json/wp/v2/posts", "any"}
          ] do
        assert {:ok, [_ | _], nil} = WordPress.list(conn, kind, nil)
        assert_received {:wordpress_request, %{request_path: ^route, query_params: params}}

        assert {params["context"], params["per_page"], params["page"], params["status"]} ==
                 {"edit", "100", "1", status}
      end
    end

    test "lists every row WordPress answered for each kind" do
      for {kind, recording} <- @recordings do
        assert items!(kind) |> Map.keys() |> Enum.sort() == Enum.sort(recorded_ids(recording))
      end
    end

    test "leaves the trash out of the posts" do
      posts = items!("post")
      trashed = recorded_ids("posts-trash")

      assert trashed != []
      assert Enum.all?(trashed, &(not is_map_key(posts, &1)))
      refute Enum.any?(Map.values(posts), &(&1.attrs["status"] == "trash"))
    end

    test "follows X-WP-TotalPages to the next page and stops after the last" do
      stub!(%{{"/wp-json/wp/v2/posts", 2} => "posts-page-2"})
      conn = connected!()

      assert {:ok, rows, nil} = WordPress.list(conn, "post", nil)
      assert length(rows) == length(recorded("posts"))

      assert {:ok, rows, 3} = WordPress.list(conn, "post", 2)
      assert Enum.map(rows, & &1["id"]) == Enum.map(recorded("posts-page-2"), & &1["id"])
      assert_received {:wordpress_request, %{query_params: %{"page" => "2"}}}
    end

    test "fails on a page past the last with what WordPress said" do
      stub!(%{{"/wp-json/wp/v2/posts", 99} => "posts-page-out-of-range"})

      assert {:error, reason} = WordPress.list(connected!(), "post", 99)
      assert reason =~ "400"
      assert reason =~ "larger than the number of pages"
    end

    test "fails as the source behaviour names it when WordPress refuses or is gone" do
      for {answer, reason} <- [
            {"unauthorized-wrong-password", :unauthorized},
            {:unreachable, :unreachable},
            {:no_site, :no_site}
          ] do
        stub!(%{"/wp-json/wp/v2/posts" => answer})

        assert WordPress.list(connected!(), "post", nil) == {:error, reason}
      end
    end

    test "fails on a server error with what WordPress said" do
      stub!(%{"/wp-json/wp/v2/tags" => "media-upload-svg-refused"})

      assert {:error, reason} = WordPress.list(connected!(), "tag", nil)
      assert reason =~ "500"
    end

    test "lists no kind it does not read" do
      stub!()

      assert WordPress.list(connected!(), "comment", nil) == {:error, {:unknown_kind, "comment"}}
      refute_received {:wordpress_request, %{request_path: "/wp-json/wp/v2/comments"}}
    end
  end

  describe "an item" do
    test "a user is named by its display name and carries what an author needs" do
      users = items!("user")
      omid = users["4"]

      assert omid.title == "امید رحیمی"
      assert is_nil(omid.modified_at)

      assert Map.take(omid.attrs, ["username", "email", "first_name", "last_name", "roles"]) ==
               %{
                 "username" => "omid",
                 "email" => "omid.rahimi@example.test",
                 "first_name" => "Omid",
                 "last_name" => "Rahimi",
                 "roles" => ["author"]
               }

      assert %{"96" => "http" <> _} = omid.attrs["avatar_urls"]
      assert %{"registered_date" => _, "capabilities" => %{}} = omid.extra
      assert users["1"].title == "Site Admin"
    end

    test "a category keeps its parent, so a nested one is found under it" do
      categories = items!("category")

      assert categories["4"].title == "Announcements"
      assert {categories["4"].parent, categories["4"].attrs["parent"]} == {"2", 2}
      assert categories["2"].title == "News"
      assert {categories["2"].parent, categories["2"].attrs["parent"]} == {nil, 0}
      assert categories["8"].parent == "7"
      assert Enum.any?(Map.values(categories), &(&1.title == "آموزش‌ها"))
      assert categories["8"].attrs["slug"] == "migration"
      assert categories["8"].extra["taxonomy"] == "category"
    end

    test "a tag keeps its slug and how many posts use it" do
      tags = items!("tag")

      assert {tags["17"].title, tags["17"].attrs["slug"], tags["17"].attrs["count"]} ==
               {"Release notes", "release-notes", 2}

      refute is_map_key(tags["17"].attrs, "parent")
      assert is_nil(tags["17"].parent)
    end

    test "a slug WordPress keeps percent-encoded is decoded, and an ASCII one is kept" do
      [tag] = Enum.filter(recorded("tags"), &(&1["id"] == 20))
      [category] = Enum.filter(recorded("categories"), &(&1["id"] == 9))

      assert tag["slug"] =~ "%d9%88"
      assert items!("tag")["20"].attrs["slug"] == "وردپرس"
      assert category["slug"] =~ "%d8%a2"
      assert items!("category")["9"].attrs["slug"] == "آموزش"
      assert items!("post")["33"].attrs["slug"] == recorded("post-single")["slug"]
    end

    test "a page keeps its parent and its place in the menu order" do
      pages = items!("page")

      assert pages["26"].title == "Leadership"
      assert {pages["26"].parent, pages["26"].attrs["parent"]} == {"25", 25}
      assert pages["25"].attrs["parent"] == 24
      assert pages["29"].attrs["menu_order"] == 5
      assert pages["3"].attrs["status"] == "draft"
      assert [%{html: "<!-- wp:paragraph -->" <> _}] = pages["24"].content
    end

    test "a post carries its author, terms, raw content and modified time" do
      posts = items!("post")
      [row] = Enum.filter(recorded("posts"), &(&1["id"] == 38))
      post = posts["38"]

      assert post.title == "Scheduled release notes"
      assert post.attrs["author"] == 2
      assert post.attrs["categories"] == [3]
      assert post.attrs["tags"] == [17]
      assert post.attrs["status"] == "future"
      assert post.attrs["date_gmt"] == row["date_gmt"]
      assert post.modified_at == ~U[2026-11-02 06:22:16Z]
      assert Item.html(post) == row["content"]["raw"]
      assert Enum.any?(Map.values(posts), &(&1.title == "نصب وردپرس روی سرور"))
    end

    test "a post's extra keeps its Yoast fields and leaves out what WordPress renders" do
      post = items!("post")["46"]

      assert post.extra["meta"]["_yoast_wpseo_title"] == "An SEO checklist for moving a site"
      assert is_map_key(post.extra, "comment_status")

      for rendered <- ["_links", "yoast_head", "yoast_head_json", "modified", "content", "title"] do
        refute is_map_key(post.extra, rendered)
      end
    end

    test "a row without the fields its kind needs is refused, and an unknown kind too" do
      [row | _] = recorded("posts-page-2")

      assert WordPress.normalize(row, "post", @context) == {:error, :unreadable}

      assert WordPress.normalize(row, "comment", @context) ==
               {:error, {:unknown_kind, "comment"}}
    end
  end

  describe "a dry run" do
    test "reports every user, term, page and post it found, each skipped with no target yet" do
      stub!()
      site = create_site!()
      admin = migration_admin!(site)

      run =
        %{source: "wordpress", connection: @connection, secret: "app password"}
        |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)
        |> dry_run!(admin)

      assert run.status == :dry_run
      assert Enum.map(run.report.kinds, & &1.kind) == WordPress.kinds()

      for %{kind: kind} = counts <- run.report.kinds do
        found = length(recorded(@recordings[kind]))

        assert Map.take(counts, [:created, :updated, :skipped, :failed]) ==
                 %{created: 0, updated: 0, skipped: found, failed: 0}
      end

      assert Enum.all?(run.report.entries, &(&1.reason == "no_target"))
      assert Enum.any?(run.report.entries, &(&1.title == "نصب وردپرس روی سرور"))

      assert MishkaCmsMigration.MigrationItem |> Ash.read!(tenant: site.id, authorize?: false) ==
               []
    end
  end
end
