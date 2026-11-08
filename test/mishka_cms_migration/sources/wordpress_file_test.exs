# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Sources.WordPressFileTest do
  @moduledoc """
  The WordPress export file source against the exports the seeded WordPress made
  (`test/fixtures/wordpress/wxr`) of the same site whose REST answers are recorded beside them: it
  reads the items the REST API gives, a dry run of the export reports what a dry run over the REST
  API reports, it pages through a kind, and a file that is not an export, or one that declares
  entities or a document type, is refused before anything in it is read.
  """
  use MishkaCmsMigration.DataCase, async: false

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0, recorded: 1]

  alias MishkaCmsMigration.Source
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Sources.{WordPress, WordPressFile}

  @all Path.expand("../../fixtures/wordpress/wxr/all-content.xml", __DIR__)
  @posts_only Path.expand("../../fixtures/wordpress/wxr/posts-only.xml", __DIR__)
  @context %{site_id: nil, run_id: nil, source_host: "localhost:8089", options: %{}}
  @connection %{"url" => "http://localhost:8089", "user" => "admin"}

  # What the REST API answers for each kind, as recorded. The source asks for comments of every
  # type; the recording of all comments was made without, so the pingback is its own recording.
  @recordings %{
    "user" => ["users"],
    "category" => ["categories"],
    "tag" => ["tags"],
    "media" => ["media"],
    "page" => ["pages"],
    "post" => ["posts"],
    "comment" => ["comments", "comments-pingback"]
  }

  # What an export does not carry ("Where it differs from the REST API" in the source's docs): the
  # site's logo and icon among its settings, and these attrs.
  @unexported_settings ["logo", "icon"]

  @not_exported %{
    "user" => ~w(avatar_urls description link nickname roles url),
    "category" => ["link"],
    "tag" => ["link"]
  }

  @namespaces ~s(xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:wp="http://wordpress.org/export/1.2/")

  defp built!(source, conn, rows, kind) do
    Map.new(rows, fn row ->
      assert {:ok, attrs} = source.normalize(row, kind, Map.put(@context, :conn, conn))
      assert {:ok, item} = attrs |> Map.put(:kind, kind) |> Item.build()
      {item.source_id, item}
    end)
  end

  defp file_items!(path, kind) do
    assert {:ok, conn} = WordPressFile.connect(%{"file" => path}, nil)
    built!(WordPressFile, conn, file_rows(conn, kind, nil), kind)
  end

  # What an export tells that the REST recording does not: a file's earlier slugs, and the posts
  # page, which the recording's settings, read without the right, do not name.
  defp export_only("post_redirect", items),
    do:
      for(
        id <- ids(items),
        String.match?(id, ~r/^media:\d+~/) or String.starts_with?(id, "archive:/blog/"),
        do: id
      )

  defp export_only(_kind, _items), do: []

  defp file_rows(conn, kind, cursor) do
    assert {:ok, rows, next} = WordPressFile.list(conn, kind, cursor)
    rows ++ if(next, do: file_rows(conn, kind, next), else: [])
  end

  defp rest_items!(kind) do
    stub!()
    {:ok, conn} = WordPress.connect(@connection, "app password")
    built!(WordPress, conn, rest_rows(conn, kind), kind)
  end

  defp rest_rows(conn, "setting") do
    {:ok, rows, nil} = WordPress.list(conn, "setting", nil)
    Enum.reject(rows, &(&1["id"] in @unexported_settings))
  end

  defp rest_rows(conn, kind) when kind in ["menu", "stylesheet"] do
    {:ok, rows, nil} = WordPress.list(conn, kind, nil)
    rows
  end

  defp rest_rows(conn, "post_redirect"), do: every_row(conn, nil)

  defp rest_rows(_conn, kind), do: Enum.flat_map(@recordings[kind], &recorded/1)

  defp every_row(conn, cursor) do
    {:ok, rows, next} = WordPress.list(conn, "post_redirect", cursor)
    rows ++ if(next, do: every_row(conn, next), else: [])
  end

  defp pieces(item), do: for(%{name: name} <- item.content || [], name != nil, do: name)

  # The attrs of an item read from the export and from the REST API, without what an export does
  # not carry: a draft's GMT date WordPress kept none for among it. An entry's SEO is compared on
  # its own: the REST API answers what Yoast served, an export what Yoast and Rank Math kept.
  defp compared(from_file, from_rest, "menu"),
    do: {unlinked_terms(from_file.attrs), unlinked_terms(from_rest.attrs)}

  defp compared(from_file, from_rest, kind) do
    left_out = ["seo" | Map.get(@not_exported, kind, [])] ++ undated(from_file.attrs)
    {Map.drop(from_file.attrs, left_out), Map.drop(from_rest.attrs, left_out)}
  end

  defp undated(%{"date_gmt" => nil}), do: ["date_gmt"]
  defp undated(_attrs), do: []

  # A term has no link in an export, so a menu's category or tag has WordPress's plain address.
  defp unlinked_terms(%{"items" => items} = node),
    do: node |> unlinked() |> Map.put("items", Enum.map(items, &unlinked_terms/1))

  defp unlinked(%{"kind" => kind} = item) when kind in ["category", "tag"],
    do: Map.delete(item, "url")

  defp unlinked(node), do: node

  defp ids(items), do: items |> Map.keys() |> Enum.sort()

  defp export!(dir, channel) do
    path = Path.join(dir, "export-#{System.unique_integer([:positive])}.xml")

    File.write!(path, """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" #{@namespaces}>
    <channel>
    <title>Small blog</title>
    <link>https://small.example.com/</link>
    <wp:wxr_version>1.2</wp:wxr_version>
    #{channel}
    </channel>
    </rss>
    """)

    path
  end

  defp post(id),
    do: """
    <item>
      <title><![CDATA[Post #{id}]]></title>
      <link>https://small.example.com/post-#{id}/</link>
      <wp:post_id>#{id}</wp:post_id>
      <wp:post_name>post-#{id}</wp:post_name>
      <wp:status>publish</wp:status>
      <wp:post_type>post</wp:post_type>
    </item>
    """

  defp counts(run),
    do: Map.new(run.report.kinds, &{&1.kind, Map.take(&1, MishkaCmsMigration.Report.outcomes())})

  defp staged!(path) do
    staged =
      Path.join(System.tmp_dir!(), "gervaz_#{System.unique_integer([:positive])}_export.xml")

    File.cp!(path, staged)
    on_exit(fn -> File.rm(staged) end)
    staged
  end

  defp file_run!(site, admin, path) do
    run =
      MishkaCmsMigration.create_run!(
        %{source: "wordpress_file", file: [%{path: staged!(path), client_name: "export.xml"}]},
        actor: admin,
        tenant: site.id
      )

    on_exit(fn -> File.rm(run.connection["file"]) end)
    run
  end

  describe "the source" do
    test "is installed beside WordPress, reads a file and asks for no connection keys" do
      assert {:ok, WordPressFile} = Source.fetch("wordpress_file")
      assert Source.file?("wordpress_file")
      refute Source.file?("wordpress")
      assert Source.form_fields("wordpress_file") == []
      assert WordPressFile.kinds() == WordPress.kinds()
    end

    test "takes the run's host from the export's home, and keeps the site's name, tagline and home" do
      assert WordPressFile.host(%{"file" => @all}) == "localhost:8089"
      assert WordPressFile.host(%{}) == nil

      assert {:ok, conn} = WordPressFile.connect(%{"file" => @all}, nil)

      assert %{
               "name" => "Mishka Test Blog",
               "description" =>
                 "A WordPress site filled with realistic content for testing the Mishka CMS migration",
               "home" => "http://localhost:8089"
             } = extra = WordPressFile.extra(conn)

      refute Map.has_key?(extra, "front_page")
    end

    test "keeps the structure of the posts' addresses as the REST API's links give it, and WordPress's own term bases" do
      stub!()
      {:ok, rest} = WordPress.connect(@connection, "app password")

      for path <- [@all, @posts_only] do
        assert {:ok, conn} = WordPressFile.connect(%{"file" => path}, nil)
        assert WordPressFile.extra(conn)["permalinks"] == WordPress.extra(rest)["permalinks"]
      end
    end

    @tag :tmp_dir
    test "is refused without a file, for a file that is not there, and for one that is not a WordPress export",
         %{tmp_dir: dir} do
      assert WordPressFile.connect(%{}, nil) == {:error, :no_file}

      assert WordPressFile.connect(%{"file" => Path.join(dir, "gone.xml")}, nil) ==
               {:error, :no_file}

      text = Path.join(dir, "notes.xml")
      File.write!(text, "Just some notes, not XML.")

      feed = Path.join(dir, "feed.xml")

      File.write!(
        feed,
        ~s(<rss version="2.0"><channel><link>https://feed.example.com/</link></channel></rss>)
      )

      broken = Path.join(dir, "broken.xml")
      File.write!(broken, @all |> File.read!() |> binary_part(0, 40_000))

      html = Path.join(dir, "page.xml")
      File.write!(html, "<html><body><p>A page</p></body></html>")

      for path <- [text, feed, broken, html] do
        assert WordPressFile.connect(%{"file" => path}, nil) == {:error, :unreadable_file}, path
      end

      assert WordPressFile.host(%{"file" => text}) == nil
      assert WordPressFile.host(%{"file" => html}) == nil
    end

    @tag :tmp_dir
    test "refuses an export that declares a document type or entities, expanding and fetching none of them",
         %{tmp_dir: dir} do
      secret = Path.join(dir, "secret.txt")
      File.write!(secret, "https://leaked.example.com/")

      dtd = Path.join(dir, "evil.dtd")
      File.write!(dtd, ~s(<!ENTITY home "https://leaked.example.com/">))

      laughs =
        Enum.map_join(1..9, "\n", fn level ->
          ~s(<!ENTITY lol#{level} "#{String.duplicate("&lol#{level - 1};", 10)}">)
        end)

      for {name, head, link} <- [
            {"billion laughs", "<!DOCTYPE rss [<!ENTITY lol0 \"lol\">\n#{laughs}]>", "&lol9;"},
            {"external entity", ~s(<!DOCTYPE rss [<!ENTITY home SYSTEM "file://#{secret}">]>),
             "&home;"},
            {"external DTD", ~s(<!DOCTYPE rss SYSTEM "file://#{dtd}">), "&home;"},
            {"parameter entity",
             ~s(<!DOCTYPE rss [<!ENTITY % dtd SYSTEM "file://#{dtd}"> %dtd;]>), "&home;"},
            {"a document type alone", "<!DOCTYPE rss>", "https://small.example.com/"}
          ] do
        path = Path.join(dir, "#{System.unique_integer([:positive])}.xml")

        File.write!(path, """
        <?xml version="1.0" encoding="UTF-8"?>
        #{head}
        <rss version="2.0" #{@namespaces}><channel><title>Evil</title><link>#{link}</link>
        <wp:wxr_version>1.2</wp:wxr_version></channel></rss>
        """)

        assert WordPressFile.connect(%{"file" => path}, nil) == {:error, :unreadable_file}, name
        assert WordPressFile.host(%{"file" => path}) == nil, name
      end
    end
  end

  describe "the items it reads" do
    test "are the ones the REST API gives for the same site: ids, titles, parents, slugs, statuses, every attr an export carries, and the content, converted alike" do
      for kind <- WordPressFile.kinds() do
        from_rest = rest_items!(kind)
        from_file = file_items!(@all, kind)

        assert ids(from_file) -- export_only(kind, from_file) == ids(from_rest), kind

        for {id, rest_item} <- from_rest do
          file_item = from_file[id]

          assert {file_item.title, file_item.parent, file_item.modified_at} ==
                   {rest_item.title, rest_item.parent, rest_item.modified_at}

          {file_attrs, rest_attrs} = compared(file_item, rest_item, kind)
          assert file_attrs == rest_attrs, "#{kind} #{id}"
          assert Item.html(file_item) == Item.html(rest_item), "#{kind} #{id}"
          assert pieces(file_item) == pieces(rest_item), "#{kind} #{id}"
        end
      end
    end

    test "point at the site's posts, pages and files the content links to, as the REST API's do" do
      post = file_items!(@all, "post")["35"]

      assert post.attrs["links"] != %{}
      assert post.attrs["pages"] != %{}
      assert post.attrs["media"] != %{}
      assert post.attrs["links"] == rest_items!("post")["35"].attrs["links"]
    end

    test "carry each menu once with its items, a category's address being WordPress's plain one" do
      menus = file_items!(@all, "menu")

      [news] =
        for item <- menus["22"].attrs["items"],
            child <- item["items"],
            child["id"] == "2",
            do: child

      assert ids(menus) == ["22", "23", "navigation-105"]
      assert {menus["22"].attrs["main"], menus["23"].attrs["main"]} == {true, false}
      assert {news["title"], news["url"]} == {"News", "http://localhost:8089/?cat=2"}
    end

    test "carry what an export has of an author, a term and a draft, and every meta field of a post" do
      author = file_items!(@all, "user")["2"]
      posts = file_items!(@all, "post")

      assert {author.title, author.attrs["username"], author.attrs["email"], author.attrs["slug"]} ==
               {"Shahryar Tavakkoli", "shahryar", "shahryar@mishka.tools", "shahryar"}

      assert Map.take(author.attrs, ~w(description avatar_urls)) == %{}
      refute Map.has_key?(file_items!(@all, "tag")["13"].attrs, "link")
      assert {posts["39"].attrs["status"], posts["39"].attrs["date_gmt"]} == {"draft", nil}

      assert Map.take(posts["32"].extra["meta"], ["subtitle", "_yoast_wpseo_title"]) == %{
               "subtitle" => "Start here",
               "_yoast_wpseo_title" => "Welcome to the Mishka Test Blog | Mishka Test Blog"
             }
    end

    @tag :tmp_dir
    test "carry each post's earlier slugs as the addresses it had, and none in its meta",
         %{tmp_dir: dir} do
      path =
        export!(dir, """
        <item>
          <title><![CDATA[Hello again]]></title>
          <link>https://small.example.com/2026/02/hello-again/</link>
          <wp:post_id>7</wp:post_id>
          <wp:post_date>2026-02-02 10:00:00</wp:post_date>
          <wp:post_name>hello-again</wp:post_name>
          <wp:status>publish</wp:status>
          <wp:post_type>post</wp:post_type>
          <wp:postmeta>
            <wp:meta_key>_wp_old_slug</wp:meta_key>
            <wp:meta_value><![CDATA[hello-world]]></wp:meta_value>
          </wp:postmeta>
          <wp:postmeta>
            <wp:meta_key>_wp_old_slug</wp:meta_key>
            <wp:meta_value><![CDATA[%d8%b3%d9%84%d8%a7%d9%85]]></wp:meta_value>
          </wp:postmeta>
        </item>
        <item>
          <title><![CDATA[A draft]]></title>
          <link>https://small.example.com/?p=8</link>
          <wp:post_id>8</wp:post_id>
          <wp:post_name>a-draft</wp:post_name>
          <wp:status>draft</wp:status>
          <wp:post_type>post</wp:post_type>
          <wp:postmeta>
            <wp:meta_key>_wp_old_slug</wp:meta_key>
            <wp:meta_value><![CDATA[first-draft]]></wp:meta_value>
          </wp:postmeta>
        </item>
        """)

      redirects = file_items!(path, "post_redirect")
      to = %{"kind" => "post", "id" => "7"}

      assert redirects["7"].attrs == %{
               "from" => "/2026/02/hello-again/",
               "query" => nil,
               "to" => to
             }

      assert redirects["7~hello-world"].attrs == %{
               "from" => "/2026/02/hello-world/",
               "query" => nil,
               "to" => to
             }

      assert redirects["7~%d8%b3%d9%84%d8%a7%d9%85"].attrs["from"] ==
               "/2026/02/%d8%b3%d9%84%d8%a7%d9%85/"

      assert redirects["8"].attrs["from"] == nil
      refute Enum.any?(Map.keys(redirects), &String.starts_with?(&1, ["8?", "8~"]))
      refute Map.has_key?(file_items!(path, "post")["7"].extra["meta"], "_wp_old_slug")
    end

    @tag :tmp_dir
    test "page the posts page's list and an author's archive, and keep a file's earlier attachment page",
         %{tmp_dir: dir} do
      page = fn id, link, parent, content ->
        """
        <item>
          <link>https://small.example.com#{link}</link>
          <content:encoded><![CDATA[#{content}]]></content:encoded>
          <wp:post_id>#{id}</wp:post_id>
          <wp:status>publish</wp:status>
          <wp:post_parent>#{parent}</wp:post_parent>
          <wp:post_type>page</wp:post_type>
        </item>
        """
      end

      posts =
        for id <- 1..11 do
          """
          <item>
            <link>https://small.example.com/post-#{id}/</link>
            <dc:creator>nadia</dc:creator>
            <wp:post_id>#{100 + id}</wp:post_id>
            <wp:post_date>2026-02-02 10:00:00</wp:post_date>
            <wp:post_name>post-#{id}</wp:post_name>
            <wp:status>publish</wp:status>
            <wp:post_type>post</wp:post_type>
          </item>
          """
        end

      path =
        export!(dir, """
        <wp:author><wp:author_id>3</wp:author_id><wp:author_login>nadia</wp:author_login></wp:author>
        #{page.(20, "/", 0, "")}
        #{page.(21, "/blog/", 0, "")}
        #{page.(22, "/about/", 0, "<p>About us</p>")}
        #{page.(23, "/about/team/", 22, "")}
        #{Enum.join(posts)}
        <item>
          <link>https://small.example.com/post-1/hero/</link>
          <wp:post_id>4</wp:post_id>
          <wp:post_name>hero</wp:post_name>
          <wp:status>inherit</wp:status>
          <wp:post_type>attachment</wp:post_type>
          <wp:postmeta>
            <wp:meta_key>_wp_old_slug</wp:meta_key>
            <wp:meta_value><![CDATA[hero-image]]></wp:meta_value>
          </wp:postmeta>
        </item>
        """)

      redirects = file_items!(path, "post_redirect")
      list = %{"kind" => "list", "id" => nil}

      assert redirects["archive:/blog/feed"].attrs["to"] == list
      assert redirects["archive:/blog/page/2"].attrs["to"] == Map.put(list, "page", 2)
      refute is_map_key(redirects, "archive:/about/page/2")

      assert redirects["user:3/page/2"].attrs == %{
               "from" => "/author/nadia/page/2",
               "query" => nil,
               "to" => %{"kind" => "user", "id" => "3", "page" => 2}
             }

      assert redirects["media:4~hero-image"].attrs == %{
               "from" => "/post-1/hero-image/",
               "query" => nil,
               "to" => %{"kind" => "media", "id" => "4"}
             }
    end

    @tag :tmp_dir
    test "page no list but the front's when the export has no one empty page at the top",
         %{tmp_dir: dir} do
      page = fn id, link ->
        """
        <item>
          <link>https://small.example.com#{link}</link>
          <wp:post_id>#{id}</wp:post_id>
          <wp:status>publish</wp:status>
          <wp:post_parent>0</wp:post_parent>
          <wp:post_type>page</wp:post_type>
        </item>
        """
      end

      path = export!(dir, page.(21, "/blog/") <> page.(22, "/news/"))
      ids = path |> file_items!("post_redirect") |> Map.keys()

      assert "archive:/feed" in ids
      refute Enum.any?(ids, &String.starts_with?(&1, ["archive:/blog", "archive:/news"]))
    end

    test "carry what Rank Math and Yoast SEO kept for a post or page, their variables as the CMS's own" do
      posts = file_items!(@all, "post")
      hero = Enum.find(recorded("media"), &(&1["slug"] == "hero"))

      assert posts["47"].attrs["seo"] == %{
               "title" => "{{page.title}} - Speed notes - {{site.name}}",
               "description" => "Where the time goes on a slow page, and what to measure first.",
               "robots" => "noindex, noarchive",
               "image" => hero["source_url"],
               "image_id" => hero["id"],
               "canonical" => "https://speed.example.test/performance-notes/"
             }

      assert posts["46"].attrs["seo"]["robots"] == "noindex, nofollow"
      assert posts["43"].attrs["seo"] == rest_items!("post")["43"].attrs["seo"]
      refute is_map_key(posts["33"].attrs["seo"], "canonical")

      assert file_items!(@all, "page")["27"].attrs["seo"]["title"] ==
               "{{page.title}} - Guides - {{site.name}}"
    end

    test "of an export of posts alone are its posts, with their authors, files and comments, and no page or term" do
      kinds = Map.new(WordPressFile.kinds(), &{&1, file_items!(@posts_only, &1)})
      posts = recorded("posts") |> Enum.map(&to_string(&1["id"])) |> Enum.sort()

      assert ids(kinds["post"]) == posts

      assert for(
               id <- ids(kinds["post_redirect"]),
               not String.contains?(id, ["?", ":", "/"]),
               do: id
             ) == posts

      refute Enum.any?(
               ids(kinds["post_redirect"]),
               &String.starts_with?(&1, ["page:", "category:", "tag:"])
             )

      assert {kinds["page"], kinds["category"], kinds["tag"]} == {%{}, %{}, %{}}
      assert ids(kinds["user"]) == ids(file_items!(@all, "user"))
      assert Enum.all?(Map.values(kinds["media"]), &(to_string(&1.attrs["post"]) in posts))
      assert Enum.all?(Map.values(kinds["comment"]), &(&1.attrs["post_type"] == "post"))

      assert Enum.all?(
               Map.values(kinds["post"]),
               &(&1.attrs["categories"] == [] and &1.attrs["tags"] == [])
             )
    end

    @tag :tmp_dir
    test "are listed 100 a page, each page read from the file again, and a kind it has none of is empty",
         %{tmp_dir: dir} do
      path = export!(dir, Enum.map_join(1..205, &post/1))
      assert {:ok, conn} = WordPressFile.connect(%{"file" => path}, nil)

      assert {:ok, first, 1} = WordPressFile.list(conn, "post", nil)
      assert {:ok, second, 2} = WordPressFile.list(conn, "post", 1)
      assert {:ok, third, nil} = WordPressFile.list(conn, "post", 2)

      assert {length(first), length(second), length(third)} == {100, 100, 5}
      assert Enum.map(first ++ second ++ third, & &1["id"]) == Enum.to_list(1..205)
      assert WordPressFile.list(conn, "page", nil) == {:ok, [], nil}
      assert WordPressFile.list(conn, "note", nil) == {:error, {:unknown_kind, "note"}}
    end
  end

  describe "a dry run" do
    test "of the export reports what a dry run over the REST API reports for the same site, but the logo and icon an export does not carry, and the pingback the REST recording left out besides" do
      stub!()
      site = create_site!()
      admin = migration_admin!(site)

      rest =
        %{source: "wordpress", connection: @connection, secret: "app password"}
        |> MishkaCmsMigration.create_run!(actor: admin, tenant: site.id)
        |> dry_run!(admin)

      file = site |> file_run!(admin, @all) |> dry_run!(admin)
      pingbacks = length(recorded("comments-pingback"))
      export_only = length(export_only("post_redirect", file_items!(@all, "post_redirect")))

      assert {file.status, file.source_host, file.extra["name"]} ==
               {:dry_run, rest.source_host, rest.extra["name"]}

      assert Enum.map(file.report.kinds, & &1.kind) == WordPressFile.kinds() -- ["stylesheet"]

      {file_redirects, file_counts} = file |> counts() |> Map.pop!("post_redirect")
      {rest_redirects, rest_counts} = rest |> counts() |> Map.pop!("post_redirect")

      assert file_counts ==
               rest_counts
               |> Map.update!("comment", &%{&1 | skipped: &1.skipped + pingbacks})
               |> Map.update!("setting", &%{&1 | created: &1.created - 2})

      assert file_redirects.created + file_redirects.skipped ==
               rest_redirects.created + rest_redirects.skipped + export_only

      assert imported_items(site) == []
    end
  end
end
