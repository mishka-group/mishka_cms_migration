# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.MigrationLog do
  @moduledoc """
  One entry of a run's log: a step of its life (`step`), who took it (`user_id`, none for a job
  that failed on its own or that Oban discarded), and what it said: the host the run reads from,
  a finished step's counts and a failed step's reason. Nothing else of the run is kept, so an entry
  never holds its connection or its secret.

  The steps are the run's own (`MishkaCmsMigration.Resources.Notifiers.Steps`): `:connected` when
  the run is created, `:dry_run_started`, `:dry_run_finished`, `:dry_run_failed`,
  `:dry_run_cancelled`, the same five words for an import, and `:cancelled` for a run cancelled
  while it waited. Written by that notifier alone, once each step is saved, as the system
  (`authorize?: false`); every actor is refused `:record`.

  Read by whoever may read the site's runs (`MishkaCmsMigration.MigrationRun`): a master reads every
  site's entries, a site admin only their own site's. Each entry is broadcast on
  `"migration_log:<site_id>:created"` and `"migration_log:created"`, which the Migration page's
  Logs follow (`MishkaCmsMigration.Activity`).
  """

  use Ash.Resource,
    otp_app: :mishka_cms_migration,
    domain: MishkaCmsMigration,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub],
    authorizers: [Ash.Policy.Authorizer]

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions

  @steps [
    :connected,
    :dry_run_started,
    :dry_run_finished,
    :dry_run_failed,
    :dry_run_cancelled,
    :import_started,
    :import_finished,
    :import_failed,
    :import_cancelled,
    :cancelled
  ]

  @counts Enum.map(
            MishkaCmsMigration.Report.outcomes(),
            &{&1, [type: :integer, allow_nil?: false]}
          )

  postgres do
    table "mishka_cms_migration_logs"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
      reference :run, on_delete: :delete
      reference :user, on_delete: :nilify
    end

    custom_indexes do
      index [:site_id, :inserted_at], name: "mishka_cms_migration_logs_site_feed_index"
      index [:inserted_at], all_tenants?: true
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:step, :source_host, :counts, :reason, :run_id, :user_id]

      description "System-internal: one step of a run, once it is saved"
    end
  end

  policies do
    policy action_type(:create) do
      forbid_if always()
    end

    policy action_type(:read) do
      access_type :strict

      authorize_if {AccessPermissions,
                    permissions: ["admin:dashboard:migration", "admin:api:migration"]}
    end

    policy action_type(:read) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(site_id == ^actor(:site_id))
    end
  end

  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "migration_log"

    publish :record, [[nil, :site_id], "created"]
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    attribute :step, :atom do
      allow_nil? false
      public? true
      constraints one_of: @steps
      description "The step of the run's life the entry tells of"
    end

    attribute :source_host, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
      description "The host the run reads from (the run's source_host)"
    end

    attribute :counts, :map do
      allow_nil? true
      public? true
      constraints fields: @counts
      description "What a finished dry run or import counted (its report's counts)"
    end

    attribute :reason, :string do
      allow_nil? true
      public? true
      constraints max_length: 2000
      description "Why a dry run or an import failed (the run's reason)"
    end

    create_timestamp :inserted_at, public?: true
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site of the run"
    end

    belongs_to :run, MishkaCmsMigration.MigrationRun do
      allow_nil? false
      attribute_writable? true
      public? true
      description "The run the step belongs to"
    end

    belongs_to :user, MishkaCmsCore.Accounts.User do
      domain MishkaCmsCore.Accounts
      read_action :related
      sortable? false
      allow_nil? true
      attribute_writable? true
      public? true
      description "Who took the step; none for a job that failed on its own"
    end
  end

  @doc "Every step an entry may tell of, in the order a run goes through them."
  @spec steps() :: [atom()]
  def steps, do: @steps
end
