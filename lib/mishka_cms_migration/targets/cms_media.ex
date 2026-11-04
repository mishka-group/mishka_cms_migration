# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.CmsMedia do
  @moduledoc """
  The `"media"` items of a source, its files, written to the CMS's own media library
  (`MishkaCmsCore.Runtime.Media`), on the run's site and as the admin who pressed Import: a file is
  stored and its record made by the core's `:upload`, the action the media chooser of an admin's
  forms runs, and written again by the `:update` an admin's own media form runs. The admin needs the
  core's `admin:dashboard:runtime:media`, and the core's own rules decide the rest: which types it
  keeps and how big, that a file's first bytes are the type its name says
  (`MishkaCmsCore.Runtime.FileSignature`), where the file is stored, and that a name is unique
  within a site.

  ## Which files

  An item's `"source_url"` is where its file is, and its extension and `"mime_type"` its type. Read
  before anything is written, in the dry run too (`existing/2`), without asking for any file, an
  item is skipped as:

    * `"not_on_source"` — its address is not `http` or `https` on the run's source host (the run's
      `source_host`, its port included), such as a file a plugin moved to a CDN: the migration only
      downloads from the site the admin named;
    * `"type_not_allowed"` — its extension is not one the Media page's upload takes (the core
      Media's `:media_files` upload, read with `MishkaGervaz.Resource.Info.form_uploads/1`): an SVG,
      an AVIF, a sound, a zip. The core takes no SVG, whose markup can carry a script it does not
      clean out, so an SVG is never downloaded;
    * `"wrong_type"` — its `"mime_type"` is not the type the core gives its extension
      (`MishkaCmsCore.Runtime.Media.get_content_type/1`);
    * `"too_big"` — its `"filesize"` is larger than that upload takes (50 MB).

  ## The download

  In an import, a file to create is downloaded before it is written (`prepare/3`), outside the
  write's transaction, once: with `Req`, from its own address, sending no credential, following no
  redirect, retrying nothing and decompressing nothing, into a temporary file
  (`Plug.Upload.random_file!/1`) that is removed once the write is done, and with the job's process
  if it ends first. The checks above run again on the address, and then:

    * the download stops once more bytes have come than the Media page's upload takes, whatever
      the source said its size was, and the item is skipped as `"too_big"`;
    * an answer that is not a `200`, or no answer, fails the item as `"not_downloaded"`;
    * an answer whose content type is not the one the core gives its extension is skipped as
      `"wrong_type"`;
    * a file whose first bytes are not that type (`MishkaCmsCore.Runtime.FileSignature.matches?/2`),
      such as an HTML page sent as `hero.jpg`, is skipped as `"wrong_bytes"`.

  The core's `:upload` checks the same file again, its type, its size and its bytes, and has the
  last word.

  ## The same file twice

  WordPress media uploaded at different times has its own ids, and each is imported as its own file.
  Two attachments are the same file only when their bytes are: the SHA-256 of a downloaded file is
  kept on its item (`MishkaCmsMigration.MigrationItem`'s `file_hash`), and one lookup by it, made
  once the file is downloaded and checked, finds an item of the site that has the same bytes. A
  name or a size alone never does. The source lists its files oldest first, so the earlier upload
  is the original. A dry run downloads nothing, so it cannot know: it plans every file to create
  and says the check is made when the file is downloaded (`"same_file_checked_at_download"`).

  The later attachment waits for the admin's decision in the import (`"same_file: <title of the
  original>"`, the report says `Same file as …`), with two choices:

    * Use the original (`"import"`) — nothing is stored. The item is connected to the original's
      Media record, so every address a post's or a page's content wrote for the duplicate
      (`relinked/3`) is the original's. The duplicate's old address on the source, such as
      `/wp-content/uploads/2026/01/photo-1.jpg`, is redirected with a 301 to the original's
      Media address through the core's redirect rule (`MishkaCmsCore.Runtime.Redirect`), as the
      admin who pressed Import, who needs the core's `admin:dashboard:runtime:redirect`
      (`"same_file_used"`); a rule that already sends that address to the original is reused. The
      run's `post_address` choice `"blog_without_redirects"` writes no redirect, and the report says so
      (`"same_file_used_no_redirect"`). A redirect for the sizes WordPress made of the file is not
      written.
    * Keep both (`"keep"`) — imported as its own file, as any other (`"same_file_kept"`).

  The answer holds for every later run: an item connected to the original is never downloaded
  again. An original the CMS no longer has is not used: the file is imported as its own.

  `req_options` in the application environment are merged into every download, which is how the
  suite answers them from the recorded site:

      config :mishka_cms_migration, MishkaCmsMigration.Targets.CmsMedia,
        req_options: [plug: {Req.Test, MishkaCmsMigration.Sources.WordPress}]

  ## The record

  A file is named by its `"slug"`, made as the core slugs a name (`hero`, `وردپرس` as `wrdprs`),
  with its own extension, or `media-<source id>` for a slug that leaves nothing: a source's slugs
  are unique among its files, and a name the site already has is refused by the core, failing the
  item with its sentence. Its description is its `"alt_text"`, or without one its `"caption"`, or
  its `"description"`, as text, the first 1,000 characters. It is filed in the site's top-level
  media folder named after the run's source, `wordpress`, read and, the first time, made by the
  admin, as the media chooser files an upload in the folder its form names; an admin who may not
  make one files it at the top.

  ## A second run

  A file the source did not change is `"unchanged"` and never downloaded again. One it changed has
  its description written over, and keeps the file the first run stored. A record an admin edited,
  archived or deleted in the CMS is kept as the admin left it
  (`MishkaCmsMigration.Workers.Helpers.Decision`).

  ## Where a file went

  `addresses/2` is where the CMS serves the files written for a source's media ids, and
  `relinked/3` points the addresses a post's or a page's content wrote for them at those files, for
  the targets that write them (`MishkaCmsMigration.Targets.BlogPost`,
  `MishkaCmsMigration.Targets.CmsPage`).
  """

  use MishkaCmsMigration.Target,
    kind: "media",
    resource: MishkaCmsCore.Runtime.Media,
    create: :upload,
    update: :update

  require Ash.Query

  alias MishkaCmsCore.Runtime.{FileSignature, Media, MediaCategory, Redirect, Redirects}
  alias MishkaCmsMigration.{Source, Target}
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Targets.Helpers.{BySlug, Read, Written}
  alias MishkaGervaz.Resource.Info

  @schemes ["http", "https"]
  @addressed ["src", "href", "poster"]
  @conflict "same_file"

  @impl MishkaCmsMigration.Target
  def existing(items, context),
    do: for(item <- items, found = refused(item, context), into: %{}, do: {item.source_id, found})

  @impl MishkaCmsMigration.Target
  # sobelow_skip ["Traversal.FileModule"]
  # The path is the temporary file `Plug.Upload.random_file!/1` made, never one a source names.
  def prepare(item, %{record: nil} = context, write) do
    path = Plug.Upload.random_file!("migration")

    try do
      with {:ok, hash} <- downloaded(item, path, context),
           :unique <- same_file(item, hash, context),
           do: write.(%{context | prepared: %{path: path, hash: hash}})
    after
      File.rm(path)
    end
  end

  def prepare(_item, context, write), do: write.(context)

  @impl MishkaCmsMigration.Target
  def attrs(item, %{record: nil} = context) do
    %{
      file: Ash.Type.File.from_path(context.prepared.path),
      original_filename: name(item) <> extension(item.attrs["source_url"]),
      description: description(item),
      media_category_id: folder_id(context)
    }
  end

  def attrs(item, _update), do: %{description: description(item)}

  @impl MishkaCmsMigration.Target
  def note(item, %{record: nil} = context),
    do: noted(context.mode, Target.decision(context, item, @conflict))

  def note(_item, _update), do: nil

  defp noted(_mode, "keep"), do: "same_file_kept"
  defp noted(:dry_run, _decision), do: "same_file_checked_at_download"
  defp noted(:import, _decision), do: nil

  @impl MishkaCmsMigration.Target
  def recorded(_item, %{prepared: %{hash: hash}}), do: %{file_hash: hash}
  def recorded(_item, _context), do: %{}

  @doc """
  Where the CMS serves the files the same run, or an earlier one, wrote for the source's media
  `ids`, by id as a string: each one's Media address, `/uploads/<site>/media/<folder>/<file>`. A
  file never written, and one the CMS no longer has, is left out.
  """
  @spec addresses([term()], MishkaCmsMigration.Target.context()) :: %{String.t() => String.t()}
  def addresses(ids, context),
    do:
      Media
      |> Written.call("media", ids, context)
      |> Map.new(fn {id, media} -> {id, media.relative_path} end)

  @doc """
  What the report says about the `srcset` candidates of `item`'s content: `"srcset_file_missing"`
  when one names a file of the source's media (the item's `"media"`) that no run wrote, so it keeps
  its old address (`relinked/3`). A dry run writes no file and says nothing. The files are read in
  one query, and only when the content has such a candidate.
  """
  @spec srcset_note(Item.t(), MishkaCmsMigration.Target.context()) :: String.t() | nil
  def srcset_note(%Item{attrs: %{"media" => media}} = item, %{mode: mode} = context)
      when is_map(media) and map_size(media) > 0 and mode != :dry_run do
    ids =
      item
      |> Item.html()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[srcset]")
      |> LazyHTML.attribute("srcset")
      |> Enum.flat_map(&Source.srcset/1)
      |> Enum.flat_map(fn {url, _descriptor} -> List.wrap(media[url]) end)
      |> Enum.uniq()

    missing(ids, context)
  end

  def srcset_note(_item, _context), do: nil

  defp missing([], _context), do: nil

  defp missing(ids, context),
    do: ids |> addresses(context) |> map_size() |> missing_note(length(ids))

  defp missing_note(written, wanted) when written < wanted, do: "srcset_file_missing"
  defp missing_note(_written, _wanted), do: nil

  @doc """
  `html` with each `src`, `href`, `poster` and `srcset` candidate that `media` names, an address as
  the source wrote it to the source id of the file it is (`MishkaCmsMigration.Sources.WordPress`'s
  `media`), pointing at that file's Media address (`addresses/2`). The address of a file that was
  not written, and every other, is kept as it is.
  """
  @spec relinked(String.t(), map() | nil, MishkaCmsMigration.Target.context()) :: String.t()
  def relinked(html, media, context) when is_map(media) and map_size(media) > 0 do
    addresses = media |> Map.values() |> addresses(context)

    html
    |> moved(for {old, id} <- media, new = addresses[to_string(id)], into: %{}, do: {old, new})
  end

  def relinked(html, _media, _context), do: html

  @doc """
  `html` with each `src`, `href` and `poster` (a video's picture) whose value is a key of `moved`
  written as that key's value, and each URL of an `srcset` (an image's, or a `source`'s in a
  `picture`) that is a key of `moved` written as that key's value, its descriptor kept; the other
  attributes are kept as they are. `relinked/3` and
  `MishkaCmsMigration.Targets.CmsPage.relinked/3` point the addresses of files and of pages at
  where they went.
  """
  @spec moved(String.t(), %{String.t() => String.t()}) :: String.t()
  def moved(html, moved) when map_size(moved) == 0, do: html

  def moved(html, moved),
    do:
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.to_tree()
      |> LazyHTML.Tree.postwalk(&moved_node(&1, moved))
      |> LazyHTML.Tree.to_html()

  defp moved_node({tag, attributes, children}, moved),
    do: {tag, Enum.map(attributes, &moved_attribute(&1, moved)), children}

  defp moved_node(node, _moved), do: node

  defp moved_attribute({"srcset", value}, moved) do
    candidates = Source.srcset(value)

    if Enum.any?(candidates, fn {url, _descriptor} -> is_map_key(moved, url) end),
      do:
        {"srcset", candidates |> Enum.map(&moved_candidate(&1, moved)) |> Source.srcset_value()},
      else: {"srcset", value}
  end

  defp moved_attribute({name, old}, moved)
       when name in @addressed and is_map_key(moved, old),
       do: {name, Map.fetch!(moved, old)}

  defp moved_attribute(attribute, _moved), do: attribute

  defp moved_candidate({url, descriptor}, moved), do: {Map.get(moved, url, url), descriptor}

  defp same_file(item, hash, context),
    do: same_file(item, hash, context, Target.decision(context, item, @conflict))

  defp same_file(_item, _hash, _context, "keep"), do: :unique

  defp same_file(item, hash, context, decision) do
    hash
    |> MishkaCmsMigration.items_by_file_hash!(actor: context.actor, tenant: context.site_id)
    |> original(item, context, decision)
  end

  defp original([], _item, _context, _decision), do: :unique

  defp original([twin | _], item, context, decision) do
    Media
    |> Ash.Query.filter(id == ^twin.target_id)
    |> Read.call(context)
    |> original(twin, item, context, decision)
  end

  defp original([], _twin, _item, _context, _decision), do: :unique

  defp original([media], twin, _item, _context, nil),
    do: {:undecided, @conflict <> ": " <> (twin.title || media.name)}

  defp original([media], _twin, item, context, "import"), do: used(media, item, context)

  defp used(media, _item, %{options: %{post_address: "blog_without_redirects"}}),
    do: {:connected, media, "same_file_used_no_redirect"}

  defp used(media, item, context) do
    with :ok <- redirected(item.attrs["source_url"], media.relative_path, context),
         do: {:connected, media, "same_file_used"}
  end

  defp redirected(url, to, context) do
    case Redirects.normalize_path(url) do
      {:ok, from} ->
        Redirect
        |> Ash.Query.filter(from_path == ^from)
        |> Read.call(context)
        |> redirected(from, to, context)

      :error ->
        {:error, "not_redirectable"}
    end
  end

  defp redirected([%Redirect{to: to}], _from, to, _context), do: :ok

  defp redirected(_other, from, to, context) do
    Redirect
    |> Ash.Changeset.for_create(:create, %{from_path: from, to: to, status: 301},
      actor: context.actor,
      tenant: context.site_id
    )
    |> Ash.create()
    |> created()
  end

  defp created({:ok, %Redirect{}}), do: :ok
  defp created({:error, error}), do: {:error, error}

  defp refused(item, context) do
    with {:ok, uri} <- sourced(item.attrs["source_url"], context.source_host),
         {:ok, _extension} <- typed(uri, item.attrs["mime_type"]),
         :ok <- fits(item.attrs["filesize"]),
         do: nil
  end

  defp sourced(url, host) when is_binary(url) and is_binary(host),
    do: url |> URI.parse() |> on_source(Source.url_host(%{"url" => url}) == host)

  defp sourced(_url, _host), do: {:skipped, "not_on_source"}

  defp on_source(%URI{scheme: scheme} = uri, true) when scheme in @schemes, do: {:ok, uri}
  defp on_source(_uri, _elsewhere), do: {:skipped, "not_on_source"}

  defp typed(uri, mime) do
    extension = extension(uri)
    allowed(extension in upload().accept, extension, mime)
  end

  defp allowed(false, _extension, _mime), do: {:skipped, "type_not_allowed"}

  defp allowed(true, extension, mime),
    do: extension |> content_type() |> same_type(mime, extension)

  defp same_type(type, type, extension), do: {:ok, extension}
  defp same_type(_type, nil, extension), do: {:ok, extension}
  defp same_type(_type, _other, _extension), do: {:skipped, "wrong_type"}

  defp fits(size), do: fits(size, upload().max_file_size)

  defp fits(size, limit) when is_integer(size) and size > limit, do: {:skipped, "too_big"}
  defp fits(_size, _limit), do: :ok

  defp downloaded(item, path, context) do
    with {:ok, uri} <- sourced(item.attrs["source_url"], context.source_host),
         {:ok, extension} <- typed(uri, nil),
         {:ok, response} <- fetched(uri, path) do
      checked(response, path, extension)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  # The path is the temporary file `prepare/3` made, never one a source names.
  defp fetched(uri, path) do
    limit = upload().max_file_size

    path
    |> File.open([:write, :binary], fn file ->
      [
        url: URI.to_string(uri),
        redirect: false,
        retry: false,
        into: &streamed(&1, &2, file, limit)
      ]
      |> Req.new()
      |> Req.merge(req_options())
      |> Req.get()
    end)
    |> opened()
  end

  defp opened({:ok, {:ok, %Req.Response{} = response}}), do: {:ok, response}
  defp opened(_not_downloaded), do: {:error, "not_downloaded"}

  defp streamed({:data, data}, {request, response}, file, limit) do
    size = Req.Response.get_private(response, :size, 0) + byte_size(data)

    hash =
      response
      |> Req.Response.get_private(:hash, :crypto.hash_init(:sha256))
      |> :crypto.hash_update(data)

    response =
      response |> Req.Response.put_private(:size, size) |> Req.Response.put_private(:hash, hash)

    kept(size <= limit, data, file, {request, response})
  end

  defp kept(true, data, file, answer) do
    :ok = IO.binwrite(file, data)
    {:cont, answer}
  end

  defp kept(false, _data, _file, answer), do: {:halt, answer}

  defp checked(%Req.Response{status: 200} = response, path, extension) do
    with :ok <- response |> Req.Response.get_private(:size, 0) |> fits(),
         :ok <- response |> Req.Response.get_header("content-type") |> answered(extension) do
      path |> FileSignature.matches?(extension) |> signed(response)
    end
  end

  defp checked(_response, _path, _extension), do: {:error, "not_downloaded"}

  defp answered([type], extension),
    do:
      type
      |> String.split(";")
      |> hd()
      |> String.trim()
      |> String.downcase()
      |> answered_as(extension)

  defp answered(_types, _extension), do: {:skipped, "wrong_type"}

  defp answered_as(type, extension), do: extension |> content_type() |> same_answer(type)

  defp same_answer(type, type), do: :ok
  defp same_answer(_type, _answered), do: {:skipped, "wrong_type"}

  defp signed(true, response),
    do:
      {:ok,
       response
       |> Req.Response.get_private(:hash, :crypto.hash_init(:sha256))
       |> :crypto.hash_final()
       |> Base.encode16(case: :lower)}

  defp signed(false, _response), do: {:skipped, "wrong_bytes"}

  defp name(%Item{attrs: %{"slug" => slug}} = item) when is_binary(slug),
    do: slug |> Slug.slugify() |> named(item)

  defp name(item), do: named(nil, item)

  defp named(nil, item), do: "media-" <> item.source_id
  defp named(name, _item), do: name

  defp description(%Item{attrs: attrs}),
    do:
      Enum.find_value(
        [attrs["alt_text"], text(attrs["caption"]), text(attrs["description"])],
        &said/1
      )

  defp text(html) when is_binary(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text()
  defp text(_none), do: nil

  defp said(text) when is_binary(text), do: text |> String.trim() |> kept_text()
  defp said(_none), do: nil

  defp kept_text(""), do: nil
  defp kept_text(text), do: String.slice(text, 0, 1000)

  defp folder_id(context) do
    folder = BySlug.slug({MediaCategory, :create, :name}, context.source)

    MediaCategory
    |> Ash.Query.filter(name == ^folder and is_nil(parent_id))
    |> Read.call(context)
    |> folder(folder, context)
  end

  defp folder([%MediaCategory{id: id} | _], _folder, _context), do: id

  defp folder([], folder, context) do
    MediaCategory
    |> Ash.Changeset.for_create(:create, %{name: folder},
      actor: context.actor,
      tenant: context.site_id
    )
    |> Ash.create()
    |> made()
  end

  defp made({:ok, %MediaCategory{id: id}}), do: id
  defp made({:error, _refused}), do: nil

  defp extension(%URI{path: path}) when is_binary(path),
    do: path |> Path.extname() |> String.downcase()

  defp extension(url) when is_binary(url), do: url |> URI.parse() |> extension()
  defp extension(_none), do: ""

  defp content_type(extension),
    do: extension |> String.trim_leading(".") |> Media.get_content_type()

  defp upload,
    do: Media |> Info.form_uploads() |> Enum.find(&(&1.name == :media_files))

  defp req_options,
    do:
      :mishka_cms_migration
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:req_options, [])
end
