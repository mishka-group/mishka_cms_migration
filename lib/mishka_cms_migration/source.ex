# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Source do
  @moduledoc """
  A CMS a site is moved from: one module that is a `mishka_installer` plugin on the
  `"migration:sources"` event and implements the callbacks below. WordPress is the first; Joomla and
  others come the same way and reuse the mapping, the dry run, the import job and the report.

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
        def fetch(req, kind, id), do: ...

        @impl true
        def normalize(row, "post", _context),
          do: {:ok, %{source_id: row["id"], title: row["title"], content: [%{html: row["html"]}]}}
      end

  Supervise the module in the extension's application, like any other plugin (`plugins/0`). `use`
  adds the plugin half — the `"migration:sources"` registration, see
  `MishkaCmsCore.ProviderRegistry` — and `id/0` and `label/0`.

  ## A run

  A run names its source by `id/0` (`MishkaCmsMigration.MigrationRun`'s `source`). The pipeline
  (`MishkaCmsMigration.Pipeline`) asks `connect/2` once, with the run's `connection` map and its
  secret opened (`MishkaCmsMigration.Secret`), then walks `kinds/0` in order — a kind another kind
  points at comes first, so authors come before posts — and pages through each with `list/3` until
  it answers no cursor. Each listed row goes through `normalize/3` and
  `MishkaCmsMigration.Item.build/1`. An error from `connect/2` or `list/3` fails the run; an error
  from `normalize/3` fails only that row, and the report says why.

  `fetch/3` reads one item again by its id, for trying one item again without walking the source.
  """

  alias MishkaCmsCore.ProviderRegistry

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
          options: MishkaCmsMigration.Options.t()
        }

  @doc "The source's id, stored on a run."
  @callback id() :: String.t()

  @doc "The source's name, as a `gettext_noop/1` msgid."
  @callback label() :: String.t()

  @doc "The kinds of item this source lists, in the order they are imported."
  @callback kinds() :: [String.t()]

  @doc "Connects with a run's `connection` map and its opened secret (`nil` when it has none)."
  @callback connect(connection :: map(), secret :: String.t() | nil) ::
              {:ok, conn()} | {:error, term()}

  @doc "One page of `kind` from `cursor`, and the cursor of the next page (`nil` after the last)."
  @callback list(conn(), kind :: String.t(), cursor()) ::
              {:ok, [term()], cursor()} | {:error, term()}

  @doc "One item of `kind` by its id on the source."
  @callback fetch(conn(), kind :: String.t(), source_id :: String.t()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  A listed row as the map `MishkaCmsMigration.Item.build/1` takes, without `:kind`, which the
  pipeline adds.
  """
  @callback normalize(row :: term(), kind :: String.t(), context()) ::
              {:ok, map()} | {:error, term()}

  @doc "Whether the source is offered on this installation. Every source is, unless it says not."
  @callback offered?() :: boolean()

  @optional_callbacks offered?: 0

  @doc false
  defmacro __using__(opts) do
    id = Keyword.fetch!(opts, :id)
    label = Keyword.fetch!(opts, :label)
    priority = Keyword.get(opts, :priority, 50)

    quote do
      use MishkaCmsCore.ProviderRegistry,
        event: "migration:sources",
        priority: unquote(priority)

      @behaviour MishkaCmsMigration.Source

      @impl MishkaCmsMigration.Source
      def id, do: unquote(id)

      @impl MishkaCmsMigration.Source
      def label, do: unquote(label)
    end
  end

  @doc "The event a source plugin listens on."
  @spec event() :: String.t()
  def event, do: @event

  @doc "Every registered source, the first of each id."
  @spec all() :: [module()]
  def all, do: ProviderRegistry.all(@event, __MODULE__)

  @doc "The offered source registered under `id`."
  @spec fetch(String.t() | nil) :: {:ok, module()} | {:error, :unknown_provider | :cannot_run}
  def fetch(id), do: ProviderRegistry.fetch(@event, __MODULE__, id)
end
