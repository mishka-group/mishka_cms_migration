# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Target do
  @moduledoc """
  Where one kind of item goes in the CMS: one module that is a `mishka_installer` plugin on the
  `"migration:targets"` event and names an existing CMS resource and the create and update actions
  that write it. The extension adds no write path of its own: every row is written by that action,
  as the admin who pressed Import and under the run's site, so the resource's policies, validations
  and plugins decide as they do for anything else.

      defmodule MyExtension.Targets.Post do
        use MishkaCmsMigration.Target,
          kind: "post",
          resource: MishkaBlog.BlogPost,
          create: :create,
          update: :update

        @impl true
        def attrs(item, _context) do
          %{
            title: item.title,
            slug: item.attrs["slug"],
            content: MishkaCmsMigration.Item.html(item)
          }
        end
      end

  `:create` and `:update` default to the resource's `:create` and `:update`. `use` makes the module
  a plugin on `"migration:targets"` — registering is the declaration; the event is never fired, and
  the plugin's `call/1` hands its state back — and adds `id/0` (the kind), `resource/0` and
  `actions/0`; a target writes only `attrs/2`.

  A target registers once it is supervised. An extension that ships one lists the module among the
  children of its own application's supervisor, as `MishkaCmsMigration.Application.plugins/0` lists
  this extension's; no list here names it. Which target writes a kind is read from mishka_installer's
  registry (`MishkaCmsMigration.Registry`): a target an operator stops in the installer writes
  nothing, and its kind is skipped as `"no_target"`.

  ## What the resource needs

  Checked when the target compiles, which fails with the reason when one is missing:

    * it is an Ash resource whose primary key is `:id`, a UUID — an item records the row it wrote
      by that id (`MishkaCmsMigration.MigrationItem`'s `target_id`);
    * it has an `updated_at` timestamp — a re-run compares it with the one recorded when the row was
      written, to keep an admin's edits (below);
    * `:create` names one of its create actions and `:update` one of its update actions.

  ## Keeping an admin's edits

  A re-run reads the rows earlier runs wrote (`current/3`) and compares each one's `updated_at`
  with the one the run recorded when it wrote it. A row changed in the CMS since is never written
  again, and one that is gone is not brought back.
  """

  require Ash.Query

  alias Ash.Resource.Info
  alias MishkaCmsMigration.{Item, Registry}

  @event "migration:targets"

  @typedoc "What `attrs/2` is told: who writes, on which site, from which run, with which choices."
  @type context :: %{
          actor: map(),
          site_id: String.t(),
          run_id: String.t(),
          source_host: String.t(),
          options: map()
        }

  @doc "The kind of item this target writes, such as `\"post\"`."
  @callback id() :: String.t()

  @doc "The CMS resource the rows are written to."
  @callback resource() :: Ash.Resource.t()

  @doc "The resource's actions this target writes through."
  @callback actions() :: %{create: atom(), update: atom()}

  @doc "The input of the create or update action for `item`."
  @callback attrs(Item.t(), context()) :: map()

  @doc false
  defmacro __using__(opts) do
    kind = Keyword.fetch!(opts, :kind)
    resource = Keyword.fetch!(opts, :resource)
    create = Keyword.get(opts, :create, :create)
    update = Keyword.get(opts, :update, :update)
    priority = Keyword.get(opts, :priority, 50)

    quote do
      use MishkaInstaller.Event.Hook,
        event: "migration:targets",
        initial: %{priority: unquote(priority)}

      @behaviour MishkaCmsMigration.Target
      @after_compile MishkaCmsMigration.Target

      require unquote(resource)

      @impl true
      def call(state), do: {:reply, state}

      @impl MishkaCmsMigration.Target
      def id, do: unquote(kind)

      @impl MishkaCmsMigration.Target
      def resource, do: unquote(resource)

      @impl MishkaCmsMigration.Target
      def actions, do: %{create: unquote(create), update: unquote(update)}
    end
  end

  @doc false
  def __after_compile__(env, _bytecode) do
    case problems(env.module.resource(), env.module.actions()) do
      [] ->
        :ok

      problems ->
        raise ArgumentError,
              "#{inspect(env.module)} cannot be a migration target: " <> Enum.join(problems, "; ")
    end
  end

  @doc "The event a target plugin registers on."
  @spec event() :: String.t()
  def event, do: @event

  @doc "The installed target that writes `kind`."
  @spec fetch(String.t() | nil) :: {:ok, module()} | {:error, :not_installed}
  def fetch(kind), do: Registry.fetch(@event, __MODULE__, kind)

  @doc """
  The rows of `ids` the target's resource still holds on `site_id`, by id. Read through the
  resource's primary read as the system: only to tell whether each row is still there and when it
  last changed.
  """
  @spec current(module(), [String.t()], String.t()) :: %{String.t() => struct()}
  def current(_target, [], _site_id), do: %{}

  def current(target, ids, site_id) do
    target.resource()
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(tenant: site_id, authorize?: false)
    |> Map.new(&{&1.id, &1})
  end

  @doc """
  Writes `item` through the target's create action, or through its update action over `record`, as
  `context.actor` under `context.site_id`.
  """
  @spec write(module(), Item.t(), struct() | nil, context()) ::
          {:ok, struct()} | {:error, term()}
  def write(target, item, nil, context) do
    target.resource()
    |> Ash.Changeset.for_create(target.actions().create, target.attrs(item, context), as(context))
    |> Ash.create()
  end

  def write(target, item, record, context) do
    record
    |> Ash.Changeset.for_update(target.actions().update, target.attrs(item, context), as(context))
    |> Ash.update()
  end

  defp as(context), do: [actor: context.actor, tenant: context.site_id]

  defp problems(resource, actions) do
    case Info.resource?(resource) do
      true -> resource_problems(resource, actions)
      false -> ["#{inspect(resource)} is not an Ash resource"]
    end
  end

  defp resource_problems(resource, actions) do
    [
      {uuid_id?(resource), "its primary key must be :id, a UUID"},
      {timestamped?(resource), "it must have an updated_at timestamp"},
      {action?(resource, actions.create, :create),
       "#{inspect(actions.create)} is not one of its create actions"},
      {action?(resource, actions.update, :update),
       "#{inspect(actions.update)} is not one of its update actions"}
    ]
    |> Enum.reject(&elem(&1, 0))
    |> Enum.map(&"#{inspect(resource)}: #{elem(&1, 1)}")
  end

  defp uuid_id?(resource) do
    Info.primary_key(resource) == [:id] and
      Info.attribute(resource, :id).type in [Ash.Type.UUID, Ash.Type.UUIDv7]
  end

  defp timestamped?(resource) do
    case Info.attribute(resource, :updated_at) do
      %{type: type} -> type in [Ash.Type.UtcDatetimeUsec, Ash.Type.UtcDatetime, Ash.Type.DateTime]
      nil -> false
    end
  end

  defp action?(resource, name, type) do
    match?(%{type: ^type}, Info.action(resource, name))
  end
end
