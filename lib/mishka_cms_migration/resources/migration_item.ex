# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.MigrationItem do
  @moduledoc """
  What the migration remembers about one item of a source on a site: what the last dry run would
  do with it (`plan`, `plan_reason`), the CMS record the last import wrote (`target_resource`,
  `target_id`), when that record last changed as the import left it (`target_updated_at`), what the
  source said about the item then (`title`, `source_slug`, `source_modified_at`, `content_hash`, and
  the fields the CMS has no home for, `extra`), and what the last import that met it did
  (`outcome`, `reason`, `run_id`). `outcome` is `nil` for an item no import has met yet, so a run's
  counts (`MishkaCmsMigration.MigrationRun`'s `created_count` and the rest) count what its import
  did alone. The item's content and its other fields, such as a post's status and author, are not
  kept: every run reads them from the source again.

  An item is one per site, source host, kind and source id (`:unique_source_item`). That is what
  makes running again safe: a second run finds the record the first one wrote and updates it, leaves
  it when the source has not changed it, and never overwrites one an admin changed in the CMS since
  (`MishkaCmsMigration.Workers.Helpers.Decision`).

  The source host is part of it so several sources can move into one site: two hosts' items never
  meet, the same id on both is two items, and re-running one host touches only its own. When two
  sources ask the CMS for the same thing (the same address, say), the target's action refuses the
  second and that item is recorded as failed with the CMS's reason; the first is never
  overwritten.

  Written by the jobs alone, which AshOban's context lets through where every actor is refused
  (`AshOban.Checks.AshObanInteraction`), as upserts on that identity: a dry run's `:record_plan`
  for every item it meets, which sets its title and plan and nothing an import recorded; an
  import's `:record` after its CMS record was written, and `:record_outcome` after an item was
  skipped or failed, which keeps what the last write recorded. No import write touches the plan,
  so an item shows what the last dry run would do beside what the last import did, and none of them
  touches an admin's choices (below). Read by whoever may read the site's runs
  (`MishkaCmsMigration.MigrationRun`).

  ## An admin's choices

  Before an import, an admin decides what it brings, item by item. `:leave_out` sets `left_out`:
  every later dry run and import skips the item as `"left_out_by_admin"`, whatever the source
  changed, and leaves the CMS record an earlier import wrote for it as it is, never deleting it.
  `:bring_back` clears it, so the next run plans the item again. Each makes that one change.

  `:choose` with a `mapped_id` sets it to a record of the CMS resource the item's kind is written
  to, on its site (`MishkaCmsMigration.Resources.Validations.MappedRecord`), and brings the item
  back: every later run connects the item to that record and never writes it, whatever the source
  changed, what an earlier import wrote and what the target would find by its slug; what sits
  under it in the source goes under that record. Two of the source's terms are merged by mapping both to one
  record, which the admin makes first. A record deleted since leaves the item skipped as
  `"mapped_missing"`. `nil` imports the item as its own again, and an item an import connected
  through its mapping forgets that record (`unmapped/2`). A mapping made after an import does not
  link again the posts that import wrote and the source has not changed since.

  An item the import cannot place safely on its own, such as a setting the site already has a
  value of its own for, waits for a decision: a dry run plans it, and an import records it, as
  `:undecided`, with the conflict as the reason (`MishkaCmsMigration.Report`), and writes nothing
  for it. `:choose` with a `decision` answers that conflict (`conflict/1`) with one of the choices
  it offers (`choices/1`): `"keep"`, the site stays as it is (its own is kept, the item is
  connected to the record the site has, or it waits); `"import"`, the item is written the import's
  way; or `"leave_out"`, where the conflict offers it. The answer is kept in `decisions`, by
  conflict, brings the item back, and holds for every later dry run and import, whose target reads
  it (`MishkaCmsMigration.Target.decision/3`). Once an import has written the item by it, or
  connected it to the site's record, the decision took effect (`settled?/1`) and stays: `:choose`
  refuses another, in words, and the item keeps the record it has. `:decide_keep` and
  `:decide_import` give the same answer for the rows an admin picks, and leave the rows whose
  conflict does not offer it, or whose decision took effect, as they are.

  The master actions (`:master_leave_out`, `:master_bring_back`, `:master_choose`,
  `:master_decide_keep`, `:master_decide_import`) do the same on any site.

  A left-out item takes what hangs on it along (`MishkaCmsMigration.Workers.Helpers.Pipeline`): the
  items under it in the source, such as a category's categories, a page's pages and a comment's
  replies, are skipped as `"parent_left_out"`; a post is written without a left-out category, tag
  or author; a left-out post's redirect and comments are skipped as `"post_missing"`; and the links
  other posts have to it keep their old address, found by its `source_slug`
  (`:left_out_by_slugs`).

  A choice takes the same permission and the same site as reading the items, and is refused while
  one of the site's runs is dry running or importing
  (`MishkaCmsMigration.Resources.Validations.SiteIdle`). Each one is broadcast on
  `"migration_item:<site_id>:updated"`, for the Items table to draw the item again; what the jobs
  record is never broadcast.

  ## In the admin

  The Items page (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Index`), reached from a run's
  row, lists as a Gervaz table every item of the run's source host on the run's site, whichever
  run met it last; its "Imported by this run" filter narrows them to the ones this run's import met
  last. Each row shows the item's kind (`MishkaCmsMigration.MigrationRun.kind_label/1`), its title
  with its source id under it, its Plan (`plan_cell/1`): what the last dry run would do with it, as
  a pill with its reason in words (`MishkaCmsMigration.MigrationRun.reason_label/1`), its Last
  import (`last_import_cell/1`): what the last import did with it, the same way, or Not imported,
  links to its CMS record (`record_paths`, below) and when a run or a choice last changed it. It
  filters by kind, plan and last import, searches the title and the source id, and keeps them and
  the view it shows in the address under `items`. A row expands to what is kept of the item, as
  JSON.

  A row's Leave out or Bring back makes that choice (Gervaz's `:update` row actions), and so do the
  bulk actions of the same names (Gervaz's `:update` bulk actions) for the rows picked with the
  checkboxes, Leave out once the admin confirms; picking every row picks what the table's filters
  find, of the run's site and source host alone. A flash says how many they changed
  (`chosen/2`). A category's or a tag's Map to… (Gervaz's `:edit` row action, which shows the
  page's modal first) opens this resource's Gervaz form on the item, one `mapped_id` field whose
  choices are the site's records of that kind in the language it leads with, and Import as its own
  (`map_options/1`). An item with a conflict has Decide… instead, which opens the same form with
  one `decision` field, the conflict's choices in words (`decision_options/1`); the Plan filter's
  Needs your decision lists them all, and Keep the site as it is and Import anyway decide the
  picked rows together. The Plan cell shows the choice before the plan, and the record a mapped
  item is connected to (`mapped_paths`). The table's other view, Map, draws the items as the source
  nests them (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Tree`), from the rows it keeps
  loaded.

  `record_paths` is a calculation: where the item's CMS record is in the admin and on the site
  (`MishkaCmsMigration.MigrationRun.record_paths/2`), with its name, `nil` for an item with no
  record or whose record is gone; `mapped_paths` is the same for the record an admin mapped it to.
  Each reads the records of a page together, as the reader.
  """

  use Ash.Resource,
    otp_app: :mishka_cms_migration,
    domain: MishkaCmsMigration,
    data_layer: AshPostgres.DataLayer,
    extensions: [GuardedStruct.AshResource, MishkaGervaz.Resource],
    notifiers: [Ash.Notifier.PubSub],
    authorizers: [Ash.Policy.Authorizer]

  use Gettext, backend: MishkaCmsCore.Gettext

  import Phoenix.Component, only: [sigil_H: 2]

  require Ash.Query

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.Resources.Validations.TenantContext
  alias MishkaCmsMigration.{MigrationRun, Target}
  alias MishkaCmsMigration.Resources.Calculations.RecordPaths
  alias MishkaCmsMigration.Resources.Changes.Decided
  alias MishkaCmsMigration.Resources.Validations.{MappedRecord, SiteIdle}
  alias MishkaCmsMigration.Targets.Helpers.Read
  alias MishkaGervaz.Table.Web.Events.{BulkActionHooks, BulkActionResult}

  @outcomes MishkaCmsMigration.Report.outcomes()
  @mappable ["category", "tag"]
  @choices %{
    "site_has_own" => ["keep", "import"],
    "header_has_links" => ["keep", "import"],
    "slug_taken" => ["keep", "import"],
    "blog_missing" => ["keep", "leave_out"],
    "player_not_allowed" => ["keep", "import"],
    "draft_pages" => ["keep", "import"]
  }
  @bulk_choices %{decide_keep: "keep", decide_import: "import"}
  @map_modal "migration-item-map-modal"
  @source [:source_host, :source_kind, :source_id]
  @written [
    :run_id,
    :title,
    :source_slug,
    :source_parent,
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

    field :source_slug, :string,
      derives: "sanitize(trim, no_control) validate(optional=[string, max_len=1000])"

    field :source_parent, :string,
      derives: "sanitize(trim) validate(optional=[string, max_len=255])"

    field :reason, :string,
      derives: "sanitize(trim, no_control) validate(optional=[string, max_len=2000])"

    field :plan_reason, :string,
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

      source do
        preload do
          always [:record_paths, :mapped_paths]
        end
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
          static true
          requires [:title, :source_id]
          label fn -> dgettext("mishka_gervaz", "Title") end
          sortable true
          sort_field [:title]

          ui do
            width "minmax(160px,1.6fr)"
          end

          render fn item ->
            assigns = %{title: item.title, source_id: item.source_id}

            ~H"""
            <div class="min-w-0">
              <div
                data-role="item-title"
                title={@title}
                class="truncate text-[13px] font-semibold text-[#17161a]"
              >
                {@title || dgettext("mishka_gervaz", "Untitled")}
              </div>
              <div
                data-role="item-source-id"
                class="mt-[2px] font-['Space_Grotesk'] text-[11px] font-medium text-[#a8a5a0]"
              >
                {"#" <> @source_id}
              </div>
            </div>
            """
          end
        end

        column :planned do
          static true

          requires [
            :plan,
            :plan_reason,
            :outcome,
            :reason,
            :left_out,
            :mapped_id,
            :mapped_paths,
            :decisions
          ]

          label fn -> dgettext("mishka_gervaz", "Plan") end

          ui do
            width "minmax(150px,1.3fr)"
          end

          render fn item -> MishkaCmsMigration.MigrationItem.plan_cell(item) end
        end

        column :result do
          static true
          requires [:outcome, :reason]
          label fn -> dgettext("mishka_gervaz", "Last import") end

          ui do
            width "minmax(150px,1.3fr)"
          end

          render fn item -> MishkaCmsMigration.MigrationItem.last_import_cell(item) end
        end

        column :record do
          static true
          requires [:target_id, :record_paths]
          label fn -> dgettext("mishka_gervaz", "CMS record") end

          ui do
            width "minmax(96px,0.6fr)"
          end

          render fn item ->
            assigns = %{paths: item.record_paths}

            ~H"""
            <MigrationRun.record_links paths={@paths} />
            <span :if={!@paths} class="text-[12px] text-[#bcb9b2]">—</span>
            """
          end
        end

        column :last_run do
          static true
          requires [:updated_at]
          label fn -> dgettext("mishka_gervaz", "Updated") end
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

        filter :plan, :select do
          options fn -> MishkaCmsMigration.MigrationItem.plan_options() end

          ui do
            prompt dgettext_noop("mishka_gervaz", "Any plan")
            label fn -> dgettext("mishka_gervaz", "Plan") end
          end
        end

        filter :outcome, :select do
          options fn -> MigrationRun.outcome_options() end

          ui do
            prompt dgettext_noop("mishka_gervaz", "Any outcome")
            label fn -> dgettext("mishka_gervaz", "Last import") end
          end
        end

        filter :this_run, :boolean do
          virtual true

          apply fn
            query, true, %{path_params: %{run: id}} -> Ash.Query.filter(query, run_id == ^id)
            query, _value, _assigns -> query
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Imported by this run") end
          end
        end
      end

      presentation do
        template MishkaGervaz.Table.Templates.Table

        switchable_templates [
          MishkaGervaz.Table.Templates.Table,
          MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Tree
        ]

        keep_loaded_records true
      end

      row do
        selectable true
      end

      row_actions do
        actions_layout do
          width "minmax(96px,max-content)"
        end

        action :expand, type: :accordion

        action :map_to do
          type :edit
          js fn _item -> MishkaCmsCore.CoreComponents.show_modal(@map_modal) end

          visible fn item, _state ->
            MishkaCmsMigration.MigrationItem.mappable?(item) and
              is_nil(MishkaCmsMigration.MigrationItem.conflict(item))
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Map to…") end
            icon "hero-link"
          end
        end

        action :decide do
          type :edit
          js fn _item -> MishkaCmsCore.CoreComponents.show_modal(@map_modal) end
          visible fn item, _state -> MishkaCmsMigration.MigrationItem.conflict(item) != nil end

          ui do
            label fn -> dgettext("mishka_gervaz", "Decide…") end
            icon "hero-hand-raised"
          end
        end

        action :leave_out do
          type :update
          action {:master_leave_out, :leave_out}
          visible fn item, _state -> not item.left_out end

          ui do
            label fn -> dgettext("mishka_gervaz", "Leave out") end
            icon "hero-eye-slash"
          end
        end

        action :bring_back do
          type :update
          action {:master_bring_back, :bring_back}
          visible fn item, _state -> item.left_out end

          ui do
            label fn -> dgettext("mishka_gervaz", "Bring back") end
            icon "hero-arrow-uturn-left"
          end
        end
      end

      bulk_actions do
        action :leave_out do
          type :update
          action {:master_leave_out, :leave_out}

          confirm dgettext_noop(
                    "mishka_gervaz",
                    "Leave out {count} items? Import will not write them."
                  )

          ui do
            label fn -> dgettext("mishka_gervaz", "Leave out") end
            icon "hero-eye-slash"
          end
        end

        action :bring_back do
          type :update
          action {:master_bring_back, :bring_back}

          ui do
            label fn -> dgettext("mishka_gervaz", "Bring back") end
            icon "hero-arrow-uturn-left"
          end
        end

        action :decide_keep do
          type :update
          action {:master_decide_keep, :decide_keep}

          ui do
            label fn -> dgettext("mishka_gervaz", "Keep the site as it is") end
            icon "hero-shield-check"
          end
        end

        action :decide_import do
          type :update
          action {:master_decide_import, :decide_import}

          confirm dgettext_noop(
                    "mishka_gervaz",
                    "Import {count} items anyway? Each is written the import's way."
                  )

          ui do
            label fn -> dgettext("mishka_gervaz", "Import anyway") end
            icon "hero-arrow-down-tray"
          end
        end
      end

      hooks do
        on_bulk_action_success [:leave_out, :bring_back, :decide_keep, :decide_import],
                               fn summary, _state, socket ->
                                 MishkaCmsMigration.MigrationItem.chosen(summary, socket)
                               end
      end

      realtime do
        prefix "migration_item"

        visible fn item, user ->
          is_nil(user.site_id) or item.site_id == user.site_id
        end
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :template]
        prefix "items"
        max_filter_length 500
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No items found"),
                  icon: "hero-list-bullet"
    end

    form do
      identity do
        name :migration_item_map_form
      end

      source do
        access :create, false

        actions do
          update {:master_choose, :choose}
          read {:master_get, :read}
        end
      end

      fields do
        field :mapped_id, :relation do
          mode :search
          options fn state -> MishkaCmsMigration.MigrationItem.map_options(state) end
          visible fn state -> MishkaCmsMigration.MigrationItem.decision_options(state) == [] end

          ui do
            label fn -> dgettext("mishka_gervaz", "Map to") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Pick a record the site already has, in the language it leads with, and the import links to it and writes nothing; what sits under the item goes under it. Import as its own writes the item as the source has it."
              )
            end
          end
        end

        field :decision, :relation do
          virtual true
          mode :search
          options fn state -> MishkaCmsMigration.MigrationItem.decision_options(state) end
          visible fn state -> MishkaCmsMigration.MigrationItem.decision_options(state) != [] end

          ui do
            label fn -> dgettext("mishka_gervaz", "Your decision") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "The import cannot place this item on its own: the site already has something in its place. What you pick holds for every later dry run and import."
              )
            end
          end
        end
      end

      submit do
        update label: fn -> dgettext("mishka_gervaz", "Save") end
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

    read :left_out_by_slugs do
      argument :source_host, :string, allow_nil?: false
      argument :source_kind, :string, allow_nil?: false
      argument :source_slugs, {:array, :string}, allow_nil?: false

      filter expr(
               left_out and source_host == ^arg(:source_host) and
                 source_kind == ^arg(:source_kind) and source_slug in ^arg(:source_slugs)
             )

      description "The items of a source host and kind an admin left out, with any of the given slugs"
    end

    create :record do
      accept @source ++ @written
      upsert? true
      upsert_identity :unique_source_item
      upsert_fields @written ++ [:updated_at]

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)

      description "System-internal: an item whose CMS record an import wrote"
    end

    create :record_outcome do
      accept @source ++ [:run_id, :title, :source_slug, :source_parent, :outcome, :reason]
      upsert? true
      upsert_identity :unique_source_item

      upsert_fields [
        :run_id,
        :title,
        :source_slug,
        :source_parent,
        :outcome,
        :reason,
        :updated_at
      ]

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)

      description "System-internal: an item an import skipped or failed, keeping what was last written"
    end

    update :leave_out do
      accept []
      require_atomic? false

      validate {TenantContext, require_master: false}
      validate SiteIdle, before_action?: true

      change set_attribute(:left_out, true)

      description "Leaves the item out of every later dry run and import, keeping its CMS record"
    end

    update :master_leave_out do
      accept []
      multitenancy :bypass
      require_atomic? false

      validate {TenantContext, require_master: true}
      validate SiteIdle, before_action?: true

      change set_attribute(:left_out, true)

      description "Leaves an item of any site out of every later dry run and import (masters)"
    end

    update :bring_back do
      accept []
      require_atomic? false

      validate {TenantContext, require_master: false}
      validate SiteIdle, before_action?: true

      change set_attribute(:left_out, false)

      description "Brings a left out item back into the next dry run and import"
    end

    update :master_bring_back do
      accept []
      multitenancy :bypass
      require_atomic? false

      validate {TenantContext, require_master: true}
      validate SiteIdle, before_action?: true

      change set_attribute(:left_out, false)

      description "Brings a left out item of any site back (masters)"
    end

    update :choose do
      accept [:mapped_id]
      require_atomic? false

      argument :decision, :string do
        allow_nil? true
        description "The answer to the conflict the item waits on: keep, import or leave_out"
      end

      validate {TenantContext, require_master: false}
      validate SiteIdle, before_action?: true
      validate MappedRecord, before_action?: true, where: [changing(:mapped_id)]

      change set_attribute(:left_out, false)
      change &MishkaCmsMigration.MigrationItem.unmapped/2
      change Decided

      description "Maps the item to a record the CMS holds or back (nil), or decides its conflict"
    end

    update :master_choose do
      accept [:mapped_id]
      multitenancy :bypass
      require_atomic? false

      argument :decision, :string do
        allow_nil? true
        description "The answer to the conflict the item waits on: keep, import or leave_out"
      end

      validate {TenantContext, require_master: true}
      validate SiteIdle, before_action?: true
      validate MappedRecord, before_action?: true, where: [changing(:mapped_id)]

      change set_attribute(:left_out, false)
      change &MishkaCmsMigration.MigrationItem.unmapped/2
      change Decided

      description "Maps an item of any site, or decides its conflict (masters)"
    end

    update :decide_keep do
      accept []
      require_atomic? false

      validate {TenantContext, require_master: false}
      validate SiteIdle, before_action?: true

      change {Decided, choice: "keep"}

      description "Answers the item's conflict with the site as it is: its own kept, connected, or waiting"
    end

    update :master_decide_keep do
      accept []
      multitenancy :bypass
      require_atomic? false

      validate {TenantContext, require_master: true}
      validate SiteIdle, before_action?: true

      change {Decided, choice: "keep"}

      description "Answers the conflict of an item of any site with the site as it is (masters)"
    end

    update :decide_import do
      accept []
      require_atomic? false

      validate {TenantContext, require_master: false}
      validate SiteIdle, before_action?: true

      change {Decided, choice: "import"}

      description "Answers the item's conflict by writing it the import's way"
    end

    update :master_decide_import do
      accept []
      multitenancy :bypass
      require_atomic? false

      validate {TenantContext, require_master: true}
      validate SiteIdle, before_action?: true

      change {Decided, choice: "import"}

      description "Answers the conflict of an item of any site by writing it the import's way (masters)"
    end

    create :record_plan do
      accept @source ++ [:title, :source_slug, :source_parent, :plan, :plan_reason]
      upsert? true
      upsert_identity :unique_source_item
      upsert_fields [:title, :source_slug, :source_parent, :plan, :plan_reason, :updated_at]

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)

      description "System-internal: what a dry run would do with an item, keeping what imports recorded"
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    policy action_type(:create) do
      forbid_if always()
    end

    policy action_type([:read, :update]) do
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
    prefix "migration_item"

    publish_all :update, [[nil, :site_id], "updated"]
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

    attribute :source_slug, :string do
      allow_nil? true
      public? true
      constraints max_length: 1000

      description "The item's slug at the source (Source.Item's attrs slug), as of the last run that met it"
    end

    attribute :source_parent, :string do
      allow_nil? true
      public? true
      constraints max_length: 255

      description "The source id of the item of its kind it sits under at the source (Source.Item's parent)"
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
      allow_nil? true
      public? true
      constraints one_of: @outcomes
      description "What the last import that met the item did with it; nil before any import did"
    end

    attribute :left_out, :boolean do
      allow_nil? false
      public? true
      default false

      description "Whether an admin left the item out: no dry run or import writes it until brought back"
    end

    attribute :mapped_id, :uuid do
      allow_nil? true
      public? true

      description "The record of the kind's CMS resource an admin mapped the item to, nil to import it as its own"
    end

    attribute :decisions, :map do
      allow_nil? false
      public? true
      default %{}

      description "An admin's answers to the conflicts the import met for the item, by conflict: keep or import"
    end

    attribute :plan, :atom do
      allow_nil? true
      public? true
      constraints one_of: @outcomes
      description "What the last dry run that met the item would do with it"
    end

    attribute :plan_reason, :string do
      allow_nil? true
      public? true
      constraints max_length: 2000

      description "Why the last dry run would skip or fail the item, or what it would write otherwise"
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

      description "Why the last import skipped or failed the item, or what its write left unconverted"
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
      description "The last import that met the item"
    end
  end

  calculations do
    calculate :record_paths, :map, RecordPaths do
      public? true

      description "Where the item's CMS record is in the admin and on the site, nil when it has none"
    end

    calculate :mapped_paths, :map, {RecordPaths, field: :mapped_id} do
      public? true

      description "Where the record an admin mapped the item to is, with its name, nil when none"
    end
  end

  identities do
    identity :unique_source_item, [:site_id, :source_host, :source_kind, :source_id] do
      description "One item per source host, kind and id on a site"
      all_tenants? true
      nils_distinct? false
    end
  end

  @doc """
  The item `id` as `user` may read it: a master's on any site, a site admin's on their own site
  alone. `{:ok, nil}` for an item that is not there or that `user` may not read.
  """
  @spec fetch(String.t(), map()) :: {:ok, struct() | nil} | {:error, term()}
  def fetch(id, %{site_id: nil} = user),
    do: Ash.get(__MODULE__, id, action: :master_get, actor: user, not_found_error?: false)

  def fetch(id, %{site_id: site_id} = user),
    do: Ash.get(__MODULE__, id, actor: user, tenant: site_id, not_found_error?: false)

  @doc """
  Whether `item` has a Map to…: a category or a tag, the kinds whose CMS records an admin may
  pick from (`map_options/1`).
  """
  @spec mappable?(map()) :: boolean()
  def mappable?(%{source_kind: kind}), do: kind in @mappable

  @doc """
  The conflict `item` waits on for an admin's decision, such as `"site_has_own"`: the reason of
  its last dry run's plan when that plan is `:undecided`, else of its last import when that left it
  `:undecided` after a plan to write it, or with no plan, else the conflict an admin decided (the
  first, for an item that met several), so a decision can be changed after a run followed it. A
  reason that names what the conflict is about after `": "`, as `"draft_pages: Team, Leadership"`
  does, is the conflict before it. `nil` for an item that never met one.
  """
  @spec conflict(map()) :: String.t() | nil
  def conflict(item),
    do: code(waits_on(item)) || item.decisions |> Map.keys() |> Enum.min(fn -> nil end)

  @doc """
  Whether the admin's decision on `item` took effect: an import wrote the item by it, or connected
  it to the site's record, so it has a CMS record (`target_id`), and nothing on it waits for a
  decision now. Changing it then could only move a record written as new onto the site's own
  address, or leave one connected unwritten, so it stays (`MishkaCmsMigration.Resources.Changes.Decided`).
  """
  @spec settled?(map()) :: boolean()
  def settled?(%{decisions: decisions, target_id: id, outcome: outcome} = item)
      when decisions != %{} and is_binary(id) and outcome != :undecided,
      do: is_nil(waits_on(item))

  def settled?(_item), do: false

  @doc """
  What an admin may answer `conflict` with: `"keep"` and `"import"`, or `"keep"` and
  `"leave_out"`; none for `nil` or a conflict this extension does not know.
  """
  @spec choices(String.t() | nil) :: [String.t()]
  def choices(conflict), do: Map.get(@choices, conflict, [])

  @doc """
  The Decide… form's choices (`decision`'s `options`): the choices of the conflict the item the
  form has loaded waits on (`conflict/1`), in words, such as Keep the site's own and Use the
  WordPress one. None before the item is loaded, and for an item with no conflict, whose form
  shows Map to… instead.
  """
  @spec decision_options(map()) :: [{String.t(), String.t()}]
  def decision_options(%{form: %Phoenix.HTML.Form{data: %__MODULE__{} = item}}) do
    conflict = conflict(item)
    for choice <- choices(conflict), do: {choice_word(conflict, choice), choice}
  end

  def decision_options(_state), do: []

  @doc """
  The Map to… form's choices (`mapped_id`'s `options`): Import as its own, then the records of the
  item's kind's CMS resource (`MishkaCmsMigration.Target`) on its site, in the language the site
  leads with (`MishkaCmsCore.Runtime.Languages.primary/1`), by name, read as the admin. The kind
  and the site are the item's, the record the form has loaded to update (`state.form.data`); a
  form with no item loaded yet, a kind with no Map to… (`mappable?/1`) or one no target writes has
  Import as its own alone.
  """
  @spec map_options(map()) :: [{String.t(), String.t()}]
  def map_options(%{
        form: %Phoenix.HTML.Form{data: %__MODULE__{source_kind: kind, site_id: site_id}},
        current_user: user
      })
      when kind in @mappable do
    [{dgettext("mishka_gervaz", "Import as its own"), "__nil__"} | records(kind, site_id, user)]
  end

  def map_options(_state), do: [{dgettext("mishka_gervaz", "Import as its own"), "__nil__"}]

  @doc """
  What `:choose` does to the record an item was connected to when its mapping is taken away: an
  item an import connected (it recorded no `target_updated_at`) forgets that record, so the next
  run creates it, or meets it by its slug, as an item never written. An item an import wrote keeps
  its own record.
  """
  @spec unmapped(Ash.Changeset.t(), map()) :: Ash.Changeset.t()
  def unmapped(%{data: %{mapped_id: was, target_updated_at: nil}} = changeset, _context)
      when is_binary(was) do
    case Ash.Changeset.get_attribute(changeset, :mapped_id) do
      nil -> Ash.Changeset.force_change_attributes(changeset, target_id: nil, content_hash: nil)
      _mapped -> changeset
    end
  end

  def unmapped(changeset, _context), do: changeset

  @doc """
  What the Items table says after its bulk Leave out, Bring back, Keep the site as it is or Import
  anyway changed the rows `summary` names (Gervaz's
  `MishkaGervaz.Table.Web.Events.BulkActionResult`): how many items it left out, brought back or
  decided, in a flash, and for a decision how many it left as they were, having no conflict that
  choice answers.
  """
  @spec chosen(BulkActionResult.t(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def chosen(%BulkActionResult{action_name: action, succeeded_records: records}, socket)
      when is_map_key(@bulk_choices, action) do
    choice = Map.fetch!(@bulk_choices, action)
    decided = Enum.count(records, &(Map.get(&1.decisions, conflict(&1)) == choice))
    BulkActionHooks.put_flash(socket, :info, decided_words(decided, length(records) - decided))
  end

  def chosen(%BulkActionResult{action_name: action, succeeded_count: count}, socket),
    do: BulkActionHooks.put_flash(socket, :info, chosen_words(action, count))

  @doc """
  The Items table's Plan cell for `item`: what the last dry run would do with it, as a pill
  (`data-role="item-plan"`, its `data-plan` the plan, or `connected` for an item the dry run
  connected to a record the CMS already held), the reason in words under it
  (`data-role="item-plan-reason"`, `MishkaCmsMigration.MigrationRun.reason_label/1`). A dash before
  the item's first dry run. An admin's choice is shown before the plan: Left out by you
  (`left_out`) for an item left out, Brought back for one brought back since the last dry run
  left it out, and Decided (`data-plan="decided"`), with the choice in words, for an item whose
  conflict an admin decided since the last run that met it. An item that waits for a decision reads
  Needs your decision, with the conflict in words, also when only its last import met it.
  """
  @spec plan_cell(map()) :: Phoenix.LiveView.Rendered.t()
  def plan_cell(item),
    do:
      item
      |> planned()
      |> Map.merge(%{role: "item-plan", reason_role: "item-plan-reason"})
      |> pill()

  @doc """
  The Items table's Last import cell for `item`: what the last import did with it, as a pill
  (`data-role="item-outcome"`, its `data-outcome` the outcome), the reason in words under it
  (`data-role="item-reason"`), or Not imported (an empty `data-outcome`) for an item no import has
  met.
  """
  @spec last_import_cell(map()) :: Phoenix.LiveView.Rendered.t()
  def last_import_cell(item),
    do:
      item.outcome
      |> imported(item.reason)
      |> Map.merge(%{role: "item-outcome", reason_role: "item-reason"})
      |> pill()

  @doc "Every plan as a `{words, plan}` pair, in the order the report counts outcomes."
  @spec plan_options() :: [{String.t(), atom()}]
  def plan_options, do: Enum.map(@outcomes, &{plan_word(&1), &1})

  defp pill(assigns) do
    ~H"""
    <div class="min-w-0">
      <span
        data-role={@role}
        data-plan={@role == "item-plan" && @key}
        data-outcome={@role == "item-outcome" && @key}
        class={[
          "inline-flex w-fit items-center gap-[5px] rounded-[20px] px-[10px] py-[3px] text-[10px] font-bold whitespace-nowrap",
          @class
        ]}
      >
        <MishkaCmsCore.CoreComponents.icon :if={@icon} name={@icon} class="size-[10px]" />{@word}
      </span>
      <div
        :if={@reason}
        data-role={@reason_role}
        class="mt-[4px] text-[11px] font-medium text-[#a8a5a0]"
      >
        {@reason}
      </div>
    </div>
    """
  end

  defp chosen_words(:leave_out, count),
    do: dngettext("mishka_gervaz", "%{count} item left out.", "%{count} items left out.", count)

  defp chosen_words(:bring_back, count),
    do:
      dngettext(
        "mishka_gervaz",
        "%{count} item brought back.",
        "%{count} items brought back.",
        count
      )

  defp decided_words(decided, 0),
    do: dngettext("mishka_gervaz", "%{count} item decided.", "%{count} items decided.", decided)

  defp decided_words(decided, left),
    do:
      decided_words(decided, 0) <>
        " " <>
        dngettext(
          "mishka_gervaz",
          "%{count} left as it was: nothing on it takes this choice.",
          "%{count} left as they were: nothing on them takes this choice.",
          left
        )

  defp choice_word("site_has_own", "keep"), do: dgettext("mishka_gervaz", "Keep the site's own")

  defp choice_word("site_has_own", "import"),
    do: dgettext("mishka_gervaz", "Use the WordPress one")

  defp choice_word("header_has_links", "keep"),
    do: dgettext("mishka_gervaz", "Keep the site's own")

  defp choice_word("header_has_links", "import"),
    do: dgettext("mishka_gervaz", "Replace with the imported menu")

  defp choice_word("slug_taken", "keep"),
    do: dgettext("mishka_gervaz", "Connect to the existing record")

  defp choice_word("slug_taken", "import"),
    do: dgettext("mishka_gervaz", "Import as new with another slug")

  defp choice_word("blog_missing", "keep"), do: dgettext("mishka_gervaz", "Wait for the Blog")
  defp choice_word("blog_missing", "leave_out"), do: dgettext("mishka_gervaz", "Leave out")

  defp choice_word("player_not_allowed", "keep"),
    do: dgettext("mishka_gervaz", "Wait for an admin")

  defp choice_word("player_not_allowed", "import"),
    do: dgettext("mishka_gervaz", "Import without the player")

  defp choice_word("draft_pages", "keep"),
    do: dgettext("mishka_gervaz", "Leave those links out of the menu")

  defp choice_word("draft_pages", "import"),
    do: dgettext("mishka_gervaz", "Publish the linked pages")

  defp records(kind, site_id, user), do: kind |> Target.fetch() |> records_of(site_id, user)

  defp records_of({:ok, target}, site_id, user) do
    language = Languages.primary(site_id)

    target.resource()
    |> Ash.Query.filter(language == ^language)
    |> Ash.Query.sort(name: :asc)
    |> Read.call(%{actor: user, site_id: site_id})
    |> Enum.map(&{&1.name, &1.id})
  end

  defp records_of({:error, :not_installed}, _site_id, _user), do: []

  defp planned(%{left_out: true}),
    do: %{
      key: "left_out",
      word: dgettext("mishka_gervaz", "Left out by you"),
      class: "bg-[#f2f1ec] text-[#6d6a63]",
      icon: "hero-eye-slash",
      reason: nil
    }

  defp planned(%{mapped_id: id, mapped_paths: %{name: name}}) when is_binary(id),
    do: %{
      key: "mapped",
      word: dgettext("mishka_gervaz", "Connected"),
      class: "bg-[#eeedfb] text-[#5b57d6]",
      icon: "hero-link",
      reason: dgettext("mishka_gervaz", "Mapped by you to %{name}", name: name)
    }

  defp planned(%{mapped_id: id}) when is_binary(id),
    do: said(:skipped, plan_word(:skipped), "mapped_missing")

  defp planned(item), do: item |> waits_on() |> waiting(item)

  defp waiting(nil, item), do: as_planned(item)
  defp waiting(reason, item), do: reason |> code() |> waiting(reason, item.decisions)

  defp waiting(conflict, _reason, decisions) when is_map_key(decisions, conflict),
    do: %{
      key: "decided",
      word: dgettext("mishka_gervaz", "Decided"),
      class: "bg-[#eeedfb] text-[#5b57d6]",
      icon: "hero-check",
      reason: choice_word(conflict, Map.fetch!(decisions, conflict))
    }

  defp waiting(_conflict, reason, _decisions), do: said(:undecided, plan_word(:undecided), reason)

  defp waits_on(%{plan: :undecided, plan_reason: reason}) when is_binary(reason), do: reason

  defp waits_on(%{plan: nil, outcome: :undecided, reason: reason}) when is_binary(reason),
    do: reason

  defp waits_on(%{plan: plan, outcome: :undecided, reason: reason, decisions: decisions})
       when plan in [:created, :updated] and is_binary(reason),
       do: reason |> code() |> undecided(reason, decisions)

  defp waits_on(_item), do: nil

  defp undecided(conflict, _reason, decisions) when is_map_key(decisions, conflict), do: nil
  defp undecided(_conflict, reason, _decisions), do: reason

  defp code(nil), do: nil
  defp code(reason), do: reason |> String.split(": ", parts: 2) |> hd()

  defp as_planned(%{plan: :skipped, plan_reason: "left_out_by_admin"}),
    do: %{
      key: "brought_back",
      word: dgettext("mishka_gervaz", "Brought back"),
      class: "bg-[#f7f6f2] text-[#8a877f]",
      icon: "hero-arrow-uturn-left",
      reason: dgettext("mishka_gervaz", "Run a dry run again to see its plan")
    }

  defp as_planned(%{plan: nil}), do: none("", dgettext("mishka_gervaz", "No dry run yet"))

  defp as_planned(%{plan: :skipped, plan_reason: "connected"}),
    do: %{
      key: "connected",
      word: dgettext("mishka_gervaz", "Connected"),
      class: "bg-[#eeedfb] text-[#5b57d6]",
      icon: "hero-link",
      reason: nil
    }

  defp as_planned(%{plan: plan, plan_reason: reason}), do: said(plan, plan_word(plan), reason)

  defp imported(nil, _reason), do: none("", dgettext("mishka_gervaz", "Not imported"))
  defp imported(outcome, reason), do: said(outcome, MigrationRun.outcome_word(outcome), reason)

  defp said(key, word, reason),
    do: %{
      key: to_string(key),
      word: word,
      class: MigrationRun.outcome_class(key),
      icon: MigrationRun.outcome_icon(key),
      reason: reason && MigrationRun.reason_label(reason)
    }

  defp none(key, word),
    do: %{key: key, word: word, class: "bg-[#f7f6f2] text-[#bcb9b2]", icon: nil, reason: nil}

  defp plan_word(:created), do: dgettext("mishka_gervaz", "Would create")
  defp plan_word(:updated), do: dgettext("mishka_gervaz", "Would update")
  defp plan_word(:skipped), do: dgettext("mishka_gervaz", "Would skip")
  defp plan_word(:failed), do: dgettext("mishka_gervaz", "Would fail")
  defp plan_word(:undecided), do: dgettext("mishka_gervaz", "Needs your decision")
end
