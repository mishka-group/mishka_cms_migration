# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.MigrationItem do
  @moduledoc """
  What the migration remembers about one item of a source on a site: the CMS row it wrote
  (`target_resource`, `target_id`), when that row last changed as the migration left it
  (`target_updated_at`), what the source said about the item then (`source_modified_at`,
  `content_hash`), and what the last run that met it did (`outcome`, `reason`, `run_id`).

  An item is one per site, source host, kind and source id (`:unique_source_item`). That is what
  makes running again safe: a second run finds the row the first one wrote and updates it, leaves
  it when the source has not changed it, and never overwrites one an admin changed in the CMS since
  (`MishkaCmsMigration.Workers.Helpers.Decision`).

  Written by the import job alone (`authorize?: false`), as upserts on that identity: `:record`
  after a row was written, `:record_outcome` after an item was skipped or failed, which keeps what
  the last write recorded. Read by whoever may read the site's runs
  (`MishkaCmsMigration.MigrationRun`).
  """

  use Ash.Resource,
    otp_app: :mishka_cms_migration,
    domain: MishkaCmsMigration,
    data_layer: AshPostgres.DataLayer,
    extensions: [GuardedStruct.AshResource],
    authorizers: [Ash.Policy.Authorizer]

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions

  @outcomes MishkaCmsMigration.Report.outcomes()
  @source [:source_host, :source_kind, :source_id]
  @written [
    :run_id,
    :source_modified_at,
    :content_hash,
    :target_resource,
    :target_id,
    :target_updated_at,
    :outcome,
    :reason
  ]

  postgres do
    table "mishka_cms_migration_items"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
      reference :run, on_delete: :nilify
    end

    custom_indexes do
      index [:run_id]
    end
  end

  guardedstruct do
    auto_wire true

    field :source_kind, :string, derives: "sanitize(trim) validate(string, not_empty, max_len=64)"
    field :source_id, :string, derives: "sanitize(trim) validate(string, not_empty, max_len=255)"

    field :reason, :string,
      derives: "sanitize(trim, no_control) validate(optional=[string, max_len=2000])"
  end

  actions do
    defaults [:read]

    read :by_sources do
      argument :source_host, :string, allow_nil?: false
      argument :source_kind, :string, allow_nil?: false
      argument :source_ids, {:array, :string}, allow_nil?: false

      filter expr(
               source_host == ^arg(:source_host) and source_kind == ^arg(:source_kind) and
                 source_id in ^arg(:source_ids)
             )

      description "The items of a source host and kind with any of the given source ids"
    end

    create :record do
      accept @source ++ @written
      upsert? true
      upsert_identity :unique_source_item
      upsert_fields @written ++ [:updated_at]

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)

      description "System-internal: an item whose CMS row a run wrote"
    end

    create :record_outcome do
      accept @source ++ [:run_id, :outcome, :reason]
      upsert? true
      upsert_identity :unique_source_item
      upsert_fields [:run_id, :outcome, :reason, :updated_at]

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)

      description "System-internal: an item a run skipped or failed, keeping what was last written"
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

  multitenancy do
    strategy :attribute
    attribute :site_id
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :source_host, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
      description "The host the item was read from (the run's source_host)"
    end

    attribute :source_kind, :string do
      allow_nil? false
      public? true
      constraints max_length: 64
      description "What the item is on the source, such as post or user"
    end

    attribute :source_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
      description "The item's id on the source"
    end

    attribute :source_modified_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When the source last changed the item, as of the last write"
    end

    attribute :content_hash, :string do
      allow_nil? true
      public? true
      description "MishkaCmsMigration.Source.Item.hash/1 of the item, as of the last write"
    end

    attribute :target_resource, :string do
      allow_nil? true
      public? true
      description "The CMS resource the item was written to"
    end

    attribute :target_id, :uuid do
      allow_nil? true
      public? true
      description "The CMS row the item was written to"
    end

    attribute :target_updated_at, :utc_datetime_usec do
      allow_nil? true
      public? true

      description "The row's updated_at as the last write left it; any other value is an edit in the CMS"
    end

    attribute :outcome, :atom do
      allow_nil? false
      public? true
      constraints one_of: @outcomes
      description "What the last run that met the item did with it"
    end

    attribute :reason, :string do
      allow_nil? true
      public? true
      constraints max_length: 2000
      description "Why the item was skipped or failed"
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site the item was moved into"
    end

    belongs_to :run, MishkaCmsMigration.MigrationRun do
      allow_nil? true
      attribute_writable? true
      public? true
      description "The last run that met the item"
    end
  end

  identities do
    identity :unique_source_item, [:site_id, :source_host, :source_kind, :source_id] do
      description "One item per source host, kind and id on a site"
      all_tenants? true
      nils_distinct? false
    end
  end
end
