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

  `use` adds the plugin half — the `"migration:sources"` registration, see
  `MishkaCmsCore.ProviderRegistry` — and `id/0` and `label/0`. A source registers once it is
  supervised: an extension that ships one lists the module among the children of its own
  application's supervisor, as `MishkaCmsMigration.Application.plugins/0` lists this extension's.

  ## A run

  A run names its source by `id/0` (`MishkaCmsMigration.MigrationRun`'s `source`); a run of a
  source that is not installed is refused when it is created. The walk
  (`MishkaCmsMigration.Walker`) asks `connect/2` once, with the run's `connection` map and its
  secret opened (`MishkaCmsMigration.Secret`), then walks `kinds/0` in the order the source gives
  them, and pages through each with `list/3` until it answers no cursor. The walk does not sort the
  kinds: a source lists them in the order they must be imported, a kind before any kind that points
  at it, so authors come before the posts that name them. Each listed row goes through
  `normalize/3` and `MishkaCmsMigration.Item.build/1`. An error from `connect/2` or `list/3` fails
  the run; an error from `normalize/3` fails only that row, and the report says why.
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
