# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Source do
  @moduledoc """
  A CMS a site is moved from: one module that is a `mishka_installer` plugin on the
  `"migration:sources"` event and implements the callbacks below. WordPress is the first
  (`MishkaCmsMigration.Sources.WordPress`); Joomla and others come the same way and reuse the
  mapping, the dry run, the import job and the report.

      defmodule MyExtension.Sources.Ghost do
        use MishkaCmsMigration.Source, id: "ghost", label: "Ghost"
        use Gettext, backend: MishkaCmsCore.Gettext

        @impl true
        def kinds, do: ["user", "tag", "post"]

        @impl true
        def form_fields,
          do: [
            [
              name: :url,
              label: dgettext_noop("mishka_gervaz", "Address"),
              placeholder: "https://example.com",
              required: true
            ],
            [
              name: :secret,
              type: :password,
              label: dgettext_noop("mishka_gervaz", "Admin API key"),
              required: true
            ]
          ]

        @impl true
        def connect(%{"url" => url}, key), do: {:ok, Req.new(base_url: url, params: [key: key])}

        @impl true
        def list(req, kind, cursor) do
          ...
          {:ok, rows, next_cursor_or_nil}
        end

        @impl true
        def normalize(row, "post", _context),
          do: {:ok, %{source_id: row["id"], title: row["title"], content: [%{html: row["html"]}]}}
      end

  `use` makes the module a plugin on `"migration:sources"` — registering is the declaration; the
  event is never fired, and the plugin's `call/1` hands its state back — and adds `id/0`, `label/0`,
  an `extra/1` that answers `%{}`, which a source overrides to keep facts about itself, a
  `host/1` that reads the connection's `"url"`, a `form_fields/0` that asks for an address and a
  secret, which a source overrides to ask for what it connects with, and a `file?/0` that answers
  `false`, which a source that reads a file overrides. A source registers once it is supervised:
  an extension that ships one lists the module among the children of its own application's
  supervisor, as `MishkaCmsMigration.Application.plugins/0` lists this extension's. Which sources are installed is read from mishka_installer's own registry
  (`installed/2`), so a source an operator stops in the installer is no longer offered and a run of
  it is refused.

  ## A run

  A run names its source by `id/0` (`MishkaCmsMigration.MigrationRun`'s `source`); a run of a source
  that is not installed is refused when it is created. A job
  (`MishkaCmsMigration.Workers.Helpers.Pipeline`) asks `connect/2` once, with the run's `connection`
  map and its secret opened (`MishkaCmsMigration.MigrationRun.open_secret/1`), then walks `kinds/0`
  in the order the source gives them, and pages through each with `list/3` until it answers no
  cursor. The walk does not sort the kinds: a source lists them in the order they must be imported,
  a kind before any kind that points at it, so authors come before the posts that name them. Each
  listed row goes through `normalize/3`, which is handed the connection `connect/2` answered to read
  more of the source when a row needs it (`t:context/0`), and then
  `MishkaCmsMigration.Source.Item.build/1`. An error from `connect/2` or `list/3` fails the run; an
  error from `normalize/3` fails only that item, and the report says why.

  A job of picked items, Dry run this item or Import this item on the Items page, walks only the
  kinds of those items and reads only their rows: `rows/3` with their source ids, where the source
  has it, and otherwise every page of their kind from `list/3`, keeping the picked ones once they
  are normalized. `rows/3` is optional; a source that reads a site over the network should have it,
  so one item never costs a walk of its whole kind.

  ## Its connection form

  The Migration page's New import opens one form for every source, and the form asks for what
  `form_fields/0` names: the keys of the run's `connection`, as data, each the shape a Gervaz
  `:key_map` key takes (`MishkaGervaz.Form.Types.Field.KeyMap`):

    * `:name` — the key the typed value is kept under in `connection`, as a string;
    * `:type` — `:text` (the default), `:password`, `:number`, `:select` or another type a
      `:key_map` key takes;
    * `:label` and `:placeholder` — msgids of the `mishka_gervaz` gettext domain, marked with
      `dgettext_noop("mishka_gervaz", "...")`, which the form translates as it draws them;
    * `:required` — `true` marks the key's label as a required field's label is marked.

  The key named `:secret` is the secret the source signs in with. Give it `type: :password`: it is
  drawn masked and never shown again, and creating the run takes it out of `connection` and keeps
  it only sealed (`MishkaCmsMigration.MigrationRun.take_secret/2`), so `connect/2` gets it as its
  `secret`. Every other key, a `:password` one too, is kept in `connection` as typed, so a source
  has one secret, under `:secret`. A key left blank is not saved.

  `use` asks for an Address (`:url`, required, `https://example.com` as its placeholder) and a
  Password or key (`:secret`, a required `:password` key). `form_fields/1` reads the keys of the
  source a form was opened for.

  ## A source that reads a file

  A source that reads a file a site exported, rather than the site itself, answers `true` to
  `file?/0` (`MishkaCmsMigration.Sources.WordPressFile` does) and names no keys in `form_fields/0`.
  The New import form then asks for the file instead of a Connection, and the run keeps it in a
  private folder until it ends (see "The source's file" in `MishkaCmsMigration.MigrationRun`):
  `host/1` and `connect/2` get its path as the connection's `"file"`, and a refusal is shown on the
  form's file. `file?/1` tells whether the source a form was opened for is one. `use` answers
  `false`.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaInstaller.Event.Event

  @event "migration:sources"

  @typedoc "What a source keeps between calls once connected: a client, a parsed file, a cursor."
  @type conn :: term()

  @typedoc "Where `list/3` goes on from: `nil` is the first page, and answering `nil` ends a kind."
  @type cursor :: term() | nil

  @typedoc """
  One key of a source's connection form: `:name`, `:type`, `:label`, `:placeholder` and
  `:required`, as a Gervaz `:key_map` key takes them (see "Its connection form").
  """
  @type form_field :: keyword()

  @form_fields [
    [
      name: :url,
      type: :text,
      label: dgettext_noop("mishka_gervaz", "Address"),
      placeholder: "https://example.com",
      required: true
    ],
    [
      name: :secret,
      type: :password,
      label: dgettext_noop("mishka_gervaz", "Password or key"),
      required: true
    ]
  ]

  @typedoc """
  What `normalize/3` is told: the run's site, its source host and its options, and the connection
  `connect/2` answered, for a row that names more of the source to read, such as the reusable
  blocks and gallery images a WordPress post names.
  """
  @type context :: %{
          site_id: String.t(),
          run_id: String.t(),
          source_host: String.t(),
          options: map(),
          conn: conn()
        }

  @doc "The source's id, stored on a run."
  @callback id() :: String.t()

  @doc "The source's name, as a `gettext_noop/1` msgid."
  @callback label() :: String.t()

  @doc """
  The kinds of item this source lists, in the order they are imported: a kind before any kind that
  points at it.
  """
  @callback kinds() :: [String.t()]

  @doc """
  Connects with a run's `connection` map and its opened secret (`nil` when it has none).

  It is asked when a run is created, so a run is only kept for a source it can reach
  (`MishkaCmsMigration.Resources.Changes.CheckConnection`), and again by each job. A refusal is
  shown to the admin on the run's `connection`; these reasons are put in words, and any other is
  shown as it is:

    * `:invalid_address` — the connection does not name an address the source can use;
    * `:unreachable` — nothing answered at the address;
    * `:no_site` — something answered, but not a site of this source;
    * `:unauthorized` — the site refused the user or the secret.
  """
  @callback connect(connection :: map(), secret :: String.t() | nil) ::
              {:ok, conn()} | {:error, term()}

  @doc """
  The host a run's `connection` points at, kept as the run's `source_host` when the run does not
  name one: with the source id and an item's id it is how a re-run finds what an earlier run
  wrote. `use` answers the host of the connection's `"url"`, or `nil` without one.
  """
  @callback host(connection :: map()) :: String.t() | nil

  @doc """
  The keys the New import form asks for, in the order it draws them: what `connect/2` reads from a
  run's `connection`, and its secret under `:secret` (see "Its connection form"). `use` asks for an
  address and a secret.
  """
  @callback form_fields() :: [form_field()]

  @doc """
  Whether the source reads a file the admin uploads, handed to it as the connection's `"file"`,
  rather than a site it connects to (see "A source that reads a file"). `use` answers `false`.
  """
  @callback file?() :: boolean()

  @doc "One page of `kind` from `cursor`, and the cursor of the next page (`nil` after the last)."
  @callback list(conn(), kind :: String.t(), cursor()) ::
              {:ok, [term()], cursor()} | {:error, term()}

  @doc """
  The rows of `kind` whose source ids are `source_ids`, as `list/3` answers them, read without
  listing the whole kind: what a job of picked items reads (see "A run"). A row it answers that was
  not asked for is left out once it is normalized, so a kind the source reads in one go, such as
  WordPress's menus, may answer it whole. Optional.
  """
  @callback rows(conn(), kind :: String.t(), source_ids :: [String.t()]) ::
              {:ok, [term()]} | {:error, term()}

  @optional_callbacks rows: 3

  @doc """
  Facts about the source a run keeps in its `extra` (`MishkaCmsMigration.MigrationRun`), such as a
  WordPress site's version and plugins. It is asked when a run is created, right after
  `connect/2`, and again by a job of the whole run before it walks a kind, and the run keeps the
  answer when that job finishes; a job of picked items does not ask. `use` answers `%{}`.
  """
  @callback extra(conn()) :: map()

  @doc """
  A listed row as the map `MishkaCmsMigration.Source.Item.build/1` takes, without `:kind`, which
  the walk adds.
  """
  @callback normalize(row :: term(), kind :: String.t(), context()) ::
              {:ok, map()} | {:error, term()}

  @doc false
  defmacro __using__(opts) do
    id = Keyword.fetch!(opts, :id)
    label = Keyword.fetch!(opts, :label)
    priority = Keyword.get(opts, :priority, 50)

    quote do
      use MishkaInstaller.Event.Hook,
        event: unquote(@event),
        initial: %{priority: unquote(priority)}

      @behaviour MishkaCmsMigration.Source

      @impl true
      def call(state), do: {:reply, state}

      @impl MishkaCmsMigration.Source
      def id, do: unquote(id)

      @impl MishkaCmsMigration.Source
      def label, do: unquote(label)

      @impl MishkaCmsMigration.Source
      def extra(_conn), do: %{}

      @impl MishkaCmsMigration.Source
      def host(connection), do: MishkaCmsMigration.Source.url_host(connection)

      @impl MishkaCmsMigration.Source
      def form_fields, do: unquote(@form_fields)

      @impl MishkaCmsMigration.Source
      def file?, do: false

      defoverridable extra: 1, host: 1, form_fields: 0, file?: 0
    end
  end

  @doc """
  The event a source plugin registers on, the one `use MishkaCmsMigration.Source` names: what an
  extension's own tests register a source for.
  """
  @spec event() :: String.t()
  def event, do: @event

  @doc """
  Every installed source (`installed/2`), by priority, the first of each id: what the Migration
  page offers to migrate from, and what a developer reads to see which sources a node has.
  """
  @spec all() :: [module()]
  def all, do: installed(@event, __MODULE__)

  @doc """
  The name to show for the source whose id is `id`: its label in the reader's language, or the id
  itself for a source that is no longer installed.
  """
  @spec label(String.t()) :: String.t()
  def label(id), do: id |> fetch() |> shown(id)

  defp shown({:ok, source}, _id), do: Gettext.gettext(MishkaCmsCore.Gettext, source.label())
  defp shown({:error, :not_installed}, id), do: id

  @doc """
  The connection keys (`c:form_fields/0`) of the installed source a form names, or of the source
  whose id is given: what the run's form draws under Connection. A form names its source in its
  `defaults`, as the Migration page opens it (`defaults: %{source: id}`). Empty for a form opened
  for no source and for a source that is not installed.

      field :connection, :key_map do
        options fn state -> MishkaCmsMigration.Source.form_fields(state) end
      end
  """
  @spec form_fields(map() | String.t() | nil) :: [form_field()]
  def form_fields(state_or_id), do: asked(state_or_id, & &1.form_fields(), [])

  @doc """
  Whether the installed source a form names (`defaults: %{source: id}`), or the source whose id is
  given, reads a file (`c:file?/0`): what shows the New import form's file. `false` for a form
  opened for no source and for a source that is not installed.

      field :file, :upload do
        visible fn state -> MishkaCmsMigration.Source.file?(state) end
      end
  """
  @spec file?(map() | String.t() | nil) :: boolean()
  def file?(state_or_id), do: asked(state_or_id, & &1.file?(), false)

  defp asked(%{defaults: %{source: id}}, ask, none), do: asked(id, ask, none)
  defp asked(id, ask, none) when is_binary(id), do: id |> fetch() |> answered(ask, none)
  defp asked(_no_source, _ask, none), do: none

  defp answered({:ok, source}, ask, _none), do: ask.(source)
  defp answered({:error, :not_installed}, _ask, none), do: none

  @doc """
  The host of a connection's `"url"`, lower-cased and with its port when it is not the scheme's
  own (`localhost:8089`), or `nil` when it has no address with a host: what `use` answers as
  `c:host/1`.
  """
  @spec url_host(map()) :: String.t() | nil
  def url_host(%{"url" => url}) when is_binary(url),
    do: url |> String.trim() |> URI.parse() |> host_of()

  def url_host(_connection), do: nil

  @doc """
  The candidates of an `srcset` attribute, each as `{url, descriptor}` (`{"hero-300.jpg", "300w"}`;
  the descriptor is `""` for a candidate with none), in the order written. Candidates are told
  apart by a comma followed by white space, or by one that follows a width or density descriptor.
  """
  @spec srcset(String.t()) :: [{String.t(), String.t()}]
  def srcset(value) when is_binary(value),
    do:
      for(
        candidate <- Regex.split(~r/,\s+|(?<=\d[wx]),/, value, trim: true),
        [url | descriptor] <- [String.split(candidate, ~r/\s+/, parts: 2, trim: true)],
        do: {String.trim_trailing(url, ","), Enum.join(descriptor)}
      )

  @doc """
  The `srcset` attribute `candidates` (`srcset/1`) written back as the attribute's value.
  """
  @spec srcset_value([{String.t(), String.t()}]) :: String.t()
  def srcset_value(candidates),
    do:
      Enum.map_join(candidates, ", ", fn {url, descriptor} ->
        String.trim("#{url} #{descriptor}")
      end)

  defp host_of(%URI{host: host} = uri) when is_binary(host) and host != "",
    do: String.downcase(host) <> port_of(uri)

  defp host_of(_uri), do: nil

  defp port_of(%URI{scheme: scheme, port: port}) when is_integer(port),
    do: port_suffix(port, URI.default_port(scheme))

  defp port_of(_uri), do: ""

  defp port_suffix(port, port), do: ""
  defp port_suffix(port, _default), do: ":#{port}"

  @doc """
  Connects with `source` (`c:connect/2`) and answers what it answers: how the New import form's
  check and each job connect. A refusal is also told on `[:mishka_cms_migration, :connect,
  :refused]`, with `metadata`, the source's id and the reason in words (see "Telemetry" in
  `MishkaCmsMigration.Workers`).
  """
  @spec connect(module(), map(), String.t() | nil, map()) :: {:ok, conn()} | {:error, term()}
  def connect(source, connection, secret, metadata),
    do: connection |> source.connect(secret) |> connected(source, metadata)

  defp connected({:error, reason} = refused, source, metadata) do
    :telemetry.execute(
      [:mishka_cms_migration, :connect, :refused],
      %{system_time: System.system_time()},
      Map.merge(metadata, %{source: source.id(), reason: MishkaCmsMigration.Report.reason(reason)})
    )

    refused
  end

  defp connected(answer, _source, _metadata), do: answer

  @doc "The installed source whose id is `id`."
  @spec fetch(String.t() | nil) :: {:ok, module()} | {:error, :not_installed}
  def fetch(id), do: installed(@event, __MODULE__, id)

  @doc """
  The plugins of a migration event that are installed now, read from mishka_installer's own
  registry (`MishkaInstaller.Event.Event.get/2`): those an operator has not stopped and that are
  not held (`:started` or `:restarted`), by priority, that are loaded and implement every required
  callback of `behaviour`, the first of each id. Nothing is fired and nothing is cached. Targets
  are found the same way (`MishkaCmsMigration.Target.fetch/1`).
  """
  @spec installed(String.t(), module()) :: [module()]
  def installed(event, behaviour) do
    :event
    |> Event.get(event)
    |> Enum.filter(&(&1.status in [:started, :restarted]))
    |> Enum.sort_by(&{&1.priority, inspect(&1.name)})
    |> Enum.map(& &1.name)
    |> Enum.filter(&implements?(&1, behaviour))
    |> Enum.uniq_by(& &1.id())
  end

  @doc "The one plugin of `installed/2` whose `id/0` is `id`; `{:error, :not_installed}` for none."
  @spec installed(String.t(), module(), String.t() | nil) ::
          {:ok, module()} | {:error, :not_installed}
  def installed(event, behaviour, id) when is_binary(id),
    do: event |> installed(behaviour) |> Enum.find(&(&1.id() == id)) |> found()

  def installed(_event, _behaviour, _id), do: {:error, :not_installed}

  defp found(nil), do: {:error, :not_installed}
  defp found(plugin), do: {:ok, plugin}

  defp implements?(module, behaviour) do
    Code.ensure_loaded?(module) and behaviour in behaviours(module) and
      Enum.all?(
        behaviour.behaviour_info(:callbacks) -- behaviour.behaviour_info(:optional_callbacks),
        fn {name, arity} -> function_exported?(module, name, arity) end
      )
  end

  defp behaviours(module),
    do: module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
end

defmodule MishkaCmsMigration.Source.Item do
  @moduledoc """
  One item of a source, as every source hands it over: the normalized model the dry run decides on
  and a target writes from. A source's `c:MishkaCmsMigration.Source.normalize/3` returns the map
  `build/1` turns into this struct; the walk puts `:kind` in, so a source never names it.

  It lives with the source behaviour because it is the source's answer, held only while a job
  runs. What is kept of it afterwards is `MishkaCmsMigration.MigrationItem`: the CMS record it was
  written to, its title, its `extra`, its hash and what the last run did with it, not its content.

    * `:kind` — what the item is, such as `"post"`, `"page"` or `"user"`. A target is chosen by it
      (`MishkaCmsMigration.Target`).
    * `:source_id` — the item's id on the source, kept as a string (an integer is turned into one).
      Together with the run's `source_host` and `:kind` it is how a re-run finds what an earlier run
      wrote.
    * `:title` — what the report calls the item.
    * `:parent` — the source id of the item of the same kind this one sits under, such as a
      category's parent category, kept as a string; `nil` for none. The walk writes the parent
      first, whichever the source lists first, and the target is handed the CMS record it was
      written to (`MishkaCmsMigration.Target`'s context, `parent_id`).
    * `:modified_at` — when the source last changed it: a `DateTime`, a `NaiveDateTime` taken as
      UTC, or an ISO 8601 string.
    * `:attrs` — everything else the target needs, as the source names it. Its keys are never
      turned into atoms.
    * `:extra` — every field of the row the CMS has no home for (a WordPress post's custom fields,
      ACF fields, another plugin's meta), as key and value. It is kept on the item's
      `MishkaCmsMigration.MigrationItem` (its `extra`), and a target whose resource has an `extra`
      of its own may copy it there (`MishkaCmsMigration.Target`). Its keys are never turned into
      atoms.
    * `:content` — the item's body as a list of pieces, in order. A piece the source converted
      itself carries `:html`; a block or shortcode it could not convert carries `:name`, `:attrs`
      and `:raw` instead, and is offered to the `migration:content:convert` event
      (`MishkaCmsMigration.Events`) when the item is imported. `html/1` joins the pieces.

  `hash/1` is what a re-run compares to tell whether the source changed the item: it covers every
  field but `:modified_at`, so a source that touches an item without changing it is not an update.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :kind, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(string, not_empty, max_len=64)"

    field :source_id, String.t(),
      enforce: true,
      validator: {MishkaCmsMigration.Source.Item, :identifier},
      derives: "sanitize(trim) validate(string, not_empty, max_len=255)"

    field :title, String.t(),
      derives: "sanitize(trim, no_control) validate(optional=[string, max_len=1000])"

    field :parent, String.t(), validator: {MishkaCmsMigration.Source.Item, :reference}

    field :modified_at, DateTime.t(), validator: {MishkaCmsMigration.Source.Item, :datetime}

    dynamic_field :attrs
    dynamic_field :extra

    sub_field :content, list(), structs: true, authorized_fields: true do
      field :html, String.t(), derives: "validate(optional=[string])"
      field :name, String.t(), derives: "sanitize(trim) validate(optional=[string, max_len=255])"
      dynamic_field :attrs
      field :raw, String.t(), derives: "validate(optional=[string])"
    end
  end

  @doc """
  The item `attrs` describe, checked and cleaned: `{:ok, item}`, or `{:error, errors}` with
  guarded_struct's error maps.
  """
  @spec build(map()) :: {:ok, t()} | {:error, [map()]}
  def build(attrs), do: builder(attrs)

  @doc """
  A digest of what the source says the item is: every field but `:modified_at`, as hex.
  """
  @spec hash(t()) :: String.t()
  def hash(%__MODULE__{} = item) do
    {item.kind, item.source_id, item.title, item.parent, item.attrs, item.extra,
     Enum.map(item.content || [], &piece/1)}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  The item's content as one string: the `:html` of each piece, in order. A piece with no `:html`
  adds nothing, so convert the pieces first.
  """
  @spec html(t()) :: String.t()
  def html(%__MODULE__{content: content}), do: Enum.map_join(content || [], &(&1.html || ""))

  @doc false
  def identifier(field, value) when is_integer(value), do: {:ok, field, Integer.to_string(value)}
  def identifier(field, value) when is_binary(value), do: {:ok, field, value}
  def identifier(field, _value), do: {:error, field, "must be a string or an integer"}

  @doc false
  def reference(field, nil), do: {:ok, field, nil}
  def reference(field, value), do: identifier(field, value)

  @doc false
  def datetime(field, nil), do: {:ok, field, nil}
  def datetime(field, %DateTime{} = value), do: {:ok, field, value}

  def datetime(field, %NaiveDateTime{} = value),
    do: {:ok, field, DateTime.from_naive!(value, "Etc/UTC")}

  def datetime(field, value) when is_binary(value),
    do: value |> DateTime.from_iso8601() |> zoned(field, value)

  def datetime(field, _value), do: {:error, field, "must be a date and time"}

  defp zoned({:ok, datetime, _offset}, field, _value), do: {:ok, field, datetime}

  defp zoned({:error, _reason}, field, value),
    do: value |> NaiveDateTime.from_iso8601() |> naive(field)

  defp naive({:ok, naive}, field), do: {:ok, field, DateTime.from_naive!(naive, "Etc/UTC")}
  defp naive({:error, _reason}, field), do: {:error, field, "must be an ISO 8601 date and time"}

  defp piece(piece), do: {piece.html, piece.name, piece.attrs, piece.raw}
end
