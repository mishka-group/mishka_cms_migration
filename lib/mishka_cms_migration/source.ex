# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Source do
  @moduledoc """
  A CMS a site is moved from: one module that is a `mishka_installer` plugin on the
  `"migration:sources"` event and implements the callbacks below. WordPress is planned as the
  first; Joomla and others come the same way and reuse the mapping, the dry run, the import job and
  the report.

      defmodule MyExtension.Sources.Ghost do
        use MishkaCmsMigration.Source, id: "ghost", label: "Ghost"

        @impl true
        def kinds, do: ["user", "tag", "post"]

        @impl true
        def connect(%{"url" => url}, key), do: {:ok, Req.new(base_url: url, params: [key: key])}

        @impl true
        def list(req, kind, page) do
          ...
          {:ok, rows, next_page_or_nil}
        end

        @impl true
        def normalize(row, "post", _context),
          do: {:ok, %{source_id: row["id"], title: row["title"], content: [%{html: row["html"]}]}}
      end

  `use` makes the module a plugin on `"migration:sources"` — registering is the declaration; the
  event is never fired, and the plugin's `call/1` hands its state back — and adds `id/0` and
  `label/0`. A source registers once it is supervised: an extension that ships one lists the module
  among the children of its own application's supervisor, as
  `MishkaCmsMigration.Application.plugins/0` lists this extension's. Which sources are installed is
  read from mishka_installer's own registry (`installed/2`), so a source an operator stops in the
  installer is no longer offered and a run of it is refused.

  ## A run

  A run names its source by `id/0` (`MishkaCmsMigration.MigrationRun`'s `source`); a run of a
  source that is not installed is refused when it is created. A job
  (`MishkaCmsMigration.Workers.Helpers.Pipeline`) asks `connect/2` once, with the run's `connection` map and its
  secret opened (`MishkaCmsMigration.MigrationRun.open_secret/1`), then walks `kinds/0` in the order the source gives
  them, and pages through each with `list/3` until it answers no cursor. The walk does not sort the
  kinds: a source lists them in the order they must be imported, a kind before any kind that points
  at it, so authors come before the posts that name them. Each listed row goes through
  `normalize/3` and `MishkaCmsMigration.Source.Item.build/1`. An error from `connect/2` or `list/3` fails
  the run; an error from `normalize/3` fails only that row, and the report says why.
  """

  alias MishkaInstaller.Event.Event

  @event "migration:sources"

  @typedoc "What a source keeps between calls once connected: a client, a parsed file, a cursor."
  @type conn :: term()

  @typedoc "Where `list/3` goes on from; `nil` asks for the first page, and answering `nil` ends a kind."
  @type cursor :: term() | nil

  @typedoc "What `normalize/3` is told: the run's site, its source host and its options."
  @type context :: %{
          site_id: String.t(),
          run_id: String.t(),
          source_host: String.t(),
          options: map()
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

  @doc "Connects with a run's `connection` map and its opened secret (`nil` when it has none)."
  @callback connect(connection :: map(), secret :: String.t() | nil) ::
              {:ok, conn()} | {:error, term()}

  @doc "One page of `kind` from `cursor`, and the cursor of the next page (`nil` after the last)."
  @callback list(conn(), kind :: String.t(), cursor()) ::
              {:ok, [term()], cursor()} | {:error, term()}

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
        event: "migration:sources",
        initial: %{priority: unquote(priority)}

      @behaviour MishkaCmsMigration.Source

      @impl true
      def call(state), do: {:reply, state}

      @impl MishkaCmsMigration.Source
      def id, do: unquote(id)

      @impl MishkaCmsMigration.Source
      def label, do: unquote(label)
    end
  end

  @doc "The event a source plugin registers on."
  @spec event() :: String.t()
  def event, do: @event

  @doc """
  Every installed source (`installed/2`), by priority, the first of each id: what a screen offers
  to migrate from. The suite reads it, and the Import tab (issue #3) will.
  """
  @spec all() :: [module()]
  def all, do: installed(@event, __MODULE__)

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
  def installed(event, behaviour, id) when is_binary(id) do
    case Enum.find(installed(event, behaviour), &(&1.id() == id)) do
      nil -> {:error, :not_installed}
      plugin -> {:ok, plugin}
    end
  end

  def installed(_event, _behaviour, _id), do: {:error, :not_installed}

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
  runs. What is kept of it afterwards is `MishkaCmsMigration.MigrationItem`: the CMS row it was
  written to, its hash and what the last run did with it, not its content.

    * `:kind` — what the item is, such as `"post"`, `"page"` or `"user"`. A target is chosen by it
      (`MishkaCmsMigration.Target`).
    * `:source_id` — the item's id on the source, kept as a string (an integer is turned into one).
      Together with the run's `source_host` and `:kind` it is how a re-run finds what an earlier run
      wrote.
    * `:title` — what the report calls the item.
    * `:modified_at` — when the source last changed it: a `DateTime`, a `NaiveDateTime` taken as
      UTC, or an ISO 8601 string.
    * `:attrs` — everything else the target needs, as the source names it. Its keys are never
      turned into atoms.
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

    field :modified_at, DateTime.t(), validator: {MishkaCmsMigration.Source.Item, :datetime}

    dynamic_field :attrs

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
    {item.kind, item.source_id, item.title, item.attrs, Enum.map(item.content || [], &piece/1)}
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
  def datetime(field, nil), do: {:ok, field, nil}
  def datetime(field, %DateTime{} = value), do: {:ok, field, value}

  def datetime(field, %NaiveDateTime{} = value),
    do: {:ok, field, DateTime.from_naive!(value, "Etc/UTC")}

  def datetime(field, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, field, datetime}
      {:error, _reason} -> naive(field, value)
    end
  end

  def datetime(field, _value), do: {:error, field, "must be a date and time"}

  defp naive(field, value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> {:ok, field, DateTime.from_naive!(naive, "Etc/UTC")}
      {:error, _reason} -> {:error, field, "must be an ISO 8601 date and time"}
    end
  end

  defp piece(piece), do: {piece.html, piece.name, piece.attrs, piece.raw}
end
