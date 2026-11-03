# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.MigrationItem do
  @moduledoc """
  What the migration remembers about one item of a source on a site: the CMS record it wrote
  (`target_resource`, `target_id`), when that record last changed as the migration left it
  (`target_updated_at`), what the source said about the item then (`title`, `source_modified_at`,
  `content_hash`, and the fields the CMS has no home for, `extra`), and what the last run that met
  it did (`outcome`, `reason`, `run_id`). The item's content and its other fields, such as a post's
  slug, status and author, are not kept: every run reads them from the source again.

  An item is one per site, source host, kind and source id (`:unique_source_item`). That is what
  makes running again safe: a second run finds the record the first one wrote and updates it, leaves
  it when the source has not changed it, and never overwrites one an admin changed in the CMS since
  (`MishkaCmsMigration.Workers.Helpers.Decision`).

  The source host is part of it so several sources can move into one site: two hosts' items never
  meet, the same id on both is two items, and re-running one host touches only its own. When two
  sources ask the CMS for the same thing (the same address, say), the target's action refuses the
  second and that item is recorded as failed with the CMS's reason; the first is never
  overwritten.

  Written by the import job alone, which AshOban's context lets through where every actor is refused
  (`AshOban.Checks.AshObanInteraction`), as upserts on that identity: `:record` after its CMS record
  was written, `:record_outcome` after an item was skipped or failed, which keeps what the last
  write recorded. Read by whoever may read the site's runs (`MishkaCmsMigration.MigrationRun`).

  ## In the admin

  The Items page (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Index`), reached from a run's
  row, lists as a Gervaz table every item of the run's source host on the run's site, whichever
  run met it last; its "Only this run's" filter narrows them to the ones this run met last. Each row
  shows the item's kind (`MishkaCmsMigration.MigrationRun.kind_label/1`), title and source id, what
  the last run did with it as an outcome pill with its reason in words
  (`MishkaCmsMigration.MigrationRun.reason_label/1`) and when the last run met it. It filters by
  kind and outcome, searches the title and the source id, and keeps them in the address under
  `items`. A row expands to what is kept of the item, as JSON.
  """

  use Ash.Resource,
    otp_app: :mishka_cms_migration,
    domain: MishkaCmsMigration,
    data_layer: AshPostgres.DataLayer,
    extensions: [GuardedStruct.AshResource, MishkaGervaz.Resource],
    authorizers: [Ash.Policy.Authorizer]

  use Gettext, backend: MishkaCmsCore.Gettext

  import Phoenix.Component, only: [sigil_H: 2]

  require Ash.Query

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.Resources.Validations.TenantContext
  alias MishkaCmsMigration.MigrationRun

  @outcomes MishkaCmsMigration.Report.outcomes()
  @source [:source_host, :source_kind, :source_id]
  @written [
    :run_id,
    :title,
    :source_modified_at,
    :content_hash,
    :target_resource,
    :target_id,
    :target_updated_at,
    :outcome,
    :reason,
    :extra
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

    field :title, :string,
      derives: "sanitize(trim, no_control) validate(optional=[string, max_len=1000])"

    field :reason, :string,
      derives: "sanitize(trim, no_control) validate(optional=[string, max_len=2000])"

    field :extra, :map, derives: "validate(optional=[map])"
  end

  mishka_gervaz do
    table do
      identity do
        name :migration_items
        route "/admin/dashboard/migration/runs/:run/items"
        stream_name :migration_items
      end

      columns do
        default_sort updated_at: :desc, id: :asc

        column :source_kind do
          label fn -> dgettext("mishka_gervaz", "Kind") end
          sortable true

          ui do
            width "minmax(120px,0.8fr)"
          end

          render fn kind ->
            assigns = %{
              kind: kind,
              label: MigrationRun.kind_label(kind),
              icon: MigrationRun.kind_icon(kind)
            }

            ~H"""
            <span data-role="item-kind" data-kind={@kind} class="inline-flex items-center gap-[9px]">
              <span class="grid size-[30px] flex-none place-items-center rounded-[9px] bg-[#eeedfb] text-[#5b57d6]">
                <MishkaCmsCore.CoreComponents.icon name={@icon} class="size-[15px]" />
              </span>
              <span class="text-[12.5px] font-semibold text-[#3a382f]">{@label}</span>
            </span>
            """
          end
        end

        column :title do
          label fn -> dgettext("mishka_gervaz", "Title") end
          sortable true

          ui do
            width "minmax(160px,1.6fr)"
          end

          render fn title ->
            assigns = %{title: title}

            ~H"""
            <div
              data-role="item-title"
              title={@title}
              class="min-w-0 truncate text-[13px] font-semibold text-[#17161a]"
            >
              {@title || dgettext("mishka_gervaz", "Untitled")}
            </div>
            """
          end
        end

        column :source_id do
          label fn -> dgettext("mishka_gervaz", "Source ID") end

          ui do
            width "minmax(84px,0.5fr)"
          end

          render fn source_id ->
            assigns = %{source_id: source_id}

            ~H"""
            <span
              data-role="item-source-id"
              class="font-['Space_Grotesk'] text-[12px] font-medium text-[#7c7a75]"
            >
              {"#" <> @source_id}
            </span>
            """
          end
        end

        column :result do
          static true
          requires [:outcome, :reason]
          label fn -> dgettext("mishka_gervaz", "Outcome") end

          ui do
            width "minmax(160px,1.6fr)"
          end

          render fn item ->
            assigns = %{
              outcome: item.outcome,
              word: MigrationRun.outcome_word(item.outcome),
              class: MigrationRun.outcome_class(item.outcome),
              icon: MigrationRun.outcome_icon(item.outcome),
              reason: item.reason && MigrationRun.reason_label(item.reason)
            }

            ~H"""
            <div class="min-w-0">
              <span
                data-role="item-outcome"
                data-outcome={@outcome}
                class={[
                  "inline-flex w-fit items-center gap-[5px] rounded-[20px] px-[10px] py-[3px] text-[10px] font-bold whitespace-nowrap",
                  @class
                ]}
              >
                <MishkaCmsCore.CoreComponents.icon name={@icon} class="size-[10px]" />{@word}
              </span>
              <div
                :if={@reason}
                data-role="item-reason"
                class="mt-[4px] text-[11px] font-medium text-[#a8a5a0]"
              >
                {@reason}
              </div>
            </div>
            """
          end
        end

        column :last_run do
          static true
          requires [:updated_at]
          label fn -> dgettext("mishka_gervaz", "Last run") end
          sortable true
          sort_field [:updated_at]

          ui do
            width "minmax(116px,0.7fr)"
          end

          render fn item ->
            assigns = %{
              date: MishkaCmsCore.Localized.date(item.updated_at, :yMMMd),
              time: MishkaCmsCore.Localized.time(item.updated_at, :Hm)
            }

            ~H"""
            <div class="min-w-0">
              <div class="text-[12.5px] font-semibold text-[#3a382f]">{@date}</div>
              <div class="mt-[2px] text-[11px] font-medium text-[#a8a5a0]">{@time}</div>
            </div>
            """
          end
        end
      end

      filters do
        filter :search, :text do
          fields [:title, :source_id]

          ui do
            label fn -> dgettext("mishka_gervaz", "Search") end
            placeholder fn -> dgettext("mishka_gervaz", "Search titles...") end
          end
        end

        filter :source_kind, :select do
          options fn -> MigrationRun.kind_options() end

          ui do
            prompt dgettext_noop("mishka_gervaz", "Any kind")
            label fn -> dgettext("mishka_gervaz", "Kind") end
          end
        end

        filter :outcome, :select do
          options fn -> MigrationRun.outcome_options() end

          ui do
            prompt dgettext_noop("mishka_gervaz", "Any outcome")
            label fn -> dgettext("mishka_gervaz", "Outcome") end
          end
        end

        filter :this_run, :boolean do
          virtual true

          apply fn
            query, true, %{path_params: %{run: id}} -> Ash.Query.filter(query, run_id == ^id)
            query, _value, _assigns -> query
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Only this run's") end
          end
        end
      end

      row_actions do
        action :expand, type: :accordion
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page]
        prefix "items"
        max_filter_length 500
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No items found"),
                  icon: "hero-list-bullet"
    end
  end

  actions do
    read :read do
      description "A site's items"
      primary? true

      pagination offset?: true,
                 keyset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false
    end

    read :master_read do
      description "Every site's items (masters)"
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
      description "One item of any site (masters)"
      multitenancy :bypass
      get? true

      validate {TenantContext, require_master: true}
    end

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

      description "System-internal: an item whose CMS record a run wrote"
    end

    create :record_outcome do
      accept @source ++ [:run_id, :title, :outcome, :reason]
      upsert? true
      upsert_identity :unique_source_item
      upsert_fields [:run_id, :title, :outcome, :reason, :updated_at]

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)

      description "System-internal: an item a run skipped or failed, keeping what was last written"
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

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

    attribute :title, :string do
      allow_nil? true
      public? true
      constraints max_length: 1000
      description "What the source calls the item (Source.Item's title), as of the last write"
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
      description "The CMS record the item was written to"
    end

    attribute :target_updated_at, :utc_datetime_usec do
      allow_nil? true
      public? true

      description "The CMS record's updated_at as the last write left it; any other value is an edit in the CMS"
    end

    attribute :outcome, :atom do
      allow_nil? false
      public? true
      constraints one_of: @outcomes
      description "What the last run that met the item did with it"
    end

    attribute :extra, :map do
      allow_nil? false
      public? true
      default %{}

      description "The source's fields the CMS has no home for, as of the last write (Source.Item's extra)"
    end

    attribute :reason, :string do
      allow_nil? true
      public? true
      constraints max_length: 2000
      description "Why the item was skipped or failed, or what its write left unconverted"
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
