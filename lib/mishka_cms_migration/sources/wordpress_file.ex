# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Sources.WordPressFile do
  @moduledoc """
  The WordPress export file source (`"wordpress_file"`): a site read from the file WordPress makes
  under Tools ▸ Export (WXR), for a site whose REST API cannot be reached or signed in to. It gives
  the same items as the WordPress source (`MishkaCmsMigration.Sources.WordPress`), so a site moved
  from its export lands in the CMS as it does from its REST API, but for what an export does not
  carry (below), and a run of either finds what a run of the other wrote (both read from the same
  host).

  It reads a file (`file?/0`): the New import form asks for the export, an `.xml` file, and no
  connection keys (`form_fields/0` is empty), and the run keeps the file until it ends
  (`MishkaCmsMigration.MigrationRun`'s "The source's file"); its path is the connection's `"file"`.
  The file is streamed (`MishkaCmsMigration.Sources.WordPress.Export`), never read whole, and one
  that declares a document type, entities or anything it would fetch is refused.

  `host/1` is the host of the export's `<link>`, the site's home, which is also where its files are
  downloaded from (`MishkaCmsMigration.Targets.CmsMedia`). `connect/2` reads the whole file once,
  refusing with one of these reasons:

    * `:no_file` — the connection names no file, or none is there;
    * `:unreadable_file` — the file is not a WordPress export: not XML, not an `<rss>` channel
      with a `wp:wxr_version` and a `<link>`, broken off, or one that declares a document type.

  While it reads, it keeps what the items point at: the authors by login, the categories and tags
  by slug, how many published posts each term has, and the id, slug and address of each post and
  page, the address, alt text and sizes of each file, and the content of each reusable block. That
  is how it answers the reads the WordPress source's `normalize/3` makes with its connection's
  `read` (the blocks and gallery images of a post's content, the posts, pages and files its links
  point at), from the file instead of the site. `extra/1` keeps the site's name, tagline and home.

  ## What it reads

  `kinds/0` is the WordPress source's, in its order. `list/3` reads the file again for each page of
  100 rows of a kind, from the top, and stops at the row after the page's last; the cursor is the
  next page's number. Each row is the shape the REST API answers for that kind, built from the
  export, and `normalize/3` is the WordPress source's own, so its items carry the same attrs, extra
  and content, converted the same way:

    * setting — the site's name and tagline, the channel's `title` and `description`, read once
      when the file is opened;
    * stylesheet — Elementor's global colours and fonts, read once when the file is opened from
      the settings (`_elementor_page_settings`) of its kit, the `elementor_library` item whose
      `_elementor_template_type` is `kit`, as the REST API's `/elementor/v1/globals` answers them
      (`MishkaCmsMigration.Sources.WordPress.ElementorKit.from_settings/1`). An export does not say
      which kit is active, so of two the one made last is read; an export with none has no row;
    * user — each `wp:author`: its id, login (`username`), display name (`name`), first and last
      name, email, and a `slug` made of the login the way the CMS slugs a name;
    * category and tag — each `wp:category` and `wp:tag`: its id, name, slug, description, how
      many published posts carry it (`count`) and, for a category, its parent's id;
    * media — each `attachment` item: its title, slug, address (`source_url`, the
      `wp:attachment_url`), type (`mime_type`, from its file name), alt text, caption, description,
      the post it was uploaded to, its dates, and its `media_details` (`_wp_attachment_metadata`,
      its size in bytes and the address of each size WordPress made of it);
    * page and post — each `page` and `post` item, but the trash: title, content, excerpt, slug,
      status, address (`link`), author's id, dates, featured file (`_thumbnail_id`), template, its
      other meta under `meta`, and a page's parent, menu order and `permalink_template` (its
      parent's address, or the home, with `%pagename%/`), a post's categories and tags by id,
      whether it is sticky and its format;
    * comment — each `wp:comment` of an item that is not in the trash, approved or held for
      moderation, with its post, parent, author, text, status, type and dates;
    * post_redirect — each post again, its id, title, status, address and modified time, its old
      address being the path of its `<link>`;
    * menu — each `nav_menu` term (`wp:term`, which an export may list twice) with its
      `nav_menu_item` items, whose own fields are their meta (`_menu_item_type`,
      `_menu_item_object`, `_menu_item_object_id`, `_menu_item_menu_item_parent`,
      `_menu_item_url`, `_menu_item_target`), read in one pass
      (`MishkaCmsMigration.Sources.WordPress.menus/4`). An item with no label of its own takes the
      title of the page or post, or the name of the category or tag, it points at, and its address
      too; one whose page, post or term the export does not carry is invalid, as WordPress counts
      it. Each `wp_navigation` post is a block menu too, as the REST API answers it.

  ## Languages

  An export of a site that runs Polylang or WPML carries the language of each entry and term, and
  which entries and terms are editions of one another, and a page, a post, a category and a tag row
  carries them as Polylang Pro's REST API does, `lang` and `translations` (every edition's id by
  language, the row's own among them), which the WordPress source reads into the item
  (`MishkaCmsMigration.Sources.WordPress`, "Languages"):

    * Polylang keeps them as its own taxonomies, which an export carries as terms (`wp:term`): an
      entry names its `language` term (its slug is the code) and its `post_translations` term, and
      each `post_translations` and `term_translations` term describes its group as a serialized
      map of code to id. A term's language is its code in the `term_translations` group that names
      it; a term in none says no language;
    * WPML, with its WPML Export and Import, keeps them in an entry's meta and a term's meta
      (`_wpml_import_language_code`, the code, and `_wpml_import_translation_group`, a value every
      edition of one entry shares; https://wpml.org/documentation/translating-your-contents/multilingual-content-import/).
      These are not kept in `meta`.

  `extra/1` keeps which plugin the export came from as `"languages"` (`"polylang"` or `"wpml"`),
  as the WordPress source does for a site.

  ## Where it differs from the REST API

  An export carries less than the REST API answers, and some of it otherwise:

    * the site's logo and icon are options, which an export does not carry, so only its name and
      tagline are read;
    * an author has no bio, website, avatar, nickname or roles, so a blogger made from one has
      none, and its slug is made of its login rather than WordPress's own `user_nicename`;
    * a term has no `link`, so a menu item of a category or a tag has WordPress's plain address of
      it (`/?cat=<id>`, `/?tag=<slug>`), which WordPress answers whatever its permalinks;
    * a menu's theme locations are the theme's, which an export does not carry, so the main menu
      is the first made;
    * a draft, pending or scheduled entry WordPress kept no GMT date for has no `date_gmt` (the
      export gives only the site's own time, not its timezone), and no entry has a `generated_slug`;
    * `meta` holds every meta field of the entry the export carries (custom fields among them,
      such as `subtitle`), where the REST API answers only those a plugin registered;
    * an export of posts alone (Tools ▸ Export ▸ Posts) carries the authors, files and comments of
      its posts but no categories, tags or pages, so its posts come without their categories and
      tags; an export of all content carries both.

  `MishkaCmsMigration.Source.Item.hash/1` covers `extra`, so an item read from an export and later
  from the REST API, or the other way round, is updated once.
  """

  use MishkaCmsMigration.Source, id: "wordpress_file", label: "WordPress export file"

  alias MishkaCmsMigration.Source
  alias MishkaCmsMigration.Sources.WordPress
  alias MishkaCmsMigration.Sources.WordPress.{ElementorKit, Export}

  import Export, only: [text: 1, text: 2]

  @per_page 100

  @hidden ["trash", "auto-draft"]
  @entries ["page", "post"]
  @listed_comments %{"1" => "approved", "0" => "hold"}
  @site ["title", "description", "link", "wp:wxr_version"]

  @routes %{
    "post" => "/wp/v2/posts",
    "page" => "/wp/v2/pages",
    "attachment" => "/wp/v2/media",
    "wp_block" => "/wp/v2/blocks"
  }

  @terms %{
    "wp:category" =>
      {"category", "wp:category_nicename", "wp:cat_name", "wp:category_description"},
    "wp:tag" => {"post_tag", "wp:tag_slug", "wp:tag_name", "wp:tag_description"}
  }

  @wpml_meta ~w(_wpml_import_language_code _wpml_import_source_language_code
                _wpml_import_translation_group)
  @mapped_meta ~w(_thumbnail_id _wp_page_template _wp_attached_file _wp_attachment_metadata
                  _wp_attachment_image_alt) ++ @wpml_meta

  @indexed_media ~w(id slug link source_url alt_text media_details)

  @menu_found %{home: nil, menus: [], items: [], objects: %{}, navigation: []}
  @term_links %{"category" => "/?cat=", "post_tag" => "/?tag="}
  @menu_meta ~w(_menu_item_type _menu_item_object _menu_item_object_id
                _menu_item_menu_item_parent _menu_item_url _menu_item_target)

  @editions %{plugin: nil, groups: %{}, terms: %{}, wpml: %{}}

  @found %{
    site: %{},
    authors: %{},
    terms: %{"category" => %{}, "post_tag" => %{}},
    counts: %{},
    rows: %{},
    kits: %{},
    editions: @editions
  }

  @kinds WordPress.kinds()

  @impl MishkaCmsMigration.Source
  def kinds, do: @kinds

  @impl MishkaCmsMigration.Source
  def form_fields, do: []

  @impl MishkaCmsMigration.Source
  def file?, do: true

  @impl MishkaCmsMigration.Source
  def host(%{"file" => path}) when is_binary(path),
    do: path |> Export.fold(nil, &home/3) |> host_of()

  def host(_connection), do: nil

  @impl MishkaCmsMigration.Source
  def connect(%{"file" => path}, _secret) when is_binary(path),
    do: path |> Export.fold(@found, &indexed/3) |> connected(path)

  def connect(_connection, _secret), do: {:error, :no_file}

  @impl MishkaCmsMigration.Source
  def extra(%{index: index}), do: index

  @impl MishkaCmsMigration.Source
  def list(conn, kind, cursor) when kind in ["setting", "stylesheet"],
    do: WordPress.list(conn, kind, cursor)

  def list(%{file: path, index: %{"home" => home}}, "menu", _cursor),
    do: path |> Export.fold(%{@menu_found | home: home}, &menu_found/3) |> menus_found()

  def list(%{file: path} = conn, kind, cursor) when kind in @kinds do
    page = cursor || 0

    path
    |> Export.fold(
      %{rows: [], count: 0, skip: page * @per_page, more?: false},
      &paged(&1, &2, &3, {kind, conn})
    )
    |> listed(page)
  end

  def list(_conn, kind, _cursor), do: {:error, {:unknown_kind, kind}}

  @impl MishkaCmsMigration.Source
  def normalize(row, kind, context), do: WordPress.normalize(row, kind, context)

  defp home("link", element, _link), do: {:halt, text(element)}
  defp home("item", _element, link), do: {:halt, link}
  defp home(_name, _element, link), do: {:cont, link}

  defp host_of({:ok, link}) when is_binary(link), do: Source.url_host(%{"url" => link})
  defp host_of(_no_link), do: nil

  defp indexed(name, element, found) when name in @site,
    do: {:cont, put_in(found, [:site, name], text(element))}

  defp indexed("wp:author", element, found),
    do:
      {:cont,
       put_in(
         found,
         [:authors, text(element, "wp:author_login")],
         integer(text(element, "wp:author_id"))
       )}

  defp indexed(name, element, found) when is_map_key(@terms, name) do
    {taxonomy, slug, _name, _description} = Map.fetch!(@terms, name)
    id = integer(text(element, "wp:term_id"))

    {:cont,
     found
     |> put_in([:terms, taxonomy, text(element, slug)], id)
     |> update_in([:editions], &wpml_indexed(&1, taxonomy, id, meta(element, "wp:termmeta")))}
  end

  defp indexed("wp:term", element, found),
    do:
      {:cont,
       update_in(
         found,
         [:editions],
         &polylang_indexed(&1, text(element, "wp:term_taxonomy"), element)
       )}

  defp indexed("item", element, found),
    do:
      {:cont, element |> item_type() |> item_indexed(text(element, "wp:status"), element, found)}

  defp indexed(_name, _element, found), do: {:cont, found}

  defp item_indexed(_type, status, _element, found) when status in @hidden, do: found

  defp item_indexed(type, status, element, found) when is_map_key(@routes, type) do
    row = indexed_row(type, element, found.authors)

    found
    |> update_in([:rows, Map.fetch!(@routes, type)], &[row | &1 || []])
    |> counted(type, status, element)
    |> update_in([:editions], &entry_indexed(&1, type, element))
  end

  defp item_indexed("elementor_library", _status, element, found),
    do: element |> meta("wp:postmeta") |> kit_indexed(element, found)

  defp item_indexed(_type, _status, _element, found), do: found

  defp kit_indexed(%{"_elementor_template_type" => "kit"} = meta, element, found),
    do:
      put_in(
        found,
        [:kits, integer(text(element, "wp:post_id"))],
        Export.php(meta["_elementor_page_settings"])
      )

  defp kit_indexed(_meta, _element, found), do: found

  defp indexed_row("attachment", element, authors),
    do: element |> media(authors) |> Map.take(@indexed_media)

  defp indexed_row("wp_block", element, _authors),
    do: %{
      "id" => integer(text(element, "wp:post_id")),
      "slug" => text(element, "wp:post_name"),
      "content" => %{"raw" => text(element, "content:encoded") || ""}
    }

  defp indexed_row(_entry, element, _authors),
    do: %{
      "id" => integer(text(element, "wp:post_id")),
      "slug" => text(element, "wp:post_name"),
      "link" => text(element, "link")
    }

  defp counted(found, "post", "publish", element),
    do:
      Enum.reduce(Export.all(element, "category"), found, fn reference, found ->
        key = {Export.attribute(reference, "domain"), Export.attribute(reference, "nicename")}
        update_in(found, [:counts, key], &((&1 || 0) + 1))
      end)

  defp counted(found, _type, _status, _element), do: found

  defp entry_indexed(editions, type, element) when type in @entries,
    do:
      wpml_indexed(
        editions,
        type,
        integer(text(element, "wp:post_id")),
        meta(element, "wp:postmeta")
      )

  defp entry_indexed(editions, _type, _element), do: editions

  defp wpml_indexed(
         editions,
         type,
         id,
         %{"_wpml_import_language_code" => language, "_wpml_import_translation_group" => group}
       )
       when is_binary(language) and language != "" and is_binary(group) and group != "",
       do: %{
         editions
         | plugin: editions.plugin || "wpml",
           wpml:
             Map.update(
               editions.wpml,
               {type, group},
               %{language => id},
               &Map.put(&1, language, id)
             )
       }

  defp wpml_indexed(editions, _type, _id, _meta), do: editions

  defp polylang_indexed(editions, "language", _element), do: %{editions | plugin: "polylang"}

  defp polylang_indexed(editions, "post_translations", element),
    do:
      put_in(
        editions,
        [:groups, text(element, "wp:term_slug")],
        group(text(element, "wp:term_description"))
      )

  defp polylang_indexed(editions, "term_translations", element) do
    group = group(text(element, "wp:term_description"))
    %{editions | terms: Enum.reduce(group, editions.terms, &Map.put(&2, elem(&1, 1), group))}
  end

  defp polylang_indexed(editions, _taxonomy, _element), do: editions

  defp group(description), do: description |> Export.php() |> group_ids()

  defp group_ids(%{} = group),
    do: for({language, id} <- group, is_integer(id), into: %{}, do: {language, id})

  defp group_ids(_not_a_group), do: %{}

  defp connected({:ok, %{site: %{"wp:wxr_version" => _, "link" => link} = site} = found}, path)
       when is_binary(link) do
    rows = Map.new(found.rows, fn {route, rows} -> {route, Enum.reverse(rows)} end)
    home = String.trim_trailing(link, "/")

    {:ok,
     %{
       file: path,
       index:
         %{"name" => site["title"], "description" => site["description"], "home" => home}
         |> languages(found.editions.plugin),
       read: &read(rows, &1, &2),
       authors: found.authors,
       terms: found.terms,
       counts: found.counts,
       editions: found.editions,
       elementor: kit(found.kits),
       under: under(Map.get(rows, "/wp/v2/pages", []), home)
     }}
  end

  defp connected({:ok, _not_an_export}, _path), do: {:error, :unreadable_file}
  defp connected(refused, _path), do: refused

  # The kit made last, which an export cannot tell from the active one.
  defp kit(kits) when map_size(kits) == 0, do: %{}
  defp kit(kits), do: kits |> Enum.max_by(&elem(&1, 0)) |> elem(1) |> ElementorKit.from_settings()

  defp languages(index, nil), do: index
  defp languages(index, plugin), do: Map.put(index, "languages", plugin)

  defp under(pages, home),
    do:
      Map.new(
        [{0, home <> "/"}] ++ for(%{"id" => id, "link" => link} <- pages, do: {id, own(link)})
      )

  defp own(link) when is_binary(link), do: link |> URI.parse() |> own_address(link)
  defp own(_no_link), do: nil

  defp own_address(%URI{query: nil, path: "/" <> _}, link),
    do: String.trim_trailing(link, "/") <> "/"

  defp own_address(_uri, _link), do: nil

  defp read(rows, route, params),
    do: rows |> Map.get(route, []) |> narrowed(params) |> Map.new(&{&1["id"], &1})

  defp narrowed(rows, params), do: Enum.reduce(params, rows, &narrowed_by/2)

  defp narrowed_by({:include, ids}, rows) do
    asked = ids |> to_string() |> String.split(",") |> Enum.map(&integer/1) |> MapSet.new()
    Enum.filter(rows, &(&1["id"] in asked))
  end

  defp narrowed_by({:slug, slugs}, rows) do
    asked = slugs |> to_string() |> String.split(",") |> MapSet.new(&slug_asked/1)
    Enum.filter(rows, &(String.downcase(&1["slug"] || "") in asked))
  end

  defp narrowed_by(_param, rows), do: rows

  defp slug_asked(slug),
    do: slug |> String.downcase() |> URI.encode(&URI.char_unreserved?/1) |> String.downcase()

  defp paged(name, element, page, {kind, conn}),
    do: name |> rows(element, kind, conn) |> Enum.reduce({:cont, page}, &paged_row/2)

  defp paged_row(_row, {:halt, page}), do: {:halt, page}

  defp paged_row(_row, {:cont, %{skip: skip} = page}) when skip > 0,
    do: {:cont, %{page | skip: skip - 1}}

  defp paged_row(_row, {:cont, %{count: @per_page} = page}), do: {:halt, %{page | more?: true}}

  defp paged_row(row, {:cont, page}),
    do: {:cont, %{page | rows: [row | page.rows], count: page.count + 1}}

  defp listed({:ok, %{rows: rows, more?: more?}}, page),
    do: {:ok, Enum.reverse(rows), next_page(more?, page)}

  defp listed(refused, _page), do: refused

  defp next_page(true, page), do: page + 1
  defp next_page(false, _page), do: nil

  defp rows("wp:author", element, "user", _conn), do: [user(element)]

  defp rows("wp:category", element, "category", conn), do: [term("wp:category", element, conn)]
  defp rows("wp:tag", element, "tag", conn), do: [term("wp:tag", element, conn)]

  defp rows("item", element, kind, conn),
    do: element |> item_type() |> item_rows(text(element, "wp:status"), element, {kind, conn})

  defp rows(_name, _element, _kind, _conn), do: []

  defp item_rows(_type, status, _element, _asked) when status in @hidden, do: []

  defp item_rows("attachment", _status, element, {"media", conn}),
    do: [media(element, conn.authors)]

  defp item_rows(type, _status, element, {type, conn}) when type in @entries,
    do: [entry(type, element, conn)]

  defp item_rows("post", _status, element, {"post_redirect", _conn}),
    do: [element |> posted(%{}) |> Map.take(~w(id title status link modified_gmt))]

  defp item_rows(type, _status, element, {"comment", _conn}), do: comments(type, element)
  defp item_rows(_type, _status, _element, _asked), do: []

  defp item_type(element), do: text(element, "wp:post_type")

  defp menu_found("wp:term", element, found),
    do: {:cont, element |> text("wp:term_taxonomy") |> menu_term(element, found)}

  defp menu_found(name, element, found) when is_map_key(@terms, name) do
    {taxonomy, slug_key, name_key, _description} = Map.fetch!(@terms, name)
    id = integer(text(element, "wp:term_id"))
    asked = term_asked(taxonomy, id, text(element, slug_key))
    link = found.home <> Map.fetch!(@term_links, taxonomy) <> asked

    {:cont, put_in(found, [:objects, {taxonomy, id}], {text(element, name_key), link})}
  end

  defp menu_found("item", element, found),
    do: {:cont, element |> item_type() |> menu_entry(text(element, "wp:status"), element, found)}

  defp menu_found(_name, _element, found), do: {:cont, found}

  defp menu_term("nav_menu", element, found),
    do: %{
      found
      | menus: [
          %{
            "id" => integer(text(element, "wp:term_id")),
            "name" => text(element, "wp:term_name"),
            "slug" => text(element, "wp:term_slug"),
            "description" => text(element, "wp:term_description") || "",
            "locations" => []
          }
          | found.menus
        ]
    }

  defp menu_term(_taxonomy, _element, found), do: found

  defp menu_entry(_type, status, _element, found) when status in @hidden, do: found

  defp menu_entry("nav_menu_item", _status, element, found),
    do: %{found | items: [menu_item(element) | found.items]}

  defp menu_entry("wp_navigation", _status, element, found),
    do: %{found | navigation: [navigation(element) | found.navigation]}

  defp menu_entry(type, _status, element, found) when type in @entries,
    do:
      put_in(
        found,
        [:objects, {type, integer(text(element, "wp:post_id"))}],
        {text(element, "title"), text(element, "link")}
      )

  defp menu_entry(_type, _status, _element, found), do: found

  defp menu_item(element) do
    meta = element |> meta("wp:postmeta") |> Map.take(@menu_meta)

    %{
      "id" => integer(text(element, "wp:post_id")),
      "title" => %{"raw" => text(element, "title") || ""},
      "url" => meta["_menu_item_url"],
      "type" => meta["_menu_item_type"],
      "object" => meta["_menu_item_object"],
      "object_id" => integer(meta["_menu_item_object_id"]),
      "parent" => integer(meta["_menu_item_menu_item_parent"]) || 0,
      "menu_order" => integer(text(element, "wp:menu_order")) || 0,
      "target" => meta["_menu_item_target"] || "",
      "menu" => menu_slug(element)
    }
  end

  defp navigation(element),
    do: %{
      "id" => integer(text(element, "wp:post_id")),
      "slug" => text(element, "wp:post_name") || "",
      "title" => %{"raw" => text(element, "title") || ""},
      "content" => %{"raw" => text(element, "content:encoded") || ""}
    }

  defp menu_slug(element), do: referenced(element, "nav_menu")

  defp term_asked("category", id, _slug), do: to_string(id)
  defp term_asked("post_tag", _id, slug), do: to_string(slug)

  defp menus_found({:ok, found}) do
    menus = found.menus |> Enum.reverse() |> Enum.uniq_by(& &1["id"])
    ids = Map.new(menus, &{&1["slug"], &1["id"]})

    items =
      for item <- Enum.reverse(found.items),
          do:
            item
            |> Map.delete("menu")
            |> Map.put("menus", ids[item["menu"]])
            |> pointed(found.objects)

    {:ok, WordPress.menus(menus, items, Enum.reverse(found.navigation), found.home), nil}
  end

  defp menus_found(refused), do: refused

  defp pointed(%{"type" => "custom"} = item, _objects), do: item

  defp pointed(%{"object" => object, "object_id" => id} = item, objects),
    do: objects |> Map.get({object, id}) |> pointed_at(item)

  defp pointed_at({title, url}, %{"title" => %{"raw" => own}} = item),
    do: %{item | "title" => %{"raw" => labelled(own, title)}, "url" => url}

  defp pointed_at(nil, item), do: Map.put(item, "invalid", true)

  defp labelled("", title), do: title || ""
  defp labelled(own, _title), do: own

  defp user(element) do
    login = text(element, "wp:author_login")

    %{
      "id" => integer(text(element, "wp:author_id")),
      "username" => login,
      "name" => text(element, "wp:author_display_name"),
      "first_name" => text(element, "wp:author_first_name"),
      "last_name" => text(element, "wp:author_last_name"),
      "email" => text(element, "wp:author_email"),
      "slug" => Slug.slugify(login || "")
    }
  end

  defp term(name, element, conn) do
    {taxonomy, slug_key, name_key, description_key} = Map.fetch!(@terms, name)
    slug = text(element, slug_key)
    id = integer(text(element, "wp:term_id"))

    %{
      "id" => id,
      "name" => text(element, name_key),
      "slug" => slug,
      "description" => text(element, description_key) || "",
      "count" => Map.get(conn.counts, {taxonomy, slug}, 0),
      "taxonomy" => taxonomy
    }
    |> parented(name, element, conn)
    |> Map.merge(
      term_edition(conn.editions.terms[id], id, {taxonomy, meta(element, "wp:termmeta")}, conn)
    )
  end

  defp term_edition(%{} = group, id, _wpml, _conn),
    do:
      edition(
        Enum.find_value(group, fn
          {language, ^id} -> language
          _other -> nil
        end),
        group
      )

  defp term_edition(nil, id, {taxonomy, meta}, conn), do: wpml_edition(taxonomy, id, meta, conn)

  defp entry_edition(element, id, meta, conn),
    do: element |> referenced("language") |> entry_language(element, {id, meta}, conn)

  defp entry_language(nil, element, {id, meta}, conn),
    do: wpml_edition(item_type(element), id, meta, conn)

  defp entry_language(language, element, {id, _meta}, conn),
    do: edition(language, conn.editions.groups[referenced(element, "post_translations")], id)

  defp wpml_edition(
         type,
         id,
         %{"_wpml_import_language_code" => language, "_wpml_import_translation_group" => group},
         conn
       )
       when is_binary(language) and language != "",
       do: edition(language, conn.editions.wpml[{type, group}], id)

  defp wpml_edition(_type, _id, _meta, _conn), do: %{}

  defp edition(nil, _group), do: %{}
  defp edition(language, group), do: %{"lang" => language, "translations" => group}

  defp edition(language, nil, id), do: edition(language, %{language => id})
  defp edition(language, group, _id), do: edition(language, group)

  defp referenced(element, taxonomy),
    do:
      Enum.find_value(Export.all(element, "category"), fn reference ->
        Export.attribute(reference, "domain") == taxonomy and
          Export.attribute(reference, "nicename")
      end)

  defp parented(term, "wp:category", element, conn),
    do:
      Map.put(
        term,
        "parent",
        Map.get(conn.terms["category"], text(element, "wp:category_parent"), 0)
      )

  defp parented(term, _tag, _element, _conn), do: term

  defp posted(element, authors),
    do: %{
      "id" => integer(text(element, "wp:post_id")),
      "date" => datetime(text(element, "wp:post_date")),
      "date_gmt" => datetime(text(element, "wp:post_date_gmt")),
      "modified" => datetime(text(element, "wp:post_modified")),
      "modified_gmt" => datetime(text(element, "wp:post_modified_gmt")),
      "guid" => %{"raw" => text(element, "guid")},
      "slug" => text(element, "wp:post_name") || "",
      "status" => text(element, "wp:status"),
      "type" => item_type(element),
      "link" => text(element, "link"),
      "title" => %{"raw" => text(element, "title") || ""},
      "author" => Map.get(authors, text(element, "dc:creator"), 0),
      "comment_status" => text(element, "wp:comment_status"),
      "ping_status" => text(element, "wp:ping_status")
    }

  defp entry(type, element, conn) do
    meta = meta(element, "wp:postmeta")
    row = posted(element, conn.authors)

    row
    |> Map.merge(%{
      "password" => text(element, "wp:post_password") || "",
      "content" => %{"raw" => text(element, "content:encoded") || ""},
      "excerpt" => %{"raw" => text(element, "excerpt:encoded") || ""},
      "featured_media" => integer(meta["_thumbnail_id"]) || 0,
      "template" => template(meta["_wp_page_template"]),
      "meta" => Map.drop(meta, @mapped_meta)
    })
    |> Map.merge(typed(type, element, conn))
    |> Map.merge(entry_edition(element, row["id"], meta, conn))
  end

  defp typed("post", element, conn),
    do: %{
      "sticky" => text(element, "wp:is_sticky") == "1",
      "format" => format(element),
      "categories" => terms(element, "category", conn),
      "tags" => terms(element, "post_tag", conn)
    }

  defp typed("page", element, conn) do
    parent = integer(text(element, "wp:post_parent")) || 0

    %{
      "parent" => parent,
      "menu_order" => integer(text(element, "wp:menu_order")) || 0,
      "permalink_template" => (conn.under[parent] || conn.under[0]) <> "%pagename%/"
    }
  end

  defp terms(element, taxonomy, conn),
    do:
      for(
        reference <- Export.all(element, "category"),
        Export.attribute(reference, "domain") == taxonomy,
        id = Map.get(conn.terms[taxonomy], Export.attribute(reference, "nicename")),
        do: id
      )

  defp format(element) do
    Enum.find_value(Export.all(element, "category"), "standard", fn reference ->
      Export.attribute(reference, "domain") == "post_format" and
        reference
        |> Export.attribute("nicename")
        |> to_string()
        |> String.replace_prefix("post-format-", "")
    end)
  end

  defp template(template) when template in [nil, "default"], do: ""
  defp template(template), do: template

  defp media(element, authors) do
    meta = meta(element, "wp:postmeta")
    url = text(element, "wp:attachment_url")
    mime = url |> to_string() |> URI.parse() |> Map.get(:path) |> to_string() |> MIME.from_path()

    element
    |> posted(authors)
    |> Map.merge(%{
      "description" => %{"raw" => text(element, "content:encoded") || ""},
      "caption" => %{"raw" => text(element, "excerpt:encoded") || ""},
      "alt_text" => meta["_wp_attachment_image_alt"] || "",
      "media_type" => media_type(mime),
      "mime_type" => mime,
      "post" => attached_to(integer(text(element, "wp:post_parent"))),
      "source_url" => url,
      "media_details" => meta["_wp_attachment_metadata"] |> Export.php() |> details(url),
      "meta" => Map.drop(meta, @mapped_meta)
    })
  end

  defp media_type("image/" <> _), do: "image"
  defp media_type(_other), do: "file"

  defp attached_to(post) when is_integer(post) and post > 0, do: post
  defp attached_to(_none), do: nil

  defp details(%{"sizes" => %{} = sizes} = details, url) when is_binary(url),
    do: %{details | "sizes" => Map.new(sizes, fn {name, size} -> {name, sized(size, url)} end)}

  defp details(%{} = details, _url), do: details
  defp details(_none, _url), do: %{}

  defp sized(%{"file" => file} = size, url) when is_binary(file) do
    uri = URI.parse(url)

    Map.put(
      size,
      "source_url",
      URI.to_string(%{uri | path: Path.join(Path.dirname(uri.path || "/"), file)})
    )
  end

  defp sized(size, _url), do: size

  defp comments(type, element) do
    post = integer(text(element, "wp:post_id"))

    for comment <- Export.all(element, "wp:comment"),
        status = @listed_comments[text(comment, "wp:comment_approved")],
        do: %{
          "id" => integer(text(comment, "wp:comment_id")),
          "post" => post,
          "parent" => integer(text(comment, "wp:comment_parent")) || 0,
          "author" => integer(text(comment, "wp:comment_user_id")) || 0,
          "author_name" => text(comment, "wp:comment_author"),
          "author_email" => text(comment, "wp:comment_author_email"),
          "author_url" => text(comment, "wp:comment_author_url"),
          "author_ip" => text(comment, "wp:comment_author_IP"),
          "date" => datetime(text(comment, "wp:comment_date")),
          "date_gmt" => datetime(text(comment, "wp:comment_date_gmt")),
          "content" => %{"raw" => text(comment, "wp:comment_content") || ""},
          "status" => status,
          "type" => comment_type(text(comment, "wp:comment_type")),
          "meta" => meta(comment, "wp:commentmeta"),
          "_links" => %{"up" => [%{"post_type" => type}]}
        }
  end

  defp comment_type(type) when type in [nil, ""], do: "comment"
  defp comment_type(type), do: type

  defp meta(element, name),
    do: Map.new(Export.all(element, name), &{text(&1, "wp:meta_key"), text(&1, "wp:meta_value")})

  defp datetime("0000-00-00" <> _never), do: nil
  defp datetime(<<date::binary-size(10), " ", time::binary-size(8)>>), do: date <> "T" <> time
  defp datetime(_none), do: nil

  defp integer(text) when is_binary(text), do: text |> String.trim() |> Integer.parse() |> whole()
  defp integer(_none), do: nil

  defp whole({integer, ""}), do: integer
  defp whole(_not_whole), do: nil
end
