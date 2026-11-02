# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.MigrationRun do
  @moduledoc """
  One move of a site's content from another CMS: which source it reads (`source`, a
  `MishkaCmsMigration.Source` id), which host it reads from (`source_host`, so a site may take
  content from several sources, each run showing its own), how it connects
  (`connection`, and the secret sealed in `connection_secret`), what the admin chose (`options`)
  and how far it got.

  ## The admin's choices

  `options` is checked by the resource's own guardedstruct (`options` is a `sub_field`): a key or a
  value it does not know is refused as an invalid attribute named by its key, under the path
  `[:options]`. It is stored with every choice, what the admin chose and the default of each one
  left out. A job turns the stored map, whose keys are strings, into
  `MishkaCmsMigration.MigrationRun.Options`, the struct the `sub_field` generates, with its
  `builder/1`, and hands it to every target:

    * `:authors` — `"connect"` (the default) ties each source author to an existing user, matched by
      email; `"create"` makes a user and a blog author for each.
    * `:pages` — `"draft"` (the default) brings pages in as drafts; `"publish"` puts them live at
      their old addresses.
    * `:post_address` — `"blog"` (the default) serves posts at `/blog/<slug>` with a 301 from each
      old address; `"keep"` keeps the source's own addresses.
    * `:comments` — whether comments come too; `false` by default.

  No target reads them yet: the authors choice is read by the author and post targets, pages by the
  page target, post addresses by the post and redirect targets and comments by the comment target,
  as each kind's import comes.

  ## Its life

      :pending ─ start_dry_run ─▶ :dry_running ─▶ :dry_run ─ start_import ─▶ :importing ─▶ :done
                                        │            │ ▲                          │
                                        │            └─┘ start_dry_run again      │
                                        └──────────────────────▶ :failed ◀────────┘

      cancel: :pending, :dry_running, :dry_run or :importing ─▶ :cancelled

  An admin creates a run (`:create`), asks for a dry run (`:start_dry_run`) and, once it has
  reported, for the import (`:start_import`). Each request queues the job of one of the run's
  AshOban triggers, `:run_dry_run` or `:run_import`, on the `migration` queue
  (`MishkaCmsMigration.Workers.DryRunWorker`, `MishkaCmsMigration.Workers.ImportWorker`), as the
  admin who asked (`MishkaCmsMigration.Resources.Changes.EnqueueJob`). A trigger has no
  scheduler: its job is queued by the request alone, and runs only while the run is in the status
  the trigger's `where` names. One run of a site is dry running or importing at a time: the
  `:one_active_per_site` identity is a unique index on the site over those two statuses, so the
  database refuses a second and nothing changes. A job tries three times, an hour each
  (`MishkaCmsMigration.Workers`).

  The job's action walks the source (`MishkaCmsMigration.Workers.Helpers.Pipeline`) and saves its
  `report` (`MishkaCmsMigration.Report`) through `:finish_dry_run` or `:finish_import` and how far
  it is through `:record_progress`; after its last attempt fails, AshOban runs `:fail`, the
  triggers' `on_error`, which keeps the reason. Those six are the system's own: every actor is
  refused them, and only what AshOban runs, and what its job runs with its context, passes
  (`AshOban.Checks.AshObanInteraction`).

  An admin ends a run that is not done with `:cancel`, which frees the site for another: its job,
  waiting or running, is cancelled (`MishkaCmsMigration.Resources.Changes.CancelJobs`); a job that
  already left the queue finds the run out of its trigger's `where` and is cancelled, or, already
  walking, stops at its next page. The job's write and the record of each item share one
  transaction, so a job stopped there leaves either both or neither. A job Oban stops on its last
  attempt, at its timeout, never reaches `on_error` and fails its run through Oban's own telemetry
  (`MishkaCmsMigration.Workers.attach/0`); `:cancel` is how an admin ends a run whose job was lost
  with its node.

  Running again means a new run; the items earlier runs wrote
  (`MishkaCmsMigration.MigrationItem`) are what makes it update rather than duplicate.
  `created_count`, `updated_count`, `skipped_count` and `failed_count` count the items this run was
  the last to touch.

  ## The source's secret

  The secret a source signs in with (such as a WordPress application password) is the `:create`
  action's `secret` argument. Only its sealed form is kept, in `connection_secret`, sealed the way
  `MishkaCmsCore.Settings` seals a `:secret` setting: `Phoenix.Token.encrypt/4` with the endpoint's
  `secret_key_base`, under a salt of this extension's own. The argument is dropped once sealed. The
  sealed secret is kept from the run's creation until it ends — done, failed or cancelled — and is
  cleared then; a job opens it with `open_secret/1` each time it connects to the source.

  A run with no secret hands the source `nil`. A secret that is stored but cannot be opened —
  `secret_key_base` was rotated since it was sealed — is `{:error, :unreadable_secret}`, which fails
  the run: the admin starts a new run with the secret typed again.

  ## Who reaches it

  A run is a site's own. Reading, creating, starting and cancelling one takes
  `admin:dashboard:migration` (or `admin:api:migration` over the API). A master (a user whose
  `site_id` is nil) reaches every site's runs; a site user only its own site's, whatever tenant it
  names. A run is created on the tenant (`:create`), which a site user may only name as its own
  site (`MishkaCmsCore.Runtime.Resources.Validations.TenantContext`), or by a master on the site it
  names (`:master_create`); the site filter holds reads and steps, so a create is decided before
  its source is asked anything.

  ## In the admin

  The Migration page lists a site's runs, every site's for a master, as a Gervaz table: the source,
  the address it is moved from, where the run is (`status_label/1`), what the last dry run or import
  did and when it started. The table follows the run's PubSub notifications, so a run moving on
  shows without a reload.

  A source's card opens the run's Gervaz form: the site's address and user (`connection`), the
  secret, and for a master the site the content moves to (`:master_create`). Its button, Check
  connection, creates the run, which connects to the source first
  (`MishkaCmsMigration.Resources.Changes.CheckConnection`): a source that does not answer or
  refuses the user keeps the form open with the reason, and nothing is saved. A run that is not
  given a `source_host` takes the host its source reads from the connection
  (`c:MishkaCmsMigration.Source.host/1`).
  """

  use Ash.Resource,
    otp_app: :mishka_cms_migration,
    domain: MishkaCmsMigration,
    data_layer: AshPostgres.DataLayer,
    extensions: [GuardedStruct.AshResource, AshOban, MishkaGervaz.Resource],
    notifiers: [Ash.Notifier.PubSub],
    authorizers: [Ash.Policy.Authorizer]

  use Gettext, backend: MishkaCmsCore.Gettext

  import Phoenix.Component, only: [sigil_H: 2]

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.Resources.Validations.TenantContext
  alias MishkaCmsMigration.Resources.Changes.{CancelJobs, CheckConnection, EnqueueJob, Reason}
  alias MishkaCmsMigration.Resources.Validations.{SourceInstalled, Status}
  alias MishkaCmsMigration.Workers.Helpers.Pipeline

  @statuses [:pending, :dry_running, :dry_run, :importing, :done, :failed, :cancelled]
  @endpoint Application.compile_env!(:mishka_cms_core, :endpoint)
  @secret_salt "mishka migration source secret"
  @outcomes MishkaCmsMigration.Report.outcomes()
  @counts Enum.map(@outcomes, &{&1, [type: :integer, allow_nil?: false]})
  @busy dgettext_noop(
          "errors",
          "Another migration of this site is still waiting or running. Try again once it is done."
        )

  postgres do
    table "mishka_cms_migration_runs"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
      reference :user, on_delete: :nilify
    end

    custom_indexes do
      index [:site_id, :inserted_at], name: "mishka_cms_migration_runs_site_feed_index"
    end

    identity_wheres_to_sql one_active_per_site: "status IN ('dry_running', 'importing')"
  end

  guardedstruct do
    auto_wire true

    field :source, :string,
      derives:
        "sanitize(trim, downcase) validate(string, not_empty, max_len=64, regex=^[a-z0-9_-]+$)"

    field :source_host, :string,
      derives:
        "sanitize(trim, downcase) validate(string, not_empty, max_len=255, regex=^[a-z0-9.-]+(:[0-9]+)?$)"

    field :connection, :map, derives: "validate(map)"

    sub_field :options, :map, authorized_fields: true do
      field :authors, :string,
        default: "connect",
        derives: "sanitize(trim) validate(enum=String[connect::create])"

      field :pages, :string,
        default: "draft",
        derives: "sanitize(trim) validate(enum=String[draft::publish])"

      field :post_address, :string,
        default: "blog",
        derives: "sanitize(trim) validate(enum=String[blog::keep])"

      field :comments, :boolean, default: false, derives: "validate(boolean)"
    end
  end

  oban do
    triggers do
      trigger :run_dry_run do
        action :run_dry_run
        where expr(status == :dry_running)
        queue(:migration)
        scheduler_cron(false)
        lock_for_update?(false)
        max_attempts(3)
        backoff :exponential
        timeout :timer.hours(1)
        on_error :fail
        actor_persister(MishkaCmsMigration.Workers.Helpers.Actor)
        shared_context([:ash_oban?])
        worker_module_name(MishkaCmsMigration.Workers.DryRunWorker)
      end

      trigger :run_import do
        action :run_import
        where expr(status == :importing)
        queue(:migration)
        scheduler_cron(false)
        lock_for_update?(false)
        max_attempts(3)
        backoff :exponential
        timeout :timer.hours(1)
        on_error :fail
        actor_persister(MishkaCmsMigration.Workers.Helpers.Actor)
        shared_context([:ash_oban?])
        worker_module_name(MishkaCmsMigration.Workers.ImportWorker)
      end
    end
  end

  mishka_gervaz do
    table do
      identity do
        name :migration_runs
        route "/admin/dashboard/migration"
        stream_name :migration_runs
      end

      source do
        preload do
          always [:site]
        end
      end

      columns do
        default_sort inserted_at: :desc

        column :source do
          label fn -> dgettext("mishka_gervaz", "Source") end

          ui do
            width "minmax(120px,0.8fr)"
          end

          render fn source ->
            assigns = %{label: MishkaCmsMigration.Source.label(source)}

            ~H"""
            <span data-role="run-source" class="text-[13.5px] font-semibold text-[#17161a]">
              {@label}
            </span>
            """
          end
        end

        column :source_host do
          label fn -> dgettext("mishka_gervaz", "From") end

          ui do
            width "minmax(180px,1.4fr)"
          end
        end

        column :status do
          label fn -> dgettext("mishka_gervaz", "Status") end
          sortable true

          ui do
            width "minmax(130px,0.9fr)"
          end

          render fn status ->
            assigns = %{
              status: status,
              label: MishkaCmsMigration.MigrationRun.status_label(status),
              class: MishkaCmsMigration.MigrationRun.status_class(status)
            }

            ~H"""
            <span
              data-role="run-status"
              data-status={@status}
              class={[
                "inline-flex items-center rounded-[6px] px-[7px] py-[2px] text-[11px] font-semibold",
                @class
              ]}
            >
              {@label}
            </span>
            """
          end
        end

        column :result do
          static true
          requires [:report]
          label fn -> dgettext("mishka_gervaz", "Result") end

          ui do
            width "minmax(200px,1.4fr)"
          end

          render fn record ->
            assigns = %{summary: MishkaCmsMigration.MigrationRun.result_summary(record.report)}

            ~H"""
            <span data-role="run-result" class="text-[12.5px] text-[#3a382f]">{@summary}</span>
            """
          end
        end

        column :started do
          static true
          requires [:site_id, :site, :inserted_at]
          label fn -> dgettext("mishka_gervaz", "Started") end
          sortable true
          sort_field [:inserted_at]

          ui do
            width "minmax(140px,1fr)"
          end

          render fn record, state ->
            assigns = %{
              started: MishkaCmsCore.Localized.date(record.inserted_at, :yMMMd),
              site_name: state.master_user? && record.site && record.site.name
            }

            ~H"""
            <div class="min-w-0">
              <div :if={@site_name} class="truncate text-[12.5px] font-medium text-[#3a382f]">
                {@site_name}
              </div>
              <div class="text-[12px] text-[#8a877f]">{@started}</div>
            </div>
            """
          end
        end
      end

      realtime do
        prefix "migration_run"

        visible fn record, user ->
          is_nil(user.site_id) or record.site_id == user.site_id
        end
      end

      url_sync do
        mode :bidirectional
        params [:sort, :page]
        prefix "runs"
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No migration has run yet"),
                  icon: "hero-arrows-right-left"

      presentation do
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Admin
      end
    end

    form do
      identity do
        name :migration_run_form
      end

      source do
        access :update, false

        actions do
          create {:master_create, :create}
        end
      end

      fields do
        field :site_id, :relation do
          restricted true
          required true
          show_on :create
          display_field :name
          search_field :name
          mode :search

          ui do
            label fn -> dgettext("mishka_gervaz", "Site") end
            description fn -> dgettext("mishka_gervaz", "The site the content moves to.") end
          end
        end

        field :source, :hidden do
          required true
        end

        field :connection, :key_map do
          required true

          options [
            [
              name: :url,
              type: :text,
              label: dgettext_noop("mishka_gervaz", "Address"),
              placeholder: "https://example.com"
            ],
            [
              name: :user,
              type: :text,
              label: dgettext_noop("mishka_gervaz", "User"),
              placeholder: "admin"
            ]
          ]

          ui do
            label fn -> dgettext("mishka_gervaz", "WordPress site") end
          end
        end

        field :secret, :password do
          virtual true

          ui do
            label fn -> dgettext("mishka_gervaz", "Application password") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Made in WordPress under Users, Profile, Application Passwords. It is kept sealed until the run ends."
              )
            end

            autocomplete "off"
          end
        end
      end

      groups do
        group :connection do
          fields [:site_id, :source, :connection, :secret]

          ui do
            columns 1
          end
        end
      end

      submit do
        create label: fn -> dgettext("mishka_gervaz", "Check connection") end
        cancel label: fn -> dgettext("mishka_gervaz", "Cancel") end
        position :bottom
      end

      presentation do
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Admin
      end

      hooks do
        on_cancel fn state -> state end
      end
    end
  end

  actions do
    read :read do
      description "A site's runs"
      primary? true

      pagination offset?: true,
                 keyset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false
    end

    read :master_read do
      description "Every site's runs (masters)"
      multitenancy :bypass

      pagination offset?: true,
                 keyset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false

      validate {TenantContext, require_master: true}
    end

    read :master_get do
      description "One run of any site (masters)"
      multitenancy :bypass
      get? true

      validate {TenantContext, require_master: true}
    end

    create :create do
      primary? true
      accept [:source, :source_host, :connection, :options]

      argument :secret, :string do
        sensitive? true
        allow_nil? true
        description "The secret the source signs in with; only its sealed form is kept"
      end

      validate {TenantContext, require_master: false}
      change CheckConnection
      validate present([:source, :source_host])
      validate SourceInstalled, before_action?: true

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)
      change set_attribute(:user_id, actor(:id))
      change &MishkaCmsMigration.MigrationRun.seal_secret/2

      description "Creates a run on the tenant's site, started by the actor, once its source answers"
    end

    create :master_create do
      accept [:site_id, :source, :source_host, :connection, :options]

      argument :secret, :string do
        sensitive? true
        allow_nil? true
        description "The secret the source signs in with; only its sealed form is kept"
      end

      validate {TenantContext, require_master: true}
      change CheckConnection
      validate present([:site_id, :source, :source_host])
      validate SourceInstalled, before_action?: true

      change fn changeset, _context ->
        Ash.Changeset.set_tenant(changeset, Ash.Changeset.get_attribute(changeset, :site_id))
      end

      change set_attribute(:user_id, actor(:id))
      change &MishkaCmsMigration.MigrationRun.seal_secret/2

      description "Creates a run on the site it names, started by the master, once its source answers"
    end

    update :start_dry_run do
      accept []

      validate {TenantContext, require_master: false}
      validate {Status, from: [:pending, :dry_run]}

      change set_attribute(:status, :dry_running)
      change {EnqueueJob, trigger: :run_dry_run}

      description "Queues a dry run: what an import would create, update and skip, writing nothing"
    end

    update :start_import do
      accept []

      validate {TenantContext, require_master: false}
      validate {Status, from: [:dry_run]}

      change set_attribute(:status, :importing)
      change {EnqueueJob, trigger: :run_import}

      description "Queues the import of a run whose dry run has reported"
    end

    update :run_dry_run do
      accept []
      transaction? false
      require_atomic? false

      validate {Status, from: [:dry_running]}

      manual {Pipeline, mode: :dry_run}

      description "System-internal: the dry run's job walks the source and saves the report"
    end

    update :run_import do
      accept []
      transaction? false
      require_atomic? false

      validate {Status, from: [:importing]}

      manual {Pipeline, mode: :import}

      description "System-internal: the import's job writes every item and saves the report"
    end

    update :finish_dry_run do
      accept [:report, :extra]

      validate {Status, from: [:dry_running]}

      change set_attribute(:status, :dry_run)

      description "System-internal: saves the dry run's report"
    end

    update :finish_import do
      accept [:report, :extra]

      validate {Status, from: [:importing]}

      change set_attribute(:status, :done)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change set_attribute(:connection_secret, nil)

      description "System-internal: saves the import's report"
    end

    update :cancel do
      accept []

      validate {TenantContext, require_master: false}
      validate {Status, from: [:pending, :dry_running, :dry_run, :importing]}

      change set_attribute(:status, :cancelled)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change set_attribute(:connection_secret, nil)
      change CancelJobs

      description "Ends a run that is not done: its job is cancelled and its secret cleared"
    end

    update :record_progress do
      accept [:progress]

      validate {Status, from: [:dry_running, :importing]}

      description "System-internal: how far the running job is, saved after each page it walks"
    end

    update :fail do
      accept []

      argument :error, :term do
        allow_nil? false
        description "What stopped the job: AshOban's error after the last attempt, or Oban's"
      end

      validate {Status, from: [:dry_running, :importing]}

      change Reason
      change set_attribute(:status, :failed)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change set_attribute(:connection_secret, nil)

      description "System-internal: saves why a dry run or an import could not go on"
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    policy action([
             :run_dry_run,
             :run_import,
             :finish_dry_run,
             :finish_import,
             :record_progress,
             :fail
           ]) do
      forbid_if always()
    end

    policy action_type([:read, :create, :update]) do
      access_type :strict

      authorize_if {AccessPermissions,
                    permissions: ["admin:dashboard:migration", "admin:api:migration"]}
    end

    policy action_type([:read, :update]) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(site_id == ^actor(:site_id))
    end
  end

  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "migration_run"
    transform &MishkaCmsMigration.MigrationRun.broadcast/1

    publish_all :create, [[nil, :site_id], "created"]
    publish_all :update, [[nil, :site_id], "updated"]
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :source, :string do
      allow_nil? false
      public? true
      constraints max_length: 64
      description "The id of the source plugin the run reads (MishkaCmsMigration.Source)"
    end

    attribute :source_host, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
      description "The host the run reads from, such as example.com or localhost:8080"
    end

    attribute :connection, :map do
      allow_nil? false
      public? true
      default %{}
      description "How the source connects, without its secret: an address, a user name, a file"
    end

    attribute :connection_secret, :string do
      allow_nil? true
      sensitive? true

      description "The source's secret, sealed (open_secret/1); cleared once the run ends"
    end

    attribute :options, :map do
      allow_nil? false
      public? true
      default %{}
      description "What the admin chose for this run (MishkaCmsMigration.MigrationRun.Options)"
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: @statuses
      description "Where the run is in its life"
    end

    attribute :report, :map do
      allow_nil? true
      public? true

      constraints fields: [
                    counts: [type: :map, allow_nil?: false, constraints: [fields: @counts]],
                    kinds: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [fields: [{:kind, [type: :string, allow_nil?: false]} | @counts]]
                      ]
                    ],
                    entries: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          preserve_nil_values?: true,
                          fields: [
                            kind: [type: :string, allow_nil?: false],
                            source_id: [type: :string],
                            title: [type: :string],
                            outcome: [
                              type: :atom,
                              allow_nil?: false,
                              constraints: [one_of: @outcomes]
                            ],
                            reason: [type: :string]
                          ]
                        ]
                      ]
                    ]
                  ]

      description "What the last dry run or import did with each item (MishkaCmsMigration.Report)"
    end

    attribute :extra, :map do
      allow_nil? false
      public? true
      default %{}
      description "Facts about the source, such as its version and plugins (Source's extra/1)"
    end

    attribute :progress, :map do
      allow_nil? true
      public? true

      constraints fields: [
                    kind: [type: :string, allow_nil?: false],
                    counts: [type: :map, allow_nil?: false, constraints: [fields: @counts]]
                  ]

      description "How far the running job is: the kind it walks and the counts so far"
    end

    attribute :reason, :string do
      allow_nil? true
      public? true
      constraints max_length: 2000
      description "Why the run failed"
    end

    attribute :finished_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When the import was done or the run failed"
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site the content moves into"
    end

    belongs_to :user, MishkaCmsCore.Accounts.User do
      domain MishkaCmsCore.Accounts
      read_action :related
      sortable? false
      allow_nil? true
      public? true
      description "Who created the run"
    end

    has_many :items, MishkaCmsMigration.MigrationItem do
      destination_attribute :run_id
      public? true
      description "The items this run was the last to touch"
    end
  end

  aggregates do
    count :created_count, :items do
      public? true
      filter expr(outcome == :created)
    end

    count :updated_count, :items do
      public? true
      filter expr(outcome == :updated)
    end

    count :skipped_count, :items do
      public? true
      filter expr(outcome == :skipped)
    end

    count :failed_count, :items do
      public? true
      filter expr(outcome == :failed)
    end
  end

  identities do
    identity :one_active_per_site, [:site_id],
      where: expr(status in [:dry_running, :importing]),
      message: @busy
  end

  @doc """
  The source's secret `run` keeps, opened: `{:ok, secret}`, `{:ok, nil}` when it keeps none, or
  `{:error, :unreadable_secret}` when it was sealed under another `secret_key_base`.
  """
  @spec open_secret(map()) :: {:ok, String.t() | nil} | {:error, :unreadable_secret}
  def open_secret(%{connection_secret: sealed}) when is_binary(sealed) and sealed != "",
    do: @endpoint |> Phoenix.Token.decrypt(@secret_salt, sealed, max_age: :infinity) |> opened()

  def open_secret(_run), do: {:ok, nil}

  @doc false
  def seal_secret(changeset, _context) do
    secret = Ash.Changeset.get_argument(changeset, :secret)
    changeset |> Ash.Changeset.delete_argument(:secret) |> sealed(secret)
  end

  @doc "Where a run with `status` is, as the admin reads it."
  @spec status_label(atom()) :: String.t()
  def status_label(:pending), do: dgettext("mishka_gervaz", "Connected")
  def status_label(:dry_running), do: dgettext("mishka_gervaz", "Dry run running")
  def status_label(:dry_run), do: dgettext("mishka_gervaz", "Dry run ready")
  def status_label(:importing), do: dgettext("mishka_gervaz", "Importing")
  def status_label(:done), do: dgettext("mishka_gervaz", "Imported")
  def status_label(:failed), do: dgettext("mishka_gervaz", "Failed")
  def status_label(:cancelled), do: dgettext("mishka_gervaz", "Cancelled")

  @doc "The badge colours of a run with `status`."
  @spec status_class(atom()) :: String.t()
  def status_class(status) when status in [:dry_running, :importing],
    do: "bg-[#eef0ff] text-[#4f4bcc]"

  def status_class(:dry_run), do: "bg-[#fff6e0] text-[#8a5a00]"
  def status_class(:done), do: "bg-[#e6f6ee] text-[#177a53]"
  def status_class(:failed), do: "bg-[#fdecea] text-[#c0473d]"
  def status_class(_waiting_or_cancelled), do: "bg-[#f1f0ec] text-[#6f6c64]"

  @doc """
  What a run's `report` counts, in one line: `"3 created · 1 updated · 2 skipped · 0 failed"`, or
  `"—"` before its first dry run.
  """
  @spec result_summary(map() | nil) :: String.t()
  def result_summary(%{counts: counts}) do
    Enum.map_join(MishkaCmsMigration.Report.outcomes(), " · ", fn outcome ->
      "#{MishkaCmsCore.Localized.number(Map.get(counts, outcome, 0))} #{outcome_label(outcome)}"
    end)
  end

  def result_summary(_no_report), do: "—"

  defp outcome_label(:created), do: dgettext("mishka_gervaz", "created")
  defp outcome_label(:updated), do: dgettext("mishka_gervaz", "updated")
  defp outcome_label(:skipped), do: dgettext("mishka_gervaz", "skipped")
  defp outcome_label(:failed), do: dgettext("mishka_gervaz", "failed")

  @doc """
  What the run's PubSub notifications carry (`pub_sub`'s `transform`): the notification with the
  run's `connection` and `connection_secret` emptied and without its changeset, whose input held
  the secret as typed. A subscriber that needs the connection reads the run.
  """
  @spec broadcast(Ash.Notifier.Notification.t()) :: Ash.Notifier.Notification.t()
  def broadcast(%Ash.Notifier.Notification{data: run} = notification),
    do: %{notification | data: %{run | connection: %{}, connection_secret: nil}, changeset: nil}

  defp opened({:ok, secret}) when is_binary(secret), do: {:ok, secret}
  defp opened(_unreadable), do: {:error, :unreadable_secret}

  defp sealed(changeset, secret) when is_binary(secret) and secret != "",
    do:
      Ash.Changeset.force_change_attribute(
        changeset,
        :connection_secret,
        Phoenix.Token.encrypt(@endpoint, @secret_salt, secret)
      )

  defp sealed(changeset, _none), do: changeset
end
