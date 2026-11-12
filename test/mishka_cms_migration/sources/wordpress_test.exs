# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Sources.WordPressTest do
  @moduledoc """
  The WordPress source against what the seeded WordPress answered: signing in and each way a
  connection is refused, what each kind lists and becomes as an item, how it pages, what a post's
  content becomes, and a dry run of a whole site.

  A post's content is read for what it means, with LazyHTML: which elements hold which text and
  which addresses, not its markup as a string.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0, stub!: 1, recorded: 1]

  alias MishkaCmsMigration.Source
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Sources.WordPress
  alias MishkaCmsMigration.Sources.WordPress.Content

  @connection %{"url" => "http://localhost:8089", "user" => "admin"}
  @context %{site_id: nil, run_id: nil, source_host: "localhost:8089", options: %{}}
  @youtube_player "https://www.youtube-nocookie.com/embed/jNQXAC9IVRw"
  @vimeo_player "https://player.vimeo.com/video/76979871"
  @written %{"category" => :created, "tag" => :created, "page" => :created, "post" => :created}
  @recordings %{
    "user" => "users",
    "category" => "categories",
    "tag" => "tags",
    "media" => "media",
    "page" => "pages",
    "post" => "posts",
    "comment" => "comments"
  }

  defp connected! do
    {:ok, conn} = WordPress.connect(@connection, "app password")
    conn
  end

  defp items!(kind, answers \\ %{}) do
    stub!(answers)
    conn = connected!()

    conn
    |> every_row(kind, nil)
    |> Map.new(fn row ->
      assert {:ok, attrs} = WordPress.normalize(row, kind, Map.put(@context, :conn, conn))
      assert {:ok, item} = attrs |> Map.put(:kind, kind) |> Item.build()
      {item.source_id, item}
    end)
  end

  defp every_row(conn, kind, cursor) do
    assert {:ok, rows, next} = WordPress.list(conn, kind, cursor)
    rows ++ more_rows(conn, kind, next)
  end

  defp more_rows(_conn, _kind, nil), do: []
  defp more_rows(conn, kind, next), do: every_row(conn, kind, next)

  defp html(item), do: item |> Item.html() |> LazyHTML.from_fragment()

  defp texts(html, selector),
    do: html |> LazyHTML.query(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

  defp sources(html, selector), do: html |> LazyHTML.query(selector) |> LazyHTML.attribute("src")

  defp pieces(item), do: for(%{name: name} = piece <- item.content, name != nil, do: piece)

  defp requested do
    receive do
      {:wordpress_request, %{request_path: path}} -> [path | requested()]
    after
      0 -> []
    end
  end

  defp recorded_ids(recording), do: recording |> recorded() |> Enum.map(&to_string(&1["id"]))

  defp json(rows), do: {"application/json", Jason.encode!(rows)}

  defp menu_items_with(changes),
    do: json(for(item <- recorded("menu-items"), do: Map.merge(item, changes[item["id"]] || %{})))

  defp outline(items),
    do: for(item <- items, do: {item["title"], item["kind"], item["id"], outline(item["items"])})

  defp counts(run, kind),
    do:
      run.report.kinds
      |> Enum.find(&(&1.kind == kind))
      |> Map.take(MishkaCmsMigration.Report.outcomes())

  describe "connecting" do
    test "signs in and keeps what the site says of itself" do
      stub!()

      assert {:ok, conn} = WordPress.connect(@connection, "app password")

      assert %{
               "name" => "Mishka Test Blog",
               "home" => "http://localhost:8089",
               "timezone" => "Asia/Tehran",
               "signed_in_as" => "admin",
               "front_page" => %{
                 "show_on_front" => "page",
                 "page_on_front" => "22",
                 "page_for_posts" => "23",
                 "posts_page_link" => nil
               }
             } = WordPress.extra(conn)

      posts_page = json(%{"link" => "http://localhost:8089/blog/"})
      stub!(%{"/wp-json/wp/v2/pages/23" => posts_page})

      assert WordPress.extra(conn)["front_page"]["posts_page_link"] ==
               "http://localhost:8089/blog/"
    end

    test "keeps the structure of the posts' addresses and the bases of the terms', read from their links" do
      stub!()
      {:ok, conn} = WordPress.connect(@connection, "app password")

      published = for %{"status" => "publish", "id" => id} <- recorded("posts"), do: id

      assert WordPress.extra(conn)["permalinks"] == %{
               "structure" => "/%year%/%monthnum%/%postname%/",
               "pattern" => "/:year/:monthnum/:slug",
               "language_prefixes" => [],
               "category_base" => "category",
               "tag_base" => "tag",
               "author_base" => "author",
               "posts" => length(published),
               "misfits" => []
             }

      assert_received {:wordpress_request,
                       %{
                         request_path: "/wp-json/wp/v2/posts",
                         query_params: %{"_fields" => fields} = asked
                       }}

      assert asked["status"] == "publish"
      assert fields == "id,status,slug,date,link,categories"
    end

    test "keeps no front page for a user who may not read the site's settings, and none of its pages for a site that shows its posts" do
      stub!(%{"/wp-json/wp/v2/settings" => "unauthorized-settings"})
      {:ok, conn} = WordPress.connect(@connection, "app password")
      refute Map.has_key?(WordPress.extra(conn), "front_page")

      latest = "settings" |> recorded() |> Map.put("show_on_front", "posts") |> Jason.encode!()
      stub!(%{"/wp-json/wp/v2/settings" => {"application/json", latest}})

      assert WordPress.extra(conn)["front_page"] == %{
               "show_on_front" => "posts",
               "page_on_front" => nil,
               "page_for_posts" => nil,
               "posts_page_link" => nil
             }
    end

    test "keeps which language plugin the site runs, from the namespaces of its REST index" do
      stub!()
      {:ok, conn} = WordPress.connect(@connection, "app password")

      assert WordPress.extra(conn)["languages"] == nil

      for {namespace, plugin} <- [{"pll/v1", "polylang"}, {"wpml/v1", "wpml"}] do
        index = Map.update!(conn.index, "namespaces", &[namespace | &1])
        assert WordPress.extra(%{conn | index: index})["languages"] == plugin
      end
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

      assert WordPress.kinds() ==
               ~w(user category tag media setting stylesheet page post comment post_redirect menu)
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
            {"media", "/wp-json/wp/v2/media", nil},
            {"page", "/wp-json/wp/v2/pages", "any"},
            {"post", "/wp-json/wp/v2/posts", "any"},
            {"comment", "/wp-json/wp/v2/comments", "all"}
          ] do
        assert {:ok, [_ | _], nil} = WordPress.list(conn, kind, nil)
        assert_received {:wordpress_request, %{request_path: ^route, query_params: params}}

        assert {params["context"], params["per_page"], params["page"], params["status"]} ==
                 {"edit", "100", "1", status}
      end
    end

    test "reads picked rows by their ids from their kind's route, 100 ids a request" do
      stub!()
      conn = connected!()
      ids = Enum.map(1..101, &to_string/1)

      assert {:ok, rows} = WordPress.rows(conn, "comment", ids)
      assert length(rows) == 2 * length(recorded("comments"))

      for asked <- [Enum.take(ids, 100), ["101"]] do
        include = Enum.join(asked, ",")

        assert_received {:wordpress_request,
                         %{
                           request_path: "/wp-json/wp/v2/comments",
                           query_params: %{"include" => ^include, "status" => "all"}
                         }}
      end

      assert {:ok, [%{"id" => 23}]} = WordPress.rows(conn, "menu", ["23"])
      assert {:ok, [%{"id" => "title"}]} = WordPress.rows(conn, "setting", ["title"])
    end

    test "reads the addresses kind after kind with only the fields an address needs, then the archives" do
      stub!()
      conn = connected!()

      assert {:ok, [_ | _], {1, nil}} = WordPress.list(conn, "post_redirect", nil)
      assert_received {:wordpress_request, %{query_params: %{"_fields" => fields}}}

      assert fields |> String.split(",") |> Enum.sort() ==
               ~w(content id link modified_gmt slug status title)

      for {at, route} <- [
            {1, "/wp-json/wp/v2/pages"},
            {2, "/wp-json/wp/v2/categories"},
            {3, "/wp-json/wp/v2/tags"},
            {4, "/wp-json/wp/v2/users"},
            {5, "/wp-json/wp/v2/media"}
          ] do
        assert {:ok, _rows, {next, nil}} = WordPress.list(conn, "post_redirect", {at, nil})
        assert next == at + 1
        assert_received {:wordpress_request, %{request_path: ^route}}
      end

      assert {:ok, archives, nil} = WordPress.list(conn, "post_redirect", {6, nil})
      assert Enum.all?(archives, &(&1["to"]["kind"] in ["list", "sitemap"]))
    end

    test "lists a post's comment pages only when the run says WordPress breaks comments into pages" do
      stub!()
      conn = connected!()

      assert {:ok, rows, _next} = WordPress.list(conn, "post_redirect", nil)
      refute Enum.any?(rows, &String.contains?(&1["id"], "comment-page"))
      refute_received {:wordpress_request, %{request_path: "/wp-json/wp/v2/comments"}}

      paged = Source.with_options(conn, %{comment_pages: true, comments_per_page: 2})
      assert {:ok, rows, _next} = WordPress.list(paged, "post_redirect", nil)

      assert_received {:wordpress_request,
                       %{
                         request_path: "/wp-json/wp/v2/comments",
                         query_params: %{"parent" => "0", "post" => posts}
                       }}

      refute "38" in String.split(posts, ",")

      comment_pages =
        for %{"id" => id} = row <- rows,
            String.contains?(id, "comment-page"),
            into: %{},
            do: {id, row}

      # Post 50 has three approved comments that answer no other, a held one and four replies.
      assert comment_pages |> Map.keys() |> Enum.sort() ==
               ~w(32/comment-page-1 33/comment-page-1 50/comment-page-1 50/comment-page-2)

      assert comment_pages["50/comment-page-2"]["from"] ==
               "/2026/04/comment-heavy-post/comment-page-2"

      assert comment_pages["50/comment-page-2"]["to"] == %{"kind" => "post", "id" => "50"}

      assert {:ok, [%{"id" => "50/comment-page-2"}]} =
               WordPress.rows(paged, "post_redirect", ["50/comment-page-2"])
    end

    test "reads picked addresses from the kinds their ids name" do
      stub!()
      conn = connected!()

      assert {:ok, rows} =
               WordPress.rows(conn, "post_redirect", ["44", "44?p", "category:2", "archive:/feed"])

      assert rows |> Enum.map(& &1["id"]) |> Enum.sort() ==
               ["44", "44?p", "archive:/feed", "category:2"]
    end

    test "lists every row WordPress answered for each kind" do
      for {kind, recording} <- @recordings do
        assert items!(kind) |> Map.keys() |> Enum.sort() == Enum.sort(recorded_ids(recording))
      end

      addresses = items!("post_redirect")
      assert Enum.all?(recorded_ids("posts"), &is_map_key(addresses, &1))
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

    test "asks for comments of every type, held ones too, and for no spam or trash" do
      stub!()
      assert {:ok, [_ | _], nil} = WordPress.list(connected!(), "comment", nil)
      assert_received {:wordpress_request, %{query_params: %{"status" => status, "type" => type}}}

      assert {status, type} == {"all", "all"}
    end

    test "reads every menu, menu item and block menu with their raw fields, each route to its last page" do
      stub!()
      assert {:ok, menus, nil} = WordPress.list(connected!(), "menu", nil)

      for route <- [
            "/wp-json/wp/v2/menus",
            "/wp-json/wp/v2/menu-items",
            "/wp-json/wp/v2/navigation"
          ] do
        assert_received {:wordpress_request, %{request_path: ^route, query_params: params}}
        assert {params["context"], params["per_page"], params["page"]} == {"edit", "100", "1"}
      end

      assert Enum.map(menus, &{&1["name"], length(&1["items"])}) ==
               [{"Primary", 14}, {"Footer", 3}, {"Main navigation", 3}]
    end

    test "lists no kind it does not read" do
      stub!()

      assert WordPress.list(connected!(), "navigation", nil) ==
               {:error, {:unknown_kind, "navigation"}}

      refute_received {:wordpress_request, %{request_path: "/wp-json/wp/v2/navigation"}}
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

    test "a term's, a user's, a commenter's and a menu's name are plain text, the HTML WordPress saves a name as read once" do
      saved = fn recording, id, fields ->
        json(
          for row <- recorded(recording),
              do:
                (row["id"] == id && Map.merge(row, Map.new(fields, &{&1, "Tom &amp; Jerry"}))) ||
                  row
        )
      end

      user_names = ~w(name first_name last_name nickname)

      category =
        items!("category", %{"/wp-json/wp/v2/categories" => saved.("categories", 2, ["name"])})

      tag = items!("tag", %{"/wp-json/wp/v2/tags" => saved.("tags", 17, ["name"])})
      user = items!("user", %{"/wp-json/wp/v2/users" => saved.("users", 4, user_names)})

      comment =
        items!("comment", %{"/wp-json/wp/v2/comments" => saved.("comments", 7, ["author_name"])})

      menu = items!("menu", %{"/wp-json/wp/v2/menus" => saved.("menus", 22, ["name"])})

      assert Enum.uniq([
               category["2"].title,
               tag["17"].title,
               user["4"].title,
               comment["7"].title,
               comment["7"].attrs["author_name"],
               menu["22"].title
               | Map.values(Map.take(user["4"].attrs, user_names))
             ]) == ["Tom & Jerry"]
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
      assert [_ | _] = texts(html(pages["24"]), "p")
    end

    test "a post carries its author, terms, converted content and modified time" do
      posts = items!("post")
      [row] = Enum.filter(recorded("posts"), &(&1["id"] == 38))
      post = posts["38"]

      assert post.title == "Scheduled release notes"
      assert post.attrs["author"] == 2
      assert post.attrs["categories"] == [3]
      assert post.attrs["tags"] == [17]
      assert post.attrs["status"] == "future"
      assert post.attrs["date_gmt"] == row["date_gmt"]
      assert post.modified_at == ~U[2026-11-03 14:47:53Z]
      assert texts(html(post), "p code") == ["future"]
      refute Item.html(post) =~ "wp:paragraph"
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

    test "a post's old address is the path of a published post's link, and none for the rest" do
      redirects = items!("post_redirect")
      posts = Map.new(recorded("posts"), &{to_string(&1["id"]), &1})

      assert redirects["44"].attrs == %{
               "from" => "/2025/12/release-1-0-announcement/",
               "query" => nil,
               "to" => %{"kind" => "post", "id" => "44"}
             }

      assert redirects["44?p"].attrs == %{
               "from" => "/",
               "query" => "p=44",
               "to" => %{"kind" => "post", "id" => "44"}
             }

      refute Enum.any?(Map.keys(redirects), &String.contains?(&1, "~"))

      assert redirects["44"].title == "Release 1.0 announcement"
      assert redirects["44"].modified_at

      for {id, item} <- redirects,
          is_map_key(posts, id),
          posts[id]["status"] == "publish",
          do: assert(item.attrs["from"] == URI.parse(posts[id]["link"]).path)

      for {id, item} <- redirects,
          is_map_key(posts, id),
          posts[id]["status"] != "publish",
          do: assert(is_nil(item.attrs["from"]) and not is_map_key(redirects, id <> "?p"))

      assert {redirects["39"].attrs["from"], redirects["41"].attrs["from"]} == {nil, nil}
    end

    test "a comment carries its post, its parent, its author and its text as the commenter typed it" do
      comments = items!("comment")
      reply = comments["7"]

      assert reply.title == "امید رحیمی"
      assert reply.parent == "6"
      assert is_nil(reply.modified_at)
      assert Item.html(reply) == "Reply from an author."

      assert reply.attrs == %{
               "post" => 50,
               "post_type" => "post",
               "author" => 4,
               "author_name" => "امید رحیمی",
               "author_email" => "omid.rahimi@example.test",
               "status" => "approved",
               "type" => "comment",
               "date_gmt" => "2026-04-12T05:50:00"
             }

      assert is_nil(comments["2"].parent)
      assert comments["3"].parent == "2"
      assert comments["9"].attrs["status"] == "hold"
      assert comments["6"] |> html() |> texts("strong") == ["Bold"]
      assert comments["15"].attrs["post_type"] == "page"
      assert reply.extra["author_ip"]
      assert reply.extra["link"] =~ "#comment-7"

      for kept <- ["content", "post", "author", "status", "_links"],
          do: refute(is_map_key(reply.extra, kept))
    end

    test "a menu keeps its items nested in menu order, each naming the page, post or term it points at" do
      menus = items!("menu")
      primary = menus["22"]

      assert {primary.title, primary.attrs["slug"], primary.attrs["main"]} ==
               {"Primary", "primary", true}

      assert {menus["23"].title, menus["23"].attrs["main"]} == {"Footer", false}

      assert outline(primary.attrs["items"]) == [
               {"Home", nil, nil, []},
               {"About", "page", "24",
                [
                  {"Team", "page", "25", [{"Leadership", "page", "26", []}]},
                  {"Contact", "page", "29", []}
                ]},
               {"Blog", "page", "23",
                [
                  {"News", "category", "2",
                   [{"Releases", "category", "3", []}, {"Announcements", "category", "4", []}]},
                  {"Tutorials", "category", "5", []}
                ]},
               {"Docs", "page", "27", [{"Getting started", "page", "28", []}]},
               {"Start here", "post", "32", []},
               {"Elixir", nil, nil, []}
             ]

      [home | _] = primary.attrs["items"]
      elixir = List.last(primary.attrs["items"])

      assert {home["url"], home["new_tab"]} == {"http://localhost:8089/", false}
      assert {elixir["url"], elixir["new_tab"]} == {"https://elixir-lang.org/", true}
      assert is_map_key(primary.extra, "auto_add")
      refute is_map_key(primary.extra, "_links")
    end

    test "a block menu keeps the links of its navigation blocks nested like a classic menu's, never main" do
      menus = items!("menu")
      block = menus["navigation-105"]

      assert {block.title, block.attrs["slug"], block.attrs["block"], block.attrs["main"]} ==
               {"Main navigation", "main-navigation", true, false}

      assert outline(block.attrs["items"]) == [
               {"Home", nil, nil, []},
               {"About", "page", "24",
                [{"Team", "page", "25", []}, {"Contact", "page", "29", []}]},
               {"Blog", "page", "23", []}
             ]
    end

    test "a block menu with the same links as a classic menu names it, and one with other links names none" do
      assert items!("menu")["navigation-105"].attrs["same_as"] == nil

      contact =
        ~s(<!-- wp:navigation-link {"label":"Reach us","type":"page","id":29,"url":"http://localhost:8089/contact/","kind":"post-type"} /-->)

      navigation =
        for post <- recorded("navigation"), do: %{post | "content" => %{"raw" => contact}}

      footer_item = %{
        "id" => 1,
        "title" => %{"raw" => "Contact"},
        "type" => "post_type",
        "object" => "page",
        "object_id" => 29,
        "url" => "http://localhost:8089/contact/",
        "menus" => 23,
        "parent" => 0,
        "menu_order" => 1,
        "target" => ""
      }

      menus =
        for menu <- recorded("menus"),
            do: (menu["id"] == 23 && %{menu | "name" => "Footer &amp; links"}) || menu

      found =
        items!("menu", %{
          "/wp-json/wp/v2/menus" => json(menus),
          "/wp-json/wp/v2/navigation" => json(navigation),
          "/wp-json/wp/v2/menu-items" => json([footer_item])
        })

      assert found["navigation-105"].attrs["same_as"] == "Footer & links"
    end

    test "the main menu is the one at the theme's primary location, else one at any location, else the first made" do
      for {locations, main} <- [
            {%{22 => [], 23 => []}, "22"},
            {%{22 => [], 23 => ["footer"]}, "23"},
            {%{22 => ["footer"], 23 => ["primary"]}, "23"}
          ] do
        menus = for menu <- recorded("menus"), do: %{menu | "locations" => locations[menu["id"]]}
        found = items!("menu", %{"/wp-json/wp/v2/menus" => json(menus)})

        assert for({id, %{attrs: %{"main" => true}}} <- found, do: id) == [main]
      end
    end

    test "a custom link of the main menu to a page or post of the site points at it, asked for as a post's links are" do
      menus =
        items!("menu", %{
          "/wp-json/wp/v2/menu-items" =>
            menu_items_with(%{
              88 => %{"url" => "http://localhost:8089/about/team/"},
              104 => %{"url" => "http://localhost:8089/contact/"}
            })
        })

      assert menus["22"].attrs["items"] |> hd() |> Map.take(["title", "kind", "id"]) ==
               %{"title" => "Home", "kind" => "page", "id" => "25"}

      assert menus["23"].attrs["items"] |> List.last() |> Map.take(["kind", "id"]) ==
               %{"kind" => nil, "id" => nil}

      assert_received {:wordpress_request,
                       %{request_path: "/wp-json/wp/v2/pages", query_params: %{"slug" => "team"}}}

      refute_received {:wordpress_request, %{query_params: %{"slug" => "contact"}}}
    end

    test "a menu item WordPress counts as invalid is left out, and the one under it sits at the top" do
      primary =
        items!("menu", %{
          "/wp-json/wp/v2/menu-items" => menu_items_with(%{90 => %{"invalid" => true}})
        })[
          "22"
        ]

      assert primary.attrs["items"] |> outline() |> Enum.map(&elem(&1, 0)) ==
               ["Home", "About", "Leadership", "Blog", "Docs", "Start here", "Elixir"]

      assert [{"About", _, _, [{"Contact", "page", "29", []}]}] =
               primary.attrs["items"] |> outline() |> Enum.filter(&(elem(&1, 0) == "About"))
    end

    test "a setting is the site's name, tagline, logo or icon, read from the REST index with no request of its own" do
      index = recorded("index")

      assert "setting" |> items!() |> Map.new(fn {id, item} -> {id, {item.title, item.attrs}} end) ==
               %{
                 "title" => {"Site Title", %{"value" => index["name"]}},
                 "tagline" => {"Tagline", %{"value" => index["description"]}},
                 "logo" => {"Site Logo", %{"value" => index["site_logo"]}},
                 "icon" => {"Site Icon", %{"value" => index["site_icon"]}},
                 "app_icon" => {"Site Icon (app icon)", %{"value" => index["site_icon"]}}
               }

      assert requested() == ["/wp-json/", "/wp-json/wp/v2/users/me"]

      bare =
        Map.merge(index, %{"name" => "Tom &amp; Jerry", "description" => "", "site_logo" => 0})

      settings = items!("setting", %{"/wp-json/" => {"application/json", Jason.encode!(bare)}})

      assert Map.keys(settings) |> Enum.sort() == ["app_icon", "icon", "title"]
      assert settings["title"].attrs["value"] == "Tom & Jerry"
    end

    test "a post or page carries what Yoast SEO kept for it, and no Yoast default nor canonical on the site's own host" do
      posts = items!("post")
      pages = items!("page")
      og_image = Enum.find(recorded("media"), &(&1["slug"] == "og-image"))

      assert posts["46"].attrs["seo"] == %{
               "title" => "An SEO checklist for moving a site",
               "description" =>
                 "Keep addresses, titles and descriptions when a site changes CMS.",
               "robots" => "noindex, nofollow",
               "image" => og_image["source_url"],
               "image_id" => og_image["id"],
               "og_title" => "SEO checklist (social title)",
               "og_description" => "The social description differs from the search description.",
               "twitter_title" => "SEO checklist (Twitter title)",
               "twitter_description" => "The Twitter description."
             }

      assert posts["43"].attrs["seo"]["canonical"] ==
               "https://syndicated.example.test/phoenix-liveview-tips/"

      refute is_map_key(posts["33"].attrs["seo"], "canonical")
      assert posts["52"].attrs["seo"] == %{}

      for id <- ["33", "35", "50"],
          field <- ["og_title", "og_description", "twitter_card"],
          do:
            refute(
              is_map_key(posts[id].attrs["seo"], field),
              "Yoast's default #{field} on post #{id} says what the CMS's head already says"
            )

      assert pages["24"].attrs["seo"]["title"] == "About the Mishka Test Blog"
      assert pages["27"].attrs["seo"]["title"] == "Docs - Guides - Mishka Test Blog"
      refute is_map_key(pages["22"].attrs["seo"], "title")
    end

    test "a spam comment and a pingback read as what they are, for the target to leave out" do
      spam = items!("comment", %{"/wp-json/wp/v2/comments" => "comments-spam"})["10"]
      pingback = items!("comment", %{"/wp-json/wp/v2/comments" => "comments-pingback"})["11"]

      assert spam.attrs["status"] == "spam"
      assert pingback.attrs["type"] == "pingback"
    end

    test "a file carries where it is, its type and size, its alt text, caption and description" do
      hero = items!("media")["4"]

      assert hero.title == "Hero image"
      assert hero.modified_at == ~U[2026-11-03 14:47:50Z]

      assert Map.take(hero.attrs, ~w(source_url filename mime_type filesize post)) == %{
               "source_url" => "http://localhost:8089/wp-content/uploads/2026/11/hero.jpg",
               "filename" => "hero.jpg",
               "mime_type" => "image/jpeg",
               "filesize" => 43_354,
               "post" => 32
             }

      assert {hero.attrs["alt_text"], hero.attrs["caption"], hero.attrs["description"]} ==
               {"A blue gradient hero image with a white circle",
                "The hero image of the welcome post", "A 1600 by 900 JPEG drawn by the seed."}

      assert %{"medium" => %{"source_url" => "http" <> _}} = hero.extra["media_details"]["sizes"]

      for rendered <- ["_links", "modified", "title", "caption", "description"] do
        refute is_map_key(hero.extra, rendered)
      end
    end

    test "a post's social and Twitter fields are read from Rank Math and Yoast's export fields, with their image found in the media request" do
      stub!()
      conn = connected!()
      [row] = Enum.filter(recorded("posts"), &(&1["id"] == 52))
      uploads = "http://localhost:8089/wp-content/uploads/2026/11/"

      meta = %{
        "rank_math_facebook_title" => "%title% %sep% %sitename%",
        "rank_math_facebook_description" => "A social text",
        "rank_math_twitter_title" => "Unknown %%ct_thing%% variable",
        "_yoast_wpseo_twitter-description" => "Twitter text",
        "rank_math_twitter_image" => uploads <> "gallery-1-300x225.jpg",
        "rank_math_twitter_card_type" => "summary"
      }

      row = Map.update!(row, "meta", &Map.merge((is_map(&1) && &1) || %{}, meta))

      assert {:ok, %{attrs: %{"seo" => seo}}} =
               WordPress.normalize(row, "post", Map.put(@context, :conn, conn))

      assert seo["og_title"] == "{{page.title}} - {{site.name}}"
      assert seo["og_description"] == "A social text"
      refute is_map_key(seo, "twitter_title")
      assert seo["twitter_description"] == "Twitter text"
      assert seo["twitter_image"] == uploads <> "gallery-1-300x225.jpg"
      assert seo["twitter_image_id"] == 6
      assert seo["twitter_card"] == "summary"
    end

    test "a post's SEO texts are plain text, each HTML entity WordPress answered read once" do
      stub!()
      context = Map.put(@context, :conn, connected!())
      [row] = recorded("elementor-posts")
      served = row["yoast_head_json"]["og_description"]
      shown = String.replace(served, "&#8217;", "’")

      seo = fn row ->
        assert {:ok, %{attrs: %{"seo" => seo}}} = WordPress.normalize(row, "post", context)
        seo
      end

      assert served =~ "Elementor&#8217;s"

      refute is_map_key(seo.(row), "og_description"),
             "Yoast's Open Graph description is its default, the excerpt WordPress made of the post"

      head =
        Map.merge(row["yoast_head_json"], %{
          "title" => "Notes &amp; news &#8211; Mishka Test Blog",
          "description" => served,
          "twitter_title" => "Tom &amp;amp; Jerry"
        })

      meta = %{"_yoast_wpseo_opengraph-title" => "Elementor&#8217;s notes"}

      assert row
             |> Map.put("yoast_head_json", head)
             |> Map.update!("meta", &Map.merge(&1, meta))
             |> seo.()
             |> Map.take(["title", "description", "og_title", "twitter_title"]) == %{
               "title" => "Notes & news – Mishka Test Blog",
               "description" => shown,
               "og_title" => "Elementor’s notes",
               "twitter_title" => "Tom &amp; Jerry"
             }

      for {_id, item} <- Map.merge(items!("post"), items!("page")),
          {field, value} <- item.attrs["seo"],
          is_binary(value),
          do: refute(value =~ ~r/&#?\w+;/, "#{field} #{inspect(value)} holds an HTML entity")
    end

    defp media_requests(found) do
      receive do
        {:wordpress_request, %{request_path: "/wp-json/wp/v2/media"} = request} ->
          media_requests([request | found])

        {:wordpress_request, _other} ->
          media_requests(found)
      after
        0 -> Enum.reverse(found)
      end
    end

    test "a post's media name the candidates of its srcset, a size of a file too, in the same requests as its other files" do
      stub!()
      conn = connected!()
      [row] = Enum.filter(recorded("posts"), &(&1["id"] == 52))
      uploads = "http://localhost:8089/wp-content/uploads/2026/11/"

      content =
        ~s(<img src="#{uploads}hero.jpg" srcset="#{uploads}hero-300x169.jpg 300w, #{uploads}gallery-2.jpg 800w, https://cdn.example.test/x.jpg 2x">) <>
          ~s(<picture><source srcset="#{uploads}diagram-768x403.png 768w"></picture>)

      row = put_in(row, ["content", "raw"], content)

      assert {:ok, %{attrs: %{"media" => media}}} =
               WordPress.normalize(row, "post", Map.put(@context, :conn, conn))

      assert media == %{
               (uploads <> "hero.jpg") => 4,
               (uploads <> "hero-300x169.jpg") => 4,
               (uploads <> "gallery-2.jpg") => 7,
               (uploads <> "diagram-768x403.png") => 10
             }

      assert [%{query_params: %{"slug" => slugs}}] = media_requests([])
      assert ~w(hero gallery-2 diagram) -- String.split(slugs, ",") == []
    end

    test "a post's media name each file of the site its content shows or links to, by the file's id, a size of it too" do
      posts = items!("post")
      uploads = "http://localhost:8089/wp-content/uploads/2026/11/"

      assert posts["35"].attrs["media"] == %{
               (uploads <> "guide.pdf") => 13,
               (uploads <> "hero-300x169.jpg") => 4,
               (uploads <> "diagram.png") => 10
             }

      assert posts["34"].attrs["media"] == %{
               (uploads <> "hero.jpg") => 4,
               (uploads <> "hero-300x169.jpg") => 4,
               (uploads <> "gallery-1.jpg") => 6,
               (uploads <> "gallery-2.jpg") => 7,
               (uploads <> "gallery-3.jpg") => 8,
               (uploads <> "sample.mp4") => 14,
               (uploads <> "animated.gif") => 12
             }

      assert posts["52"].attrs["media"] == %{}
    end

    test "a post's media are asked for by the ids of its images and by the slugs of its files, with only the fields they need" do
      stub!()
      conn = connected!()
      [row] = Enum.filter(recorded("posts"), &(&1["id"] == 35))

      assert {:ok, _attrs} = WordPress.normalize(row, "post", Map.put(@context, :conn, conn))

      assert_received {:wordpress_request,
                       %{
                         request_path: "/wp-json/wp/v2/media",
                         query_params: %{"include" => "10", "_fields" => fields}
                       }}

      assert_received {:wordpress_request,
                       %{request_path: "/wp-json/wp/v2/media", query_params: %{"slug" => slugs}}}

      assert fields == "id,source_url,media_details"
      assert ~w(guide hero diagram) -- String.split(slugs, ",") == []
    end

    test "a post's links to the site's own posts name the post's slug, and its other links are left out" do
      posts = items!("post")

      assert posts["35"].attrs["links"] == %{
               "http://localhost:8089/2026/01/welcome-to-the-mishka-test-blog/" =>
                 "welcome-to-the-mishka-test-blog",
               "http://localhost:8089/?p=33" => "gutenberg-all-core-blocks",
               "/2026/01/gutenberg-all-core-blocks/" => "gutenberg-all-core-blocks",
               "http://localhost:8089/2025/11/classic-editor-with-shortcodes/#a-heading-after-the-more-tag" =>
                 "classic-editor-with-shortcodes"
             }

      assert posts["52"].attrs["links"] == %{}
    end

    test "a post's and a page's links to the site's pages name the page's address and id, and its other links are left out" do
      team = %{"link" => "http://localhost:8089/about/team/", "id" => "25"}

      assert items!("post")["35"].attrs["pages"] == %{
               "http://localhost:8089/?page_id=25" => team,
               "/about/team/" => team
             }

      pages = items!("page")

      assert pages["24"].attrs["pages"] == %{
               team["link"] => team,
               "http://localhost:8089/contact/" => %{
                 "link" => "http://localhost:8089/contact/",
                 "id" => "29"
               }
             }

      assert pages["25"].attrs["pages"] == %{}
      assert items!("post")["52"].attrs["pages"] == %{}
    end

    test "a link to a page of the site is found however it is written, and a feed, a category or a page the site no longer has is not" do
      stub!()
      conn = connected!()
      [row] = Enum.filter(recorded("pages"), &(&1["id"] == 22))

      content =
        ~s(<a href="http://localhost:8089/contact/?ref=nav#form">a</a> ) <>
          ~s(<a href="/docs/getting-started">b</a> ) <>
          ~s(<a href="http://LOCALHOST:8089/?page_id=27">c</a> ) <>
          ~s(<a href="http://localhost:8089/feed/">d</a> ) <>
          ~s(<a href="http://localhost:8089/category/news/">e</a> ) <>
          ~s(<a href="http://localhost:8089/gone/">f</a> ) <>
          ~s(<a href="https://elsewhere.test/contact/">g</a>)

      row = put_in(row, ["content", "raw"], content)

      assert {:ok, %{attrs: %{"pages" => pages}}} =
               WordPress.normalize(row, "page", Map.put(@context, :conn, conn))

      assert Map.keys(pages) |> Enum.sort() ==
               Enum.sort([
                 "http://localhost:8089/contact/?ref=nav#form",
                 "/docs/getting-started",
                 "http://LOCALHOST:8089/?page_id=27"
               ])

      assert pages["http://localhost:8089/contact/?ref=nav#form"] ==
               %{"link" => "http://localhost:8089/contact/", "id" => "29"}
    end

    test "a link a post answers is not asked of the pages again, and the pages are asked for by slug and by id with only the fields they need" do
      stub!()
      conn = connected!()
      [row] = Enum.filter(recorded("posts"), &(&1["id"] == 35))

      assert {:ok, _attrs} = WordPress.normalize(row, "post", Map.put(@context, :conn, conn))

      assert_received {:wordpress_request,
                       %{
                         request_path: "/wp-json/wp/v2/pages",
                         query_params: %{"slug" => slugs, "_fields" => "id,slug,link"}
                       }}

      assert_received {:wordpress_request,
                       %{
                         request_path: "/wp-json/wp/v2/pages",
                         query_params: %{"include" => "25", "status" => "any"}
                       }}

      assert ~w(team news elixir nadia this-post-was-deleted) -- String.split(slugs, ",") == []
      refute "welcome-to-the-mishka-test-blog" in String.split(slugs, ",")
    end

    test "a post's links are asked for by slug and by id, with only the fields they need" do
      stub!()
      conn = connected!()
      [row] = Enum.filter(recorded("posts"), &(&1["id"] == 35))

      assert {:ok, _attrs} = WordPress.normalize(row, "post", Map.put(@context, :conn, conn))

      assert_received {:wordpress_request,
                       %{
                         request_path: "/wp-json/wp/v2/posts",
                         query_params: %{"slug" => slugs, "_fields" => "id,slug,link"}
                       }}

      assert_received {:wordpress_request,
                       %{
                         request_path: "/wp-json/wp/v2/posts",
                         query_params: %{"include" => "33,25", "status" => "any"}
                       }}

      assert ~w(welcome-to-the-mishka-test-blog gutenberg-all-core-blocks
                classic-editor-with-shortcodes this-post-was-deleted) --
               String.split(slugs, ",") == []
    end

    test "a post's links and media are left as they are without the connection to ask WordPress" do
      [row] = Enum.filter(recorded("posts"), &(&1["id"] == 35))

      assert {:ok, %{attrs: %{"links" => links, "pages" => pages, "media" => media}}} =
               WordPress.normalize(row, "post", @context)

      assert {links, pages, media} == {%{}, %{}, %{}}
    end

    test "a row without the fields its kind needs is refused, and an unknown kind too" do
      [row | _] = recorded("posts-page-2")

      assert WordPress.normalize(row, "post", @context) == {:error, :unreadable}

      assert WordPress.normalize(row, "comment", @context) == {:error, :unreadable}
      assert WordPress.normalize(row, "menu", @context) == {:error, :unreadable}

      assert WordPress.normalize(row, "navigation", @context) ==
               {:error, {:unknown_kind, "navigation"}}
    end
  end

  describe "a post's content" do
    test "drops javascript:, vbscript: and data: addresses but an image's, in blocks and classic text" do
      raw = """
      <!-- wp:paragraph --><p><a href=" javascript:alert(1)">a</a> <a href="/kept">b</a></p><!-- /wp:paragraph -->
      <!-- wp:html --><form action="vbscript:x"><button formaction="javascript:y">c</button></form><!-- /wp:html -->
      <p><img src="data:image/gif;base64,R0lGOD"><iframe src="data:text/html,x"></iframe>
      <video poster="javascript:z" src="/v.mp4"></video></p>
      """

      html =
        raw
        |> Content.call(fn _route, _ids -> %{} end)
        |> Enum.map_join(& &1.html)
        |> LazyHTML.from_fragment()

      addresses =
        for name <- ~w(href src action formaction poster),
            address <- html |> LazyHTML.query("[#{name}]") |> LazyHTML.attribute(name),
            do: address

      assert addresses == ["/kept", "data:image/gif;base64,R0lGOD", "/v.mp4"]
      assert html |> LazyHTML.query("a, form, button, iframe, video") |> Enum.count() == 6
    end

    test "keeps its core blocks as their HTML, without WordPress's classes and block comments" do
      post = items!("post")["33"]
      html = html(post)

      assert texts(html, "p strong") == ["bold"]
      assert texts(html, "h2") == ["A level two heading"]
      assert texts(html, "h3") |> Enum.member?("A level three heading")
      assert texts(html, "ul > li > ul > li") == ["Nested one", "Nested two"]
      assert texts(html, "ol > li") == ["Step one", "Step two"]
      assert texts(html, "blockquote cite") |> Enum.member?("A migration proverb")
      assert texts(html, "table th") == ["Block", "Becomes"]
      assert [code] = texts(html, "pre > code")
      assert code =~ ~s(def world, do: "Hello <World> & friends")
      assert html |> LazyHTML.query("hr") |> Enum.count() == 1

      assert [figure | _] = Enum.to_list(LazyHTML.query(html, "figure:has(> a > img)"))

      assert sources(figure, "img") == [
               "http://localhost:8089/wp-content/uploads/2026/11/photo.webp"
             ]

      assert texts(figure, "figcaption") == ["An image linked to its file, with a caption"]

      assert sources(html, "figure > figure > img") |> Enum.map(&Path.basename/1) ==
               ["gallery-1.jpg", "gallery-2.jpg", "gallery-3.jpg"]

      assert html |> LazyHTML.query("[class]") |> LazyHTML.attribute("class") ==
               [
                 "grid gap-6 md:grid-cols-2",
                 "grid gap-6 md:grid-cols-2",
                 "grid gap-6",
                 "custom-widget",
                 "grid gap-6"
               ]

      refute Item.html(post) =~ "<!--"
      assert pieces(post) == []
    end

    test "lays its columns side by side and inlines the reusable block it names" do
      html = html(items!("post")["33"])

      assert texts(html, ".md\\:grid-cols-2 > div > p") == [
               "Text beside an image: the media-text block holds one media item and inner blocks.",
               "Left column.",
               "Right column."
             ]

      assert texts(html, ".grid h3") == ["Get the migration newsletter"]

      assert html
             |> LazyHTML.query(".grid a")
             |> LazyHTML.attribute("href")
             |> Enum.member?("http://localhost:8089/contact/")

      assert sources(html, "figure > iframe") == [@youtube_player]
    end

    test "makes paragraphs of a classic post and HTML of its core shortcodes" do
      post = items!("post")["34"]
      html = html(post)

      assert [first, second | _] = texts(html, "p")
      assert first =~ "written in the classic editor"
      assert second =~ "A second paragraph with bold text"
      assert texts(html, "p > strong") == ["bold"]
      assert texts(html, "h2") == ["A heading after the more tag"]
      assert texts(html, "ul > li") == ["One", "Two"]

      assert [caption] = Enum.to_list(LazyHTML.query(html, "figure:has(> figcaption)"))
      assert sources(caption, "img") |> Enum.map(&Path.basename/1) == ["hero-300x169.jpg"]
      assert texts(caption, "figcaption") == ["The hero image, with a caption"]

      assert html
             |> LazyHTML.query("figure > figure > a")
             |> LazyHTML.attribute("href")
             |> Enum.map(&Path.basename/1) ==
               ["gallery-1.jpg", "gallery-2.jpg", "gallery-3.jpg"]

      assert sources(html, "video") == [
               "http://localhost:8089/wp-content/uploads/2026/11/sample.mp4"
             ]

      assert sources(html, "figure > iframe") == [@youtube_player, @vimeo_player]

      assert "A video address alone on its line, which WordPress embeds by itself:" in texts(
               html,
               "p"
             )

      assert html |> LazyHTML.query("p:has(> img) > br") |> Enum.count() == 2
      assert texts(html, "pre") == ["preformatted\n   text keeps its spaces"]
      refute Item.html(post) =~ "[caption"
      refute Item.html(post) =~ "[gallery"
    end

    test "names a video's poster among the files of the media library it shows" do
      post = items!("post")["49"]
      gallery_2 = Enum.find(recorded("media"), &(&1["slug"] == "gallery-2"))

      assert post.attrs["media"][gallery_2["source_url"]] == gallery_2["id"]
    end

    test "plays a YouTube or Vimeo embed block, keeps an iframe the author wrote, and links any other embed" do
      html = html(items!("post")["49"])

      assert sources(html, "figure > iframe") == [@vimeo_player]

      assert sources(html, "iframe") == [
               @vimeo_player,
               "https://www.youtube.com/embed/jNQXAC9IVRw"
             ]

      assert [iframe] = Enum.to_list(LazyHTML.query(html, "figure > iframe"))
      assert LazyHTML.attribute(iframe, "title") == ["Vimeo video player"]

      embedded =
        ~s(<!-- wp:embed {"url":"https://x.example/status/1"} -->\n) <>
          ~s(<figure class="wp-block-embed"><div>https://x.example/status/1</div></figure>\n) <>
          ~s(<!-- /wp:embed -->\n\n) <>
          ~s([embed]https://youtu.be/jNQXAC9IVRw[/embed]\n\n) <>
          ~s(https://www.youtube.com/shorts/jNQXAC9IVRw\n\n) <>
          ~s(https://vimeo.com/76979871/0123abcdef\n\n) <>
          ~s(https://example.com/not-a-video\n)

      converted = embedded |> Content.call(fn _route, _ids -> %{} end) |> Enum.map_join(& &1.html)
      converted = LazyHTML.from_fragment(converted)

      assert sources(converted, "figure > iframe") == [
               @youtube_player,
               @youtube_player,
               @vimeo_player <> "?h=0123abcdef"
             ]

      assert converted |> LazyHTML.query("figure > a") |> LazyHTML.attribute("href") ==
               ["https://x.example/status/1"]

      assert texts(converted, "p") == ["https://example.com/not-a-video"]
    end

    test "leaves a shortcode, a plugin's block and a block WordPress draws itself to convert" do
      classic = items!("post")["34"]
      blocks = items!("post")["53"]

      assert [
               %{name: "unknown_plugin_shortcode", attrs: %{"id" => "7", "title" => "Unknown"}} =
                 unknown,
               %{name: "pullbox", attrs: %{"align" => "right"}} = pullbox
             ] = pieces(classic)

      assert unknown.raw == ~s([unknown_plugin_shortcode id="7" title="Unknown"])
      assert pullbox.raw =~ ~s([pullbox align="right"]Content inside an enclosing shortcode)
      assert pullbox.raw =~ "[/pullbox]"

      assert [
               %{name: "acme/callout", attrs: %{"tone" => "info", "title" => "Heads up"}} =
                 callout,
               %{name: "core/latest-posts", attrs: %{"postsToShow" => 2}}
             ] = pieces(blocks)

      assert callout.raw =~ "<strong>Heads up</strong>"
      assert texts(html(blocks), "p") |> Enum.member?("Page two starts here.")
    end

    test "leaves a reusable block and a gallery for a plugin when WordPress does not answer them" do
      posts =
        items!("post", %{"/wp-json/wp/v2/blocks" => :no_site, "/wp-json/wp/v2/media" => :no_site})

      assert [%{name: "core/block", attrs: %{"ref" => 54}, raw: raw}] = pieces(posts["33"])
      assert raw =~ "wp:block"
      assert texts(html(posts["33"]), "h3") == ["A level three heading"]

      assert %{name: "gallery", attrs: %{"ids" => "6,7,8", "columns" => "3", "link" => "file"}} =
               Enum.find(pieces(posts["34"]), &(&1.name == "gallery"))
    end
  end

  describe "a dry run" do
    test "reports every item it found: what to create, users with no CMS user, a file Media cannot keep, a tagline the CMS has no setting for, a redirect from each published post's address, menus a site with no layout has no place for" do
      stub!()
      site = create_site!()
      admin = migration_admin!(site)

      run =
        %{source: "wordpress", connection: @connection, secret: "app password"}
        |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)
        |> dry_run!(admin)

      assert run.status == :dry_run
      # The recorded site runs no Elementor, so it has no stylesheet of Elementor's globals.
      assert Enum.map(run.report.kinds, & &1.kind) == WordPress.kinds() -- ["stylesheet"]

      published = Enum.count(recorded("posts"), &(&1["status"] == "publish"))

      redirects =
        for %{kind: "post_redirect", source_id: id} = entry <- run.report.entries,
            into: %{},
            do: {id, {entry.outcome, entry.reason}}

      planned_posts =
        for %{kind: "post", source_id: id} = entry <- run.report.entries,
            into: %{},
            do: {id, {entry.outcome, entry.reason}}

      # A published post's addresses are planned as its own plan goes: one it writes as a draft is
      # not served, and one it does not write has no post to point at. The run keeps the WordPress
      # addresses, so a post it writes is served at its own and only its `?p=` is redirected.
      for post <- recorded("posts"), id = to_string(post["id"]) do
        expected =
          case planned_posts[id] do
            {:created, "draft_from_" <> _} -> {:skipped, "not_served"}
            {:created, _note} -> {:created, nil}
            _not_written -> {:skipped, "post_missing"}
          end

        own = if expected == {:created, nil}, do: {:skipped, "same_address"}, else: expected

        case post["status"] do
          "publish" -> assert {redirects[id], redirects[id <> "?p"]} == {own, expected}
          _not_public -> assert redirects[id] == {:skipped, "no_old_address"}
        end
      end

      assert Enum.count(redirects, &match?({_id, {:created, _}}, &1)) > 2 * published

      assert counts(run, "media") ==
               %{
                 created: length(recorded("media")) - 1,
                 updated: 0,
                 skipped: 1,
                 failed: 0,
                 undecided: 0
               }

      assert counts(run, "setting") == %{
               created: 5,
               updated: 0,
               skipped: 0,
               failed: 0,
               undecided: 0
             }

      assert counts(run, "menu") == %{created: 0, updated: 0, skipped: 1, failed: 0, undecided: 2}

      assert counts(run, "post") == %{
               created: length(recorded("posts")) - 3,
               updated: 0,
               skipped: 0,
               failed: 0,
               undecided: 3
             }

      assert for(
               %{kind: "post", outcome: :undecided} = entry <- run.report.entries,
               do: entry.reason
             ) == List.duplicate("player_not_allowed", 3)

      for %{kind: kind} = counts <- run.report.kinds,
          kind not in ["post_redirect", "media", "setting", "menu", "post"] do
        planned = Map.get(@written, kind, :skipped)

        assert Map.take(counts, MishkaCmsMigration.Report.outcomes()) ==
                 Map.put(
                   %{created: 0, updated: 0, skipped: 0, failed: 0, undecided: 0},
                   planned,
                   length(recorded(@recordings[kind]))
                 )
      end

      assert run.report.entries
             |> Enum.reject(&(&1.kind in ["page", "post"]))
             |> Enum.all?(
               &({&1.outcome, &1.reason} in [
                   {:created, nil},
                   {:created, "same_file_checked_at_download"},
                   {:skipped, "no_user"},
                   {:skipped, "no_setting"},
                   {:skipped, "no_layout"},
                   {:undecided, "menu_goes_to"},
                   {:skipped, "not_chosen"},
                   {:skipped, "no_old_address"},
                   {:skipped, "not_served"},
                   {:skipped, "post_missing"},
                   {:skipped, "not_imported"},
                   {:skipped, "same_address"},
                   {:skipped, "type_not_allowed"},
                   {:created, "path_made_ascii"}
                 ])
             )

      assert for(
               %{reason: "path_made_ascii"} = entry <- run.report.entries,
               entry.kind in ["tag", "category"],
               do: {entry.kind, entry.source_id}
             )
             |> Enum.sort() == [{"category", "9"}, {"tag", "20"}]

      assert Enum.any?(run.report.entries, &(&1.title == "نصب وردپرس روی سرور"))

      assert imported_items(site) == []
    end
  end
end
