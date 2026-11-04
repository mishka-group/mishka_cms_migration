# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Target do
  @moduledoc """
  Where one kind of item goes in the CMS: one module that is a `mishka_installer` plugin on the
  `"migration:targets"` event and names an existing CMS resource and the create and update actions
  that write it. The extension adds no write path of its own: every record is written by that
  action, as the admin who pressed Import and under the run's site, so the resource's policies,
  validations and plugins decide as they do for anything else.

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
            content: MishkaCmsMigration.Source.Item.html(item)
          }
        end
      end

  `:create` and `:update` default to the resource's `:create` and `:update`. `use` makes the module
  a plugin on `"migration:targets"` — registering is the declaration; the event is never fired, and
  the plugin's `call/1` hands its state back — and adds `id/0` (the kind), `resource/0`,
  `actions/0`, a `note/2` that says nothing, an `existing/2` that finds nothing, a `prepare/3`
  that writes at once and a `waiting/2` that plans every write; a target writes only `attrs/2`,
  `note/2` when it writes an item otherwise than the source has it, `existing/2` when the CMS may
  already hold some of its items, and `prepare/3` and `waiting/2` when a write needs something
  from the source first or may wait for an admin.

  A target registers once it is supervised. An extension that ships one lists the module among the
  children of its own application's supervisor, as `MishkaCmsMigration.Application.plugins/0` lists
  this extension's; no list here names it. Which target writes a kind is read from
  mishka_installer's registry (`MishkaCmsMigration.Source.installed/2`): a target an operator stops
  in the installer writes nothing, and its kind is skipped as `"no_target"`, or, for a kind the
  Blog writes, waits for it (`"blog_missing"`, `MishkaCmsMigration.Application.blog_kinds/0`).

  ## What the resource needs

  Checked when the target compiles, which fails with the reason when one is missing:

    * it is an Ash resource whose primary key is `:id`, a UUID — an item records the record it wrote
      by that id (`MishkaCmsMigration.MigrationItem`'s `target_id`);
    * its `updated_at` is an `update_timestamp`, which Ash sets on every write and no input may
      set — a re-run compares it with the one recorded when the record was written, to keep an
      admin's edits (below); a plain `updated_at` attribute, or one an action may be handed, is
      refused;
    * `:create` names one of its create actions, or a generic action that answers one of its
      records (`returns :struct, constraints: [instance_of: <the resource>]`), such as the core
      Media's `:upload`, which stores a file and creates its record; `:update` names one of its
      update actions, or a create action that upserts (`upsert? true`), such as the core Setting's
      `:set`, which writes over the record with the same identity and keeps its id.

  ## The source's other fields

  `item.extra` holds the fields of the source's row the CMS has no home for (a WordPress post's
  custom fields, ACF fields, another plugin's meta); the item's record keeps them either way
  (`MishkaCmsMigration.MigrationItem`'s `extra`). A target whose resource keeps an `extra` map of
  its own — the core's pages, layouts and components do — may copy them there, under a key of its
  own so they sit beside what the CMS keeps in it:

      def attrs(item, _context),
        do: %{title: item.title, path: item.attrs["path"], extra: %{"migration" => item.extra}}

  ## An item's parent

  An item that sits under another of its kind (`MishkaCmsMigration.Source.Item`'s `parent`, such
  as a category's parent category) is written after its parent, and `attrs/2` is handed the id of
  the CMS record the parent was written to as `context.parent_id` (`nil` for an item with none), to
  put where the resource keeps its parent:

      def attrs(item, context),
        do: %{name: item.title, slug: item.attrs["slug"], parent_collection_id: context.parent_id}

  An item whose parent has no CMS record is not written; it is skipped as `"parent_missing"`
  (`MishkaCmsMigration.Workers.Helpers.Writer`). One whose parent an admin left out is skipped as
  `"parent_left_out"`, in a dry run too (`MishkaCmsMigration.Workers.Helpers.Pipeline`).

  ## A create and an update

  `attrs/2` builds the input of both actions. On an update its context's `record` is the CMS
  record being written over, and `nil` on a create, so a target can leave out what is set only
  once, such as whose profile a blog author is. It runs inside the write's transaction, as the
  admin: what it writes first for the record to point at (the Blog's author target makes the user
  its profile names) is rolled back with the record when the write fails, and one it cannot write
  raises, which fails the item with the error.

  ## What a write needs first

  A write that needs something from the source before it runs, such as a file to download, gets it
  in `prepare/3`. It is handed the item, the context `attrs/2` gets and `write`, the item's write and
  its record in one transaction, and answers what `write.(context)` answers, after putting what it
  fetched in the context's `prepared` for `attrs/2` to read, or `{:skipped, reason}` or
  `{:error, reason}` without writing: the item is then skipped or failed with `reason`. It may
  answer `{:connected, record, reason}` too, for an item it found to be a record the CMS already
  holds: nothing is written, and the item is recorded against `record`, as skipped with `reason`,
  the way `existing/2`'s `{:connected, record}` is. It may answer `{:undecided, conflict}` too, for a conflict only the write can tell, such as a player an
  admin who may not allow it would write: the item waits for an admin's decision, as one
  `existing/2` answers so does. It runs in
  an import only, after the item is converted and offered to the plugins, outside the write's
  transaction, so a slow source holds no database transaction open, and it cleans up what it
  fetched once `write` answers. `use` answers `write.(context)`.

  A dry run runs no `prepare/3`, so it asks `waiting/2` instead, of each item it would create or
  update, with the context `prepare/3` would get: what the import's `prepare/3` would answer
  without writing, `{:undecided, conflict}` or `{:skipped, reason}`, or `nil` for a write. The dry
  run then plans the item as the import would leave it: a post an earlier import wrote, whose
  player the admin may not allow, is planned as waiting for a decision, not as an update. `use`
  answers `nil`.

      def waiting(item, context), do: MishkaCmsMigration.Targets.Helpers.Frames.waiting(item, context)

      def prepare(item, %{record: nil} = context, write) do
        path = Plug.Upload.random_file!("migration")

        try do
          with :ok <- fetch(item, path), do: write.(%{context | prepared: path})
        after
          File.rm(path)
        end
      end

      def prepare(_item, context, write), do: write.(context)

  ## Where an item is written

  Every item of a kind goes to the target's `resource/0` through its `actions/0`. A target whose
  items go to different resources, such as a menu that an admin sends to the site layout or to a
  component of its own (`MishkaCmsMigration.Targets.CmsLayout`), names them all in `resources/0`
  and answers each item's in `writes_to/2`, handed the context with the item's decisions. The item
  records the resource of the record it was written to, and a re-run reads it from there.

  ## What the CMS already holds

  An item may already be in the CMS without any run having written it, such as a WordPress author
  who is a user of the site with a blog profile of their own. `existing/2` is handed a page's items
  no run has written yet, with the context `attrs/2` gets (no parent and no record), before
  anything is written and in a dry run too, and answers by source id:

    * `{:connected, record}` — the item is that CMS record. It is recorded against it and never
      written, by this run or a later one: the record is the CMS's own and is kept as it is, and
      the report says `"connected"` (`MishkaCmsMigration.Workers.Helpers.Decision`);
    * `{:updated, record}` — the item is written over that CMS record through the update action,
      as though an earlier run had written it, and is that record from then on: what a target
      answers whose item lands in a record every site already has, such as the main menu, which
      becomes the links of the site layout's header (`MishkaCmsMigration.Targets.CmsLayout`). A
      later run treats the record as any other a run wrote;
    * `{:skipped, reason}` — the item is left out, with `reason`;
    * `{:undecided, conflict}` — the item meets something the site already has that only an admin
      can settle, such as a setting the site has a value of its own for: nothing is written, the
      report says `conflict` (`MishkaCmsMigration.Report`), and every later run asks again until
      an admin decides on the Items page.

  An item the answer leaves out is created. It reads as the admin running the job, under the CMS's
  own policies. `use` answers `%{}`.

      def existing(items, context) do
        held = held_by_slug(items, context)

        for item <- items, record = held[item.attrs["slug"]], into: %{},
            do: {item.source_id, {:connected, record}}
      end

  ## An admin's decision

  An admin answers a conflict on the item's row (`MishkaCmsMigration.MigrationItem`'s
  `decisions`), and the answer holds for every later dry run and import. `decision/3` reads it from
  the context: `"keep"`, the site stays as it is (its own value is kept, the item is connected to
  the record it has, or it waits); `"import"`, the item is written the import's way; `nil` while no
  admin has answered. A target answers by it in `existing/2`, and in `note/2`, `prepare/3` and
  `attrs/2`, which are handed the same decisions:

      def existing(items, context) do
        for item <- items, own?(item, context), into: %{} do
          {item.source_id, kept(Target.decision(context, item, "site_has_own"))}
        end
      end

      defp kept("keep"), do: {:skipped, "site_own_kept"}
      defp kept("import"), do: {:updated, record}
      defp kept(nil), do: {:undecided, "site_has_own"}

  ## What the report says

  `note/2` is what the report says about an item the target writes otherwise than the source has
  it, such as a post pending review that the CMS keeps as a draft: a short code the admin page puts
  in words (`MishkaCmsMigration.MigrationRun.reason_label/1`), several joined by `"; "`, or `nil`.
  It is handed the context `attrs/2` gets, whose `mode` says whether the run is a `:dry_run`, which
  writes nothing, or an `:import`; in a dry run no parent is looked up. It is the entry's reason in
  a dry run and in an import, and the item's record keeps it, before the pieces of its content no
  plugin converted (`MishkaCmsMigration.Report`).

      def note(%{attrs: %{"status" => "pending"}}, _context), do: "draft_from_pending"
      def note(_item, _context), do: nil

  ## Keeping an admin's edits

  A re-run reads the records earlier runs wrote, as the admin running it
  (`MishkaCmsMigration.Workers.Helpers.Decision`), and compares each one's `updated_at` with the
  one the run recorded when it wrote it. A record changed in the CMS since is never written again,
  and one that is gone is not brought back.

  Items that share one record, such as the menus written into the site layout, each record the
  `updated_at` of their own write. A target that writes such a record again records the new
  `updated_at` for the other items of that record too (`MishkaCmsMigration.record_item/2`, with the
  context's `scope`), so a write of one is not mistaken for an edit in the CMS.
  """

  alias Ash.Resource.Info
  alias MishkaCmsMigration.Source
  alias MishkaCmsMigration.Source.Item

  @event "migration:targets"
  @uuid_types [Ash.Type.UUID, Ash.Type.UUIDv7]
  @timestamp_types [Ash.Type.UtcDatetimeUsec, Ash.Type.UtcDatetime, Ash.Type.DateTime]

  @typedoc """
  What `attrs/2` is told: whether the run is a dry run or an import, who writes, on which site,
  from which run of which source (its id, such as `"wordpress"`, and host), with which choices, the
  the job's `scope`, for a target that records other items it changed (see "Keeping an admin's
  edits"), the CMS record of the item's parent (see "An item's parent"), the record an update writes over (see
  "A create and an update"), what `prepare/3` fetched for the write (`nil` until it does), the language plugin the source runs
  (`languages`, `"polylang"` or `"wpml"`, else `nil`), and an
  admin's decisions on the items, by source id (see "An admin's decision", read with
  `decision/3`).
  """
  @type context :: %{
          mode: :dry_run | :import,
          actor: map(),
          scope: map(),
          site_id: String.t(),
          run_id: String.t(),
          source: String.t(),
          source_host: String.t(),
          options: map(),
          parent_id: Ecto.UUID.t() | nil,
          record: struct() | nil,
          prepared: term(),
          languages: String.t() | nil,
          decisions: %{String.t() => %{String.t() => String.t()}}
        }

  @typedoc """
  What `existing/2` says of one item: the CMS record it already is, the one it is written over, why
  it is left out, or the conflict it waits on for an admin's decision.
  """
  @type found ::
          {:connected, struct()}
          | {:updated, struct()}
          | {:skipped, String.t()}
          | {:undecided, String.t()}

  @doc "The kind of item this target writes, such as `\"post\"`."
  @callback id() :: String.t()

  @doc "The CMS resource the records are written to."
  @callback resource() :: Ash.Resource.t()

  @doc "The resource's actions this target writes through."
  @callback actions() :: %{create: atom(), update: atom()}

  @doc """
  Every resource this target writes, for a target whose items go to more than one (see "Where an
  item is written"). `use` answers `[resource()]`.
  """
  @callback resources() :: [Ash.Resource.t()]

  @doc """
  The resource and the actions that write `item` (see "Where an item is written"). `use` answers
  `{resource(), actions()}`.
  """
  @callback writes_to(Item.t(), context()) ::
              {Ash.Resource.t(), %{create: atom(), update: atom()}}

  @doc "The input of the create or update action for `item`."
  @callback attrs(Item.t(), context()) :: map()

  @doc """
  What the report says about `item` when it is written otherwise than the source has it, or `nil`
  (see "What the report says"). `use` answers `nil`.
  """
  @callback note(Item.t(), context()) :: String.t() | nil

  @doc """
  What the CMS already holds of `items`, a page of items no run has written yet, by source id; an
  item left out is created (see "What the CMS already holds"). `use` answers `%{}`.
  """
  @callback existing([Item.t()], context()) :: %{String.t() => found()}

  @doc """
  Runs `write`, the import's write of `item`, with what it needs from the source first, or answers
  `{:skipped, reason}`, `{:undecided, conflict}`, `{:connected, record, reason}` or
  `{:error, reason}` without writing (see "What a write needs first"). `use` answers
  `write.(context)`.
  """
  @callback prepare(Item.t(), context(), (context() -> result)) ::
              result
              | {:skipped, String.t()}
              | {:undecided, String.t()}
              | {:connected, struct(), String.t()}
              | {:error, term()}
            when result: term()

  @doc """
  What the target adds to the item's own record (`MishkaCmsMigration.MigrationItem`) when an import
  writes it, from what `prepare/3` fetched, such as `%{file_hash: hash}` for a downloaded file (see
  "What a write needs first"). `use` answers `%{}`.
  """
  @callback recorded(Item.t(), context()) :: map()

  @doc """
  What a dry run plans for `item`, one it would create or update, that the import's `prepare/3`
  would not write: `{:undecided, conflict}`, `{:skipped, reason}`, or `nil` for a write (see "What
  a write needs first"). `use` answers `nil`.
  """
  @callback waiting(Item.t(), context()) ::
              {:undecided, String.t()} | {:skipped, String.t()} | nil

  @doc false
  defmacro __using__(opts) do
    kind = Keyword.fetch!(opts, :kind)
    resource = Keyword.fetch!(opts, :resource)
    create = Keyword.get(opts, :create, :create)
    update = Keyword.get(opts, :update, :update)
    priority = Keyword.get(opts, :priority, 50)

    quote do
      use MishkaInstaller.Event.Hook,
        event: unquote(@event),
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

      @impl MishkaCmsMigration.Target
      def resources, do: [unquote(resource)]

      @impl MishkaCmsMigration.Target
      def writes_to(_item, _context), do: {unquote(resource), actions()}

      @impl MishkaCmsMigration.Target
      def note(_item, _context), do: nil

      @impl MishkaCmsMigration.Target
      def existing(_items, _context), do: %{}

      @impl MishkaCmsMigration.Target
      def prepare(_item, context, write), do: write.(context)

      @impl MishkaCmsMigration.Target
      def recorded(_item, _context), do: %{}

      @impl MishkaCmsMigration.Target
      def waiting(_item, _context), do: nil

      defoverridable resources: 0,
                     writes_to: 2,
                     note: 2,
                     existing: 2,
                     prepare: 3,
                     recorded: 2,
                     waiting: 2
    end
  end

  @doc false
  def __after_compile__(env, _bytecode),
    do: env.module.resource() |> problems(env.module.actions()) |> refused(env.module)

  @doc """
  The event a target plugin registers on, the one `use MishkaCmsMigration.Target` names: what an
  extension's own tests register a target for.
  """
  @spec event() :: String.t()
  def event, do: @event

  @doc "The installed target that writes `kind`."
  @spec fetch(String.t() | nil) :: {:ok, module()} | {:error, :not_installed}
  def fetch(kind), do: Source.installed(@event, __MODULE__, kind)

  @doc """
  What an admin decided on `item`'s `conflict` (see "An admin's decision"): `"keep"`, `"import"`,
  or `nil` while no admin has answered it, and for a context that carries no decisions.
  """
  @spec decision(map(), Item.t(), String.t()) :: String.t() | nil
  def decision(context, %Item{source_id: id}, conflict),
    do: get_in(context, [:decisions, id, conflict])

  defp refused([], _module), do: :ok

  defp refused(problems, module),
    do:
      raise(
        ArgumentError,
        "#{inspect(module)} cannot be a migration target: " <> Enum.join(problems, "; ")
      )

  defp problems(resource, actions), do: problems(Info.resource?(resource), resource, actions)

  defp problems(false, resource, _actions), do: ["#{inspect(resource)} is not an Ash resource"]

  defp problems(true, resource, actions) do
    [
      {uuid_id?(Info.primary_key(resource), Info.attribute(resource, :id)),
       "its primary key must be :id, a UUID"},
      {timestamped?(Info.attribute(resource, :updated_at)),
       "its updated_at must be an update_timestamp, set by Ash on every write and never by input"},
      {creates?(Info.action(resource, actions.create), resource),
       "#{inspect(actions.create)} is not one of its create actions, nor a generic action " <>
         "that answers one of its records"},
      {updates?(Info.action(resource, actions.update)),
       "#{inspect(actions.update)} is not one of its update actions, nor a create action " <>
         "that upserts"}
    ]
    |> Enum.reject(&elem(&1, 0))
    |> Enum.map(&"#{inspect(resource)}: #{elem(&1, 1)}")
  end

  defp uuid_id?([:id], %{type: type}) when type in @uuid_types, do: true
  defp uuid_id?(_primary_key, _id), do: false

  defp timestamped?(%{type: type, update_default: default, writable?: false})
       when type in @timestamp_types and not is_nil(default),
       do: true

  defp timestamped?(_updated_at), do: false

  defp creates?(%{type: :create}, _resource), do: true

  defp creates?(%{type: :action, returns: Ash.Type.Struct, constraints: constraints}, resource),
    do: constraints[:instance_of] == resource

  defp creates?(_action, _resource), do: false

  defp updates?(%{type: :update}), do: true
  defp updates?(%{type: :create, upsert?: true}), do: true
  defp updates?(_action), do: false
end
