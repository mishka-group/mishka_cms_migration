# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.MigrationRun do
  @moduledoc """
  One move of a site's content from another CMS: which source it reads (`source`, a
  `MishkaCmsMigration.Source` id), which host it reads from (`source_host`), how it connects
  (`connection`, and the secret sealed in `connection_secret`), what the admin chose
  (`options`, `MishkaCmsMigration.Options`) and how far it got.

  ## Its life

      :pending ─ start_dry_run ─▶ :dry_running ─▶ :dry_run ─ start_import ─▶ :importing ─▶ :done
                                        │            │ ▲                          │
                                        │            └─┘ start_dry_run again      │
                                        └──────────────────────▶ :failed ◀────────┘

  An admin creates a run (`:create`), asks for a dry run (`:start_dry_run`) and, once it has
  reported, for the import (`:start_import`). Each request queues a job on the `migration` queue
  (`MishkaCmsMigration.Workers.DryRunWorker`, `MishkaCmsMigration.Workers.ImportWorker`) carrying
  who asked; only one job of a site may wait or run at a time, so a request made while another is
  pending is refused and nothing changes. The job saves its `report` (`MishkaCmsMigration.Report`)
  through `:finish_dry_run` or `:finish_import`, or the reason it could not go on through `:fail`.
  Those three are the system's own: no actor may run them.

  A run that is done or failed keeps no secret: `connection_secret` is cleared. Running again
  means a new run; the items earlier runs wrote (`MishkaCmsMigration.MigrationItem`) are what makes
  it update rather than duplicate. `created_count`, `updated_count`, `skipped_count` and
  `failed_count` count the items this run was the last to touch.

  ## Who reaches it

  A run is a site's own. Reading, creating and starting one takes `admin:dashboard:migration` (or
  `admin:api:migration` over the API). A master (a user whose `site_id` is nil) reaches every
  site's runs; a site user only its own site's, whatever tenant it names.
  """

  use Ash.Resource,
    otp_app: :mishka_cms_migration,
    domain: MishkaCmsMigration,
    data_layer: AshPostgres.DataLayer,
    extensions: [GuardedStruct.AshResource],
    notifiers: [Ash.Notifier.PubSub],
    authorizers: [Ash.Policy.Authorizer]

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.Resources.Validations.TenantContext
  alias MishkaCmsMigration.Resources.Changes.{BuildStruct, EnqueueJob, SealSecret}
  alias MishkaCmsMigration.Resources.Validations.Status
  alias MishkaCmsMigration.Workers.{DryRunWorker, ImportWorker}

  @statuses [:pending, :dry_running, :dry_run, :importing, :done, :failed]
  @outcomes MishkaCmsMigration.Report.outcomes()
  @counts Enum.map(@outcomes, &{&1, [type: :integer, allow_nil?: false]})

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
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:source, :source_host, :connection, :options]

      argument :secret, :string do
        sensitive? true
        allow_nil? true
        description "The secret the source signs in with; only its sealed form is kept"
      end

      validate {TenantContext, require_master: false}
      validate present([:source, :source_host])

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)
      change set_attribute(:user_id, actor(:id))
      change {BuildStruct, attribute: :options, struct: MishkaCmsMigration.Options}
      change {SealSecret, argument: :secret, attribute: :connection_secret}

      description "Creates a run on the tenant's site, started by the actor"
    end

    update :start_dry_run do
      accept []

      validate {TenantContext, require_master: false}
      validate {Status, from: [:pending, :dry_run]}

      change set_attribute(:status, :dry_running)
      change {EnqueueJob, worker: DryRunWorker}

      description "Queues a dry run: what an import would create, update and skip, writing nothing"
    end

    update :start_import do
      accept []

      validate {TenantContext, require_master: false}
      validate {Status, from: [:dry_run]}

      change set_attribute(:status, :importing)
      change {EnqueueJob, worker: ImportWorker}

      description "Queues the import of a run whose dry run has reported"
    end

    update :finish_dry_run do
      accept [:report]

      validate {Status, from: [:dry_running]}

      change set_attribute(:status, :dry_run)

      description "System-internal: saves the dry run's report"
    end

    update :finish_import do
      accept [:report]

      validate {Status, from: [:importing]}

      change set_attribute(:status, :done)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change set_attribute(:connection_secret, nil)

      description "System-internal: saves the import's report"
    end

    update :fail do
      accept [:error]

      validate {Status, from: [:dry_running, :importing]}

      change set_attribute(:status, :failed)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change set_attribute(:connection_secret, nil)

      description "System-internal: saves why a dry run or an import could not go on"
    end
  end

  policies do
    policy action([:finish_dry_run, :finish_import, :fail]) do
      forbid_if always()
    end

    policy action_type([:read, :create, :update]) do
      access_type :strict

      authorize_if {AccessPermissions,
                    permissions: ["admin:dashboard:migration", "admin:api:migration"]}
    end

    policy action_type([:read, :create, :update]) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(site_id == ^actor(:site_id))
    end
  end

  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "migration_run"

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

      description "The source's secret, sealed (MishkaCmsMigration.Secret); cleared once the run ends"
    end

    attribute :options, :map do
      allow_nil? false
      public? true
      default %{}
      description "What the admin chose for this run (MishkaCmsMigration.Options)"
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

    attribute :error, :string do
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
end
