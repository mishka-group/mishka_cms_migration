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

    * `:authors` — `"connect"` (the default) ties each source author to a user of the site, matched
      by email, and skips one with no match; `"create"` makes a user for one with no match. Either
      way each becomes that user's blog author (`MishkaCmsMigration.Targets.BlogBlogger`).
    * `:pages` — `"draft"` (the default) brings pages in as drafts; `"publish"` puts them live at
      their old addresses.
    * `:post_address` — `"blog"` (the default) serves posts at `/blog/<slug>`, with a 301 redirect
      from each old address; `"blog_without_redirects"` serves them there with no redirect.
      Keeping a source's own address, such as WordPress's `/2025/12/hello/`, needs Mishka Blog to
      serve a post at an address of its own first (mishka_blog#6), so it is not a choice yet.
    * `:comments` — whether comments come too; `false` by default.

  The authors choice is read by the Blog's author target and the post addresses by the redirect
  target (`MishkaCmsMigration.Targets.PostRedirect`), the pages choice by the page target
  (`MishkaCmsMigration.Targets.CmsPage`); comments will be read by the comment target, as that
  kind's import comes.

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
  it is through `:record_progress`, whose `progress` each request empties for its new job; after
  its last attempt fails, AshOban runs `:fail`, the
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

  Each step is an entry of the run's log (`MishkaCmsMigration.MigrationLog`), and once a dry run or
  an import ends — it finished, its job failed, or an admin cancelled it while it ran — the run's
  user and the admin whose job it was are told in the topbar bell
  (`MishkaCmsMigration.Resources.Notifiers.Steps`).

  Running again means a new run; the items earlier runs wrote
  (`MishkaCmsMigration.MigrationItem`) are what makes it update rather than duplicate.
  `created_count`, `updated_count`, `skipped_count` and `failed_count` count the items this run was
  the last to touch.

  ## The source's secret

  The secret a source signs in with (such as a WordPress application password) is the `:create`
  action's `secret` argument. The New import form types it under the connection's `"secret"` key
  (`c:MishkaCmsMigration.Source.form_fields/0`); `take_secret/2` moves it from there into the
  argument before the run connects, so `connection` never holds it, and a `secret` argument a
  caller gives as well wins. Only its sealed form is kept, in `connection_secret`, sealed the way
  `MishkaCmsCore.Settings` seals a `:secret` setting: `Phoenix.Token.encrypt/4` with the endpoint's
  `secret_key_base`, under a salt of this extension's own. The argument is dropped once sealed. The
  sealed secret is kept from the run's creation until it ends — done, failed or cancelled — and is
  cleared then; a job opens it with `open_secret/1` each time it connects to the source.

  A run with no secret hands the source `nil`. A secret that is stored but cannot be opened —
  `secret_key_base` was rotated since it was sealed — is `{:error, :unreadable_secret}`, which fails
  the run: the admin starts a new run with the secret typed again.

  ## The source's file

  A source that reads a file a site exported (`c:MishkaCmsMigration.Source.file?/0`, such as the
  WordPress export file) is handed it by the `:create` action's `file` argument: the New import
  form's upload, a file Gervaz staged (`MishkaCmsCore.Runtime.Media.staged_upload/2`, so a path a
  request names is never taken). `MishkaCmsMigration.Resources.Changes.SourceFile` puts that staged
  file's path in the connection's `"file"` while the run is checked, so the source can read the
  export's host (`c:MishkaCmsMigration.Source.host/1`), and just before the run connects copies it
  into its own folder (`MishkaCmsMigration.Resources.Changes.SourceFile.files_dir/0`) under a name
  of its own and points `"file"` there; a run that is then not saved takes its copy with it. A
  `"file"` a caller types in the connection is always dropped, so a run only ever names a file it
  was handed.

  That folder is outside the one the CMS serves (`MishkaCmsCore.Runtime.Media.static_dir/0`) and
  readable by the CMS's own user alone, so the export, with its drafts, private posts and
  commenters' addresses, is never public. The file is deleted once the run ends: done, failed or
  cancelled (`:finish_import`, `:fail`, `:cancel`), after the run is saved so. A run left waiting
  keeps it until an admin cancels it.

  ## Who reaches it

  A run is a site's own. Reading, creating, starting and cancelling one takes
  `admin:dashboard:migration` (or `admin:api:migration` over the API). A master (a user whose
  `site_id` is nil) reaches every site's runs; a site user only its own site's, whatever tenant it
  names. A run is created on the tenant (`:create`), which a site user may only name as its own
  site (`MishkaCmsCore.Runtime.Resources.Validations.TenantContext`), or by a master on the site it
  names (`:master_create`); the site filter holds reads and steps, so a create is decided before
  its source is asked anything.

  ## In the admin

  The Migration page lists a site's runs, every site's for a master, as a Gervaz table laid out
  like the Pages table: the source with its icon (`source_icon/1`) and the run's short id, the
  address it is moved from with the source site's name under it, where the run is as a coloured pill
  (`status_label/1`, `status_class/1`), its result (`result_cell/1`), for a master the site, and
  when it started. Each column is as narrow as its cell can be drawn without cutting it off, an
  address truncating with the whole of it as its tooltip, and a result wrapping onto more lines,
  so the table fits beside the admin's sidebar on a laptop screen without scrolling sideways. It
  filters by status, source, for a master the site, and the days a run started in, and keeps them
  in the address. The table follows the run's PubSub notifications, so a run moving on, and a
  running job's progress, show without a reload.

  A row offers what its status allows: Dry run on a run that is Connected (`:pending`), Run again on
  one whose dry run is ready (`:dry_run`), both `:start_dry_run`, Import on that same ready run
  (`:start_import`, once the admin confirms), and Cancel (`:cancel`, once the admin confirms) on
  one that is waiting, dry running, ready or importing. They are `:event` row actions, run by the
  page (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.Index`), and drawn by the domain's
  Tailwind adapter as the Pages table draws its own: an icon, with the action's name as its
  tooltip and accessible name. The Actions column is always as wide as the most a row shows, three
  30px buttons 4px apart with 16px either side (`actions_layout`'s `width`), so a row whose status
  changes its buttons never moves the other columns. A row expands to what its last dry run or
  import found, kind by kind: the kind in words (`kind_label/1`), how many items the source listed,
  what was done with them (`result_summary/1`) and why the skipped ones were skipped
  (`reason_label/1`).

  A source's card opens the run's Gervaz form with the card's source as the form's default. Its
  Connection is a `:key_map` whose keys the source names
  (`MishkaCmsMigration.Source.form_fields/1`), read each time the form is drawn and its params are
  read, so each source's New import asks for its own: WordPress's address, user and application
  password, and a plugin's source what its `form_fields/0` names. The secret's key is a masked
  password input that never shows what was typed. The field's description says where WordPress
  makes an application password, as a Gervaz key carries no description of its own. A source that
  reads a file asks for no Connection: the form shows its Export file instead, a dropzone taking
  one `.xml` file of up to 100 MB (see "The source's file"), the reason a file is refused under
  it. Under them,
  Choices for this run is a `:key_map` over `options` with a select for the authors, the pages and
  the post addresses, each starting at the default the `sub_field` gives it; its description says
  why a post's old address is redirected rather than kept. Comments are not asked for until a
  source's comments can be imported. For a master the form asks for the site the content moves to
  as well (`:master_create`). Its button, Check and save, creates the run, which connects to
  the source first, or reads its file (`MishkaCmsMigration.Resources.Changes.CheckConnection`): a
  source that does not answer or refuses the user keeps the form open with the reason, and nothing
  is saved. Gervaz takes a button's label as a string or a function of no arguments, so one label
  fits a connection and a file alike. A run that is not given a `source_host` takes the host its
  source reads from the connection (`c:MishkaCmsMigration.Source.host/1`).
  """

  use Ash.Resource,
    otp_app: :mishka_cms_migration,
    domain: MishkaCmsMigration,
    data_layer: AshPostgres.DataLayer,
    extensions: [GuardedStruct.AshResource, AshOban, MishkaGervaz.Resource],
    notifiers: [Ash.Notifier.PubSub, MishkaCmsMigration.Resources.Notifiers.Steps],
    authorizers: [Ash.Policy.Authorizer]

  use Gettext, backend: MishkaCmsCore.Gettext

  import Phoenix.Component, only: [sigil_H: 2]
  import MishkaGervaz.UIAdapters.Tailwind, only: [copy_button: 1]

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.Resources.Validations.TenantContext

  alias MishkaCmsMigration.Resources.Changes.{
    CancelJobs,
    CheckConnection,
    EnqueueJob,
    Reason,
    SourceFile
  }

  alias MishkaCmsMigration.Resources.Validations.{SourceInstalled, Status}
  alias MishkaCmsMigration.Workers.Helpers.Pipeline

  @statuses [:pending, :dry_running, :dry_run, :importing, :done, :failed, :cancelled]
  @endpoint Application.compile_env!(:mishka_cms_core, :endpoint)
  @secret_salt "mishka migration source secret"
  @outcomes MishkaCmsMigration.Report.outcomes()
  @counts Enum.map(@outcomes, &{&1, [type: :integer, allow_nil?: false]})
  @pick_site dgettext_noop("errors", "Pick the site the content moves to.")
  @type_address dgettext_noop("errors", "Type the site's address, such as https://example.com.")
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
        derives: "sanitize(trim) validate(enum=String[blog::blog_without_redirects])"

      field :comments, :boolean, default: false, derives: "validate(boolean)"
    end
  end

  oban do
    triggers do
      trigger :run_dry_run do
        action :run_dry_run
        where expr(status == :dry_running)
        queue :migration
        scheduler_cron false
        lock_for_update? false
        max_attempts 3
        backoff :exponential
        timeout :timer.hours(1)
        on_error :fail
        actor_persister MishkaCmsMigration.Workers.Helpers.Actor
        shared_context [:ash_oban?]
        worker_module_name MishkaCmsMigration.Workers.DryRunWorker
      end

      trigger :run_import do
        action :run_import
        where expr(status == :importing)
        queue :migration
        scheduler_cron false
        lock_for_update? false
        max_attempts 3
        backoff :exponential
        timeout :timer.hours(1)
        on_error :fail
        actor_persister MishkaCmsMigration.Workers.Helpers.Actor
        shared_context [:ash_oban?]
        worker_module_name MishkaCmsMigration.Workers.ImportWorker
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

        column :source_info do
          static true
          requires [:id, :source]
          label fn -> dgettext("mishka_gervaz", "Source") end

          ui do
            width "minmax(184px,1.3fr)"
          end

          render fn record ->
            short_id = String.slice(record.id, 0, 8) <> "…" <> String.slice(record.id, -4, 4)

            assigns = %{
              id: record.id,
              short_id: short_id,
              label: MishkaCmsMigration.Source.label(record.source),
              icon: MishkaCmsMigration.MigrationRun.source_icon(record.source)
            }

            ~H"""
            <div class="flex min-w-0 items-center gap-[11px]">
              <span class="grid size-[34px] flex-none place-items-center rounded-[10px] bg-[#f1edfb] text-[#7a5bd0]">
                <MishkaCmsCore.CoreComponents.icon name={@icon} class="size-[18px]" />
              </span>
              <div class="min-w-0">
                <div
                  data-role="run-source"
                  class="truncate text-[13.5px] font-semibold text-[#17161a]"
                >
                  {@label}
                </div>
                <div class="mt-[2px] flex items-center gap-[5px]">
                  <span class="font-['Space_Grotesk'] text-[11px] font-medium text-[#a8a5a0]">{@short_id}</span>
                  <.copy_button
                    id={"run-id-copy-#{@id}"}
                    value={@id}
                    label={dgettext("mishka_gervaz", "Copy run ID")}
                  />
                </div>
              </div>
            </div>
            """
          end
        end

        column :from do
          static true
          requires [:source_host, :extra]
          label fn -> dgettext("mishka_gervaz", "From") end

          ui do
            width "minmax(84px,1.1fr)"
          end

          render fn record ->
            assigns = %{host: record.source_host, name: record.extra["name"]}

            ~H"""
            <div class="min-w-0">
              <div
                class="truncate font-['Space_Grotesk'] text-[12.5px] font-semibold text-[#3a382f]"
                title={@host}
              >
                {@host}
              </div>
              <div
                :if={@name}
                class="mt-[2px] truncate text-[11px] font-medium text-[#a8a5a0]"
                title={@name}
              >
                {@name}
              </div>
            </div>
            """
          end
        end

        column :status do
          label fn -> dgettext("mishka_gervaz", "Status") end
          sortable true

          ui do
            width "minmax(144px,0.9fr)"
          end

          render fn status ->
            assigns = %{
              status: status,
              label: MishkaCmsMigration.MigrationRun.status_label(status),
              class: MishkaCmsMigration.MigrationRun.status_class(status),
              running?: status in [:dry_running, :importing]
            }

            ~H"""
            <span
              data-role="run-status"
              data-status={@status}
              class={[
                "inline-flex w-fit items-center gap-[6px] rounded-[20px] px-[10px] py-[3px] text-[10px] font-bold whitespace-nowrap",
                @class
              ]}
            >
              <span class={["size-[5px] rounded-full bg-current", @running? && "motion-safe:animate-pulse"]}></span>{@label}
            </span>
            """
          end
        end

        column :result do
          static true
          requires [:status, :source, :report, :progress]
          label fn -> dgettext("mishka_gervaz", "Result") end

          ui do
            width "minmax(130px,1.6fr)"
          end

          render fn record -> MishkaCmsMigration.MigrationRun.result_cell(record) end
        end

        column :site_info do
          static true
          requires [:site_id, :site]
          label fn -> dgettext("mishka_gervaz", "Site") end
          visible fn state -> state.master_user? end

          ui do
            width "minmax(120px,0.9fr)"
          end

          render fn record ->
            assigns = %{name: record.site && record.site.name}

            ~H"""
            <MishkaCmsCore.CoreComponents.site_cell global?={false} name={@name} />
            """
          end
        end

        column :started do
          static true
          requires [:inserted_at]
          label fn -> dgettext("mishka_gervaz", "Started") end
          sortable true
          sort_field [:inserted_at]

          ui do
            width "minmax(116px,0.7fr)"
          end

          render fn record ->
            assigns = %{
              date: MishkaCmsCore.Localized.date(record.inserted_at, :yMMMd),
              time: MishkaCmsCore.Localized.time(record.inserted_at, :Hm)
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
        filter :site_id, :relation do
          mode :search_multi
          display_field :name
          search_field :name
          min_chars 1
          page_size 15
          restricted true

          ui do
            label fn -> dgettext("mishka_gervaz", "Site") end
            placeholder fn -> dgettext("mishka_gervaz", "Search sites...") end
          end
        end

        filter :status, :select do
          options fn -> MishkaCmsMigration.MigrationRun.status_options() end

          ui do
            prompt dgettext_noop("mishka_gervaz", "Any status")
            label fn -> dgettext("mishka_gervaz", "Status") end
          end
        end

        filter :source, :select do
          options fn -> MishkaCmsMigration.MigrationRun.source_options() end

          ui do
            prompt dgettext_noop("mishka_gervaz", "Any source")
            label fn -> dgettext("mishka_gervaz", "Source") end
          end
        end

        filter :started, :date_range do
          source :inserted_at

          ui do
            label fn -> dgettext("mishka_gervaz", "Started") end
          end
        end
      end

      row_actions do
        actions_layout do
          width "minmax(130px,max-content)"
        end

        action :expand, type: :accordion

        action :dry_run do
          type :event
          event "dry_run"
          visible fn record, _state -> record.status == :pending end

          ui do
            label fn -> dgettext("mishka_gervaz", "Dry run") end
            icon "hero-play"
          end
        end

        action :dry_run_again do
          type :event
          event "dry_run"
          visible fn record, _state -> record.status == :dry_run end

          ui do
            label fn -> dgettext("mishka_gervaz", "Run again") end
            icon "hero-arrow-path"
          end
        end

        action :import do
          type :event
          event "import"

          confirm fn _record ->
            dgettext(
              "mishka_gervaz",
              "Import now? It writes what the dry run found into the CMS."
            )
          end

          visible fn record, _state -> record.status == :dry_run end

          ui do
            label fn -> dgettext("mishka_gervaz", "Import") end
            icon "hero-arrow-down-tray"
          end
        end

        action :cancel do
          type :event
          event "cancel"

          confirm fn _record ->
            dgettext("mishka_gervaz", "Cancel this run? It cannot be started again.")
          end

          visible fn record, _state ->
            record.status in [:pending, :dry_running, :dry_run, :importing]
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Cancel") end
            icon "hero-x-mark"
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
        params [:filters, :sort, :page]
        prefix "runs"
        max_filter_length 500
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No runs found"),
                  icon: "hero-arrows-right-left"
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

        field :connection, :key_map do
          required true
          options fn state -> MishkaCmsMigration.Source.form_fields(state) end
          visible fn state -> MishkaCmsMigration.Source.form_fields(state) != [] end

          ui do
            label fn -> dgettext("mishka_gervaz", "Connection") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "A WordPress application password is made under Users, Profile, Application Passwords. The password is kept sealed until the run ends."
              )
            end
          end
        end

        field :file, :upload do
          required true
          visible fn state -> MishkaCmsMigration.Source.file?(state) end

          ui do
            label fn -> dgettext("mishka_gervaz", "Export file") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "The .xml file WordPress makes under Tools, Export, with All content chosen. It is kept privately until the run ends, then deleted."
              )
            end
          end
        end

        field :options, :key_map do
          default %{"authors" => "connect", "pages" => "draft", "post_address" => "blog"}

          options [
            [
              name: :authors,
              type: :select,
              label: dgettext_noop("mishka_gervaz", "Authors"),
              options: [
                {dgettext_noop("mishka_gervaz", "Match by email, skip the rest"), "connect"},
                {dgettext_noop("mishka_gervaz", "Match by email, create the rest"), "create"}
              ]
            ],
            [
              name: :pages,
              type: :select,
              label: dgettext_noop("mishka_gervaz", "Pages"),
              options: [
                {dgettext_noop("mishka_gervaz", "Drafts"), "draft"},
                {dgettext_noop("mishka_gervaz", "Live at their old addresses"), "publish"}
              ]
            ],
            [
              name: :post_address,
              type: :select,
              label: dgettext_noop("mishka_gervaz", "Post addresses"),
              options: [
                {dgettext_noop("mishka_gervaz", "/blog/<slug> + 301 redirect"), "blog"},
                {dgettext_noop("mishka_gervaz", "/blog/<slug>, no redirect"),
                 "blog_without_redirects"}
              ]
            ]
          ]

          ui do
            label fn -> dgettext("mishka_gervaz", "Choices for this run") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Mishka Blog serves each post at /blog/<slug>. Keeping a post's WordPress address, such as /2025/12/hello/, needs the Blog to serve posts there first, so a 301 redirect from it is offered instead. Pages arrive at their old paths, as drafts or live."
              )
            end
          end
        end
      end

      groups do
        group :connection do
          fields [:site_id, :connection, :file]

          ui do
            columns 1
          end
        end

        group :options do
          fields [:options]

          ui do
            columns 1
          end
        end
      end

      uploads do
        upload :file do
          accept ~w(.xml)
          max_entries 1
          max_file_size 100_000_000
          style :dropzone
        end
      end

      submit do
        create label: fn -> dgettext("mishka_gervaz", "Check and save") end
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
      allow_nil_input [:source_host]

      argument :secret, :string do
        sensitive? true
        allow_nil? true
        description "The secret the source signs in with; only its sealed form is kept"
      end

      argument :file, {:array, :map} do
        allow_nil? true
        description "The file a source that reads one is handed: the form's staged upload"
      end

      validate {TenantContext, require_master: false}
      change &MishkaCmsMigration.MigrationRun.take_secret/2
      change {SourceFile, step: :take}
      change CheckConnection
      validate present(:source_host), only_when_valid?: true, message: @type_address
      validate SourceInstalled, before_action?: true

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)
      change set_attribute(:user_id, actor(:id))
      change &MishkaCmsMigration.MigrationRun.seal_secret/2

      description "Creates a run on the tenant's site, started by the actor, once its source answers"
    end

    create :master_create do
      accept [:site_id, :source, :source_host, :connection, :options]
      allow_nil_input [:site_id, :source_host]

      argument :secret, :string do
        sensitive? true
        allow_nil? true
        description "The secret the source signs in with; only its sealed form is kept"
      end

      argument :file, {:array, :map} do
        allow_nil? true
        description "The file a source that reads one is handed: the form's staged upload"
      end

      validate {TenantContext, require_master: true}
      validate present(:site_id), message: @pick_site
      change &MishkaCmsMigration.MigrationRun.take_secret/2
      change {SourceFile, step: :take}
      change CheckConnection
      validate present(:source_host), only_when_valid?: true, message: @type_address
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
      change set_attribute(:progress, nil)
      change {EnqueueJob, trigger: :run_dry_run}

      description "Queues a dry run: what an import would create, update and skip, writing nothing"
    end

    update :start_import do
      accept []

      validate {TenantContext, require_master: false}
      validate {Status, from: [:dry_run]}

      change set_attribute(:status, :importing)
      change set_attribute(:progress, nil)
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
      change {SourceFile, step: :drop}

      description "System-internal: saves the import's report"
    end

    update :cancel do
      accept []

      validate {TenantContext, require_master: false}
      validate {Status, from: [:pending, :dry_running, :dry_run, :importing]}

      change set_attribute(:status, :cancelled)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change set_attribute(:connection_secret, nil)
      change {SourceFile, step: :drop}
      change CancelJobs

      description "Ends a run that is not done: its job is cancelled, its secret and file cleared"
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
      change {SourceFile, step: :drop}

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

  @doc """
  Takes the secret out of a new run's `connection`: what a form typed under its `"secret"` key (or
  `:secret`, from a caller of its own) becomes the action's `secret` argument, which
  `seal_secret/2` keeps only sealed, and the key is dropped, so `connection` never holds the
  secret. A `secret` argument the caller gave wins over the key; a blank key is dropped alone.
  `:create` and `:master_create` run it before they connect
  (`MishkaCmsMigration.Resources.Changes.CheckConnection`).
  """
  @spec take_secret(Ash.Changeset.t(), map()) :: Ash.Changeset.t()
  def take_secret(changeset, _context),
    do: changeset |> Ash.Changeset.get_attribute(:connection) |> secret_taken(changeset)

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

  @doc "The pill colours of a run with `status`; its dot takes the text colour."
  @spec status_class(atom()) :: String.t()
  def status_class(:pending), do: "bg-[#eaf1fb] text-[#3a6cb5]"

  def status_class(status) when status in [:dry_running, :importing],
    do: "bg-[#eef0ff] text-[#4f4bcc]"

  def status_class(:dry_run), do: "bg-[#fff6e0] text-[#8a5a00]"
  def status_class(:done), do: "bg-[#e6f6ee] text-[#177a53]"
  def status_class(:failed), do: "bg-[#fdecea] text-[#c0473d]"
  def status_class(_cancelled), do: "bg-[#f2f1ec] text-[#8a877f]"

  @doc "Every status as a `{label, status}` pair, in the order a run goes through them."
  @spec status_options() :: [{String.t(), atom()}]
  def status_options, do: Enum.map(@statuses, &{status_label(&1), &1})

  @doc "The installed sources as `{label, id}` pairs."
  @spec source_options() :: [{String.t(), String.t()}]
  def source_options,
    do:
      Enum.map(
        MishkaCmsMigration.Source.all(),
        &{MishkaCmsMigration.Source.label(&1.id()), &1.id()}
      )

  @doc "The heroicon that stands for the source whose id is `id` in the admin's lists."
  @spec source_icon(String.t()) :: String.t()
  def source_icon("wordpress"), do: "hero-globe-alt"
  def source_icon("wordpress_file"), do: "hero-document-arrow-up"
  def source_icon(_other), do: "hero-server-stack"

  @doc """
  What a run's `report` counts, in one line: `"3 created · 1 updated · 2 skipped · 0 failed"`, or
  `"—"` before its first dry run.
  """
  @spec result_summary(map() | nil) :: String.t()
  def result_summary(%{counts: counts}) do
    Enum.map_join(MishkaCmsMigration.Report.outcomes(), " · ", fn outcome ->
      outcome_count(outcome, Map.get(counts, outcome, 0))
    end)
  end

  def result_summary(_no_report), do: "—"

  @doc """
  The outcomes a run's `report` counts more than none of, in `MishkaCmsMigration.Report.outcomes/0`
  order, each with its count: `[created: 3, skipped: 2]`. Empty before the first dry run, and for a
  report whose source listed nothing.
  """
  @spec result_outcomes(map() | nil) :: [{atom(), pos_integer()}]
  def result_outcomes(%{counts: counts}) do
    for outcome <- @outcomes,
        count = Map.get(counts, outcome, 0),
        count > 0,
        do: {outcome, count}
  end

  def result_outcomes(_no_report), do: []

  @doc "One outcome's count in words, as a Result pill's tooltip begins: `\"3 created\"`."
  @spec outcome_count(atom(), non_neg_integer()) :: String.t()
  def outcome_count(outcome, count),
    do: "#{MishkaCmsCore.Localized.number(count)} #{outcome_label(outcome)}"

  @doc "The pill colours of an outcome's count: green created, blue updated, grey skipped, red failed."
  @spec outcome_class(atom()) :: String.t()
  def outcome_class(:created), do: "bg-[#e6f6ee] text-[#177a53]"
  def outcome_class(:updated), do: "bg-[#eaf1fb] text-[#3a6cb5]"
  def outcome_class(:skipped), do: "bg-[#f2f1ec] text-[#8a877f]"
  def outcome_class(:failed), do: "bg-[#fdecea] text-[#c0473d]"

  @doc "The heroicon of an outcome's pill: a plus created, arrows updated, a minus skipped, a warning failed."
  @spec outcome_icon(atom()) :: String.t()
  def outcome_icon(:created), do: "hero-plus"
  def outcome_icon(:updated), do: "hero-arrow-path"
  def outcome_icon(:skipped), do: "hero-minus"
  def outcome_icon(:failed), do: "hero-exclamation-triangle"

  @doc """
  The heroicon that stands for the items of `kind` in the admin's lists, such as
  `"hero-document-text"` for `"post"`; a kind this extension does not name is a cube.
  """
  @spec kind_icon(String.t()) :: String.t()
  def kind_icon("user"), do: "hero-user"
  def kind_icon("category"), do: "hero-folder"
  def kind_icon("tag"), do: "hero-tag"
  def kind_icon("media"), do: "hero-photo"
  def kind_icon("page"), do: "hero-document"
  def kind_icon("post"), do: "hero-document-text"
  def kind_icon("post_redirect"), do: "hero-arrows-right-left"
  def kind_icon(_other), do: "hero-cube"

  @doc """
  The Runs table's Result cell for `run`, drawn in the width its column gives it: its pills and
  chips wrap onto more lines rather than widen the column.

    * While the run is dry running or importing, how far its job is (`progress`): the kind it
      walks, with its icon, the items met so far, of how many the run's last report
      counted when it has one, and a thin bar of that share. Without a report the bar fills by the
      kinds of the source walked so far. Before the job's first page it reads Starting.
    * Otherwise, what its last report counted: a pill for each outcome counted more than none of,
      in `MishkaCmsMigration.Report.outcomes/0` order (green created, blue updated, grey skipped,
      red failed), each an icon and its count, its tooltip the count in words and, for skipped or
      failed items, the reason most of them share (`reason_label/1`). Under them a grey chip for
      each kind it met, the kind's icon (`kind_icon/1`) and how many the source listed, its
      tooltip the kind in words (`kind_label/1`). "Nothing to move" when it counted nothing, and "—" before the first
      dry run.

  The data the page's tests read: `data-role="run-result"` on the cell, `"run-progress"` (with
  `data-kind`, `data-done` and `data-total`), `"run-outcome"` (`data-outcome`, `data-count` and
  `data-reason`, the shared reason as the report keeps it) and `"run-kind"` (`data-kind`,
  `data-count`). The bar's width is one of the admin sheet's `w-[N%]` classes (0 to 100), so it
  needs no `style` attribute.
  """
  @spec result_cell(map()) :: Phoenix.LiveView.Rendered.t()
  def result_cell(run) do
    assigns = result(run)

    ~H"""
    <div data-role="run-result" class="grid min-w-0 gap-[5px]">
      <div
        :if={@progress}
        data-role="run-progress"
        data-kind={@progress.kind}
        data-done={@progress.done}
        data-total={@progress.total}
        title={@progress.title}
        class="min-w-0"
      >
        <div class="flex flex-wrap items-center justify-between gap-x-[6px] gap-y-px">
          <span class="flex min-w-0 items-center gap-[4px] text-[10.5px] font-semibold text-[#4f4bcc]">
            <MishkaCmsCore.CoreComponents.icon
              :if={@progress.icon}
              name={@progress.icon}
              class="size-[11px] flex-none"
            />
            <span class="truncate">{@progress.label}</span>
          </span>
          <span class="font-['Space_Grotesk'] text-[10.5px] font-semibold text-[#8a877f]">
            {@progress.count}
          </span>
        </div>
        <div class="mt-[5px] h-[3px] overflow-hidden rounded-full bg-[#e9e8f7]">
          <div class={[
            "h-full rounded-full bg-[#5b57d6] motion-safe:transition-[width] motion-safe:duration-500",
            @progress.width
          ]}>
          </div>
        </div>
      </div>
      <div :if={@outcomes != []} class="flex flex-wrap gap-[4px]">
        <span
          :for={outcome <- @outcomes}
          data-role="run-outcome"
          data-outcome={outcome.outcome}
          data-count={outcome.count}
          data-reason={outcome.reason}
          title={outcome.title}
          class={[
            "inline-flex items-center gap-[3px] rounded-[20px] px-[6px] py-[2px] text-[10px] font-bold whitespace-nowrap",
            outcome.class
          ]}
        >
          <MishkaCmsCore.CoreComponents.icon name={outcome.icon} class="size-[10px] flex-none" />
          {outcome.number}<span class="sr-only">{"\u00a0" <> outcome.label}</span>
        </span>
      </div>
      <div :if={@kinds != []} class="flex flex-wrap gap-[3px]">
        <span
          :for={kind <- @kinds}
          data-role="run-kind"
          data-kind={kind.kind}
          data-count={kind.count}
          title={kind.title}
          class="inline-flex items-center gap-[2px] rounded-[6px] border border-[#ecebe6] px-[4px] py-px text-[10px] font-semibold whitespace-nowrap text-[#8a877f]"
        >
          <MishkaCmsCore.CoreComponents.icon name={kind.icon} class="size-[10px] flex-none" />
          {kind.number}<span class="sr-only">{"\u00a0" <> kind.label}</span>
        </span>
      </div>
      <span :if={@note} class="text-[12.5px] font-medium text-[#a8a5a0]">{@note}</span>
    </div>
    """
  end

  defp result(%{status: status} = run) when status in [:dry_running, :importing],
    do: %{progress: progress(run), outcomes: [], kinds: [], note: nil}

  defp result(%{report: %{kinds: kinds} = report}) do
    outcomes =
      for {outcome, count} <- result_outcomes(report),
          do: outcome_pill(outcome, count, shared_reason(report, outcome))

    chips =
      for %{kind: kind} = kind_counts <- kinds,
          count = items(kind_counts),
          count > 0,
          do: kind_chip(kind, count)

    %{progress: nil, outcomes: outcomes, kinds: chips, note: nothing_to_move(outcomes)}
  end

  defp result(_no_report), do: %{progress: nil, outcomes: [], kinds: [], note: "—"}

  defp outcome_pill(outcome, count, reason) do
    %{
      outcome: outcome,
      count: count,
      number: MishkaCmsCore.Localized.number(count),
      label: outcome_label(outcome),
      icon: outcome_icon(outcome),
      class: outcome_class(outcome),
      reason: reason,
      title: outcome_title(outcome_count(outcome, count), reason)
    }
  end

  defp kind_chip(kind, count) do
    number = MishkaCmsCore.Localized.number(count)

    %{
      kind: kind,
      count: count,
      number: number,
      label: kind_label(kind),
      icon: kind_icon(kind),
      title:
        dgettext("mishka_gervaz", "%{kind}: %{count} found",
          kind: kind_label(kind),
          count: number
        )
    }
  end

  defp nothing_to_move([]), do: dgettext("mishka_gervaz", "Nothing to move")
  defp nothing_to_move(_outcomes), do: nil

  defp outcome_title(count, nil), do: count

  defp outcome_title(count, reason),
    do:
      dgettext("mishka_gervaz", "%{count}: %{reason}",
        count: count,
        reason: reason |> reason_label() |> String.split_at(120) |> shortened()
      )

  defp shortened({text, ""}), do: text
  defp shortened({text, _rest}), do: text <> "…"

  defp shared_reason(%{entries: entries}, outcome) when outcome in [:skipped, :failed] do
    entries
    |> Enum.filter(&(&1.outcome == outcome and is_binary(&1.reason)))
    |> Enum.frequencies_by(& &1.reason)
    |> Enum.max_by(&elem(&1, 1), fn -> {nil, 0} end)
    |> elem(0)
  end

  defp shared_reason(_report, _outcome), do: nil

  defp progress(%{progress: %{kind: kind, counts: counts}} = run) do
    done = items(counts)
    total = run.report |> reported_items() |> at_least(done)

    %{
      kind: kind,
      icon: kind_icon(kind),
      label: walking(run.status, kind),
      done: done,
      total: total,
      count: progress_count(done, total),
      title: progress_title(done, total),
      width: "w-[#{share(done, total, kind, run.source)}%]"
    }
  end

  defp progress(_run_before_its_first_page) do
    %{
      kind: nil,
      icon: nil,
      label: dgettext("mishka_gervaz", "Starting"),
      done: 0,
      total: nil,
      count: nil,
      title: nil,
      width: "w-[0%]"
    }
  end

  defp walking(:dry_running, kind),
    do: dgettext("mishka_gervaz", "Reading %{kind}", kind: kind_noun(kind))

  defp walking(:importing, kind),
    do: dgettext("mishka_gervaz", "Importing %{kind}", kind: kind_noun(kind))

  defp progress_count(done, nil), do: MishkaCmsCore.Localized.number(done)

  defp progress_count(done, total),
    do: "#{MishkaCmsCore.Localized.number(done)}/#{MishkaCmsCore.Localized.number(total)}"

  defp progress_title(done, nil),
    do:
      dgettext("mishka_gervaz", "%{done} items so far",
        done: MishkaCmsCore.Localized.number(done)
      )

  defp progress_title(done, total),
    do:
      dgettext("mishka_gervaz", "%{done} of %{total} items",
        done: MishkaCmsCore.Localized.number(done),
        total: MishkaCmsCore.Localized.number(total)
      )

  defp share(done, total, _kind, _source) when is_integer(total), do: div(done * 100, total)

  defp share(_done, nil, kind, source) do
    with {:ok, module} <- MishkaCmsMigration.Source.fetch(source),
         kinds = module.kinds(),
         index when is_integer(index) <- Enum.find_index(kinds, &(&1 == kind)) do
      div(index * 100, length(kinds))
    else
      _unknown -> 0
    end
  end

  defp reported_items(%{counts: counts}), do: items(counts)
  defp reported_items(_no_report), do: 0

  defp at_least(0, _done), do: nil
  defp at_least(total, done), do: max(total, done)

  defp items(counts), do: counts |> Map.take(@outcomes) |> Map.values() |> Enum.sum()

  defp outcome_label(:created), do: dgettext("mishka_gervaz", "created")
  defp outcome_label(:updated), do: dgettext("mishka_gervaz", "updated")
  defp outcome_label(:skipped), do: dgettext("mishka_gervaz", "skipped")
  defp outcome_label(:failed), do: dgettext("mishka_gervaz", "failed")

  defp kind_noun("user"), do: dgettext("mishka_gervaz", "users")
  defp kind_noun("category"), do: dgettext("mishka_gervaz", "categories")
  defp kind_noun("tag"), do: dgettext("mishka_gervaz", "tags")
  defp kind_noun("media"), do: dgettext("mishka_gervaz", "files")
  defp kind_noun("page"), do: dgettext("mishka_gervaz", "pages")
  defp kind_noun("post"), do: dgettext("mishka_gervaz", "posts")
  defp kind_noun("post_redirect"), do: dgettext("mishka_gervaz", "redirects")
  defp kind_noun(kind), do: kind

  @doc """
  The items of `kind` as the admin reads them, such as `"Posts"` for `"post"`. A kind this
  extension does not name, one a source plugin of its own lists, reads as itself, capitalized.
  """
  @spec kind_label(String.t()) :: String.t()
  def kind_label("user"), do: dgettext("mishka_gervaz", "Users")
  def kind_label("category"), do: dgettext("mishka_gervaz", "Categories")
  def kind_label("tag"), do: dgettext("mishka_gervaz", "Tags")
  def kind_label("media"), do: dgettext("mishka_gervaz", "Media")
  def kind_label("page"), do: dgettext("mishka_gervaz", "Pages")
  def kind_label("post"), do: dgettext("mishka_gervaz", "Posts")
  def kind_label("post_redirect"), do: dgettext("mishka_gervaz", "Redirects")
  def kind_label(kind), do: String.capitalize(kind)

  @doc """
  Why an item was skipped or failed, or what was written otherwise than the source has it (a
  `MishkaCmsMigration.Report` entry's `reason`), as the admin reads it, each of its parts (joined by
  `"; "`) in words. A plugin's own reason, and what a source or the CMS answered, read as they are.
  """
  @spec reason_label(String.t()) :: String.t()
  def reason_label(reason), do: reason |> String.split("; ") |> Enum.map_join("; ", &said/1)

  defp said("no_target"), do: dgettext("mishka_gervaz", "Nothing imports these yet")
  defp said("unchanged"), do: dgettext("mishka_gervaz", "Unchanged")
  defp said("edited_in_cms"), do: dgettext("mishka_gervaz", "Edited in the CMS, so kept")
  defp said("target_missing"), do: dgettext("mishka_gervaz", "Deleted in the CMS, so left out")
  defp said("duplicate_in_source"), do: dgettext("mishka_gervaz", "Listed twice by the source")
  defp said("parent_missing"), do: dgettext("mishka_gervaz", "Its parent was not imported")
  defp said("no_user"), do: dgettext("mishka_gervaz", "No user with this email on the site")
  defp said("not_chosen"), do: dgettext("mishka_gervaz", "Left out by this run's choices")
  defp said("no_old_address"), do: dgettext("mishka_gervaz", "No public address at the source")
  defp said("post_missing"), do: dgettext("mishka_gervaz", "Its post was not imported")
  defp said("same_address"), do: dgettext("mishka_gervaz", "Already at its old address")

  defp said("author_missing"),
    do: dgettext("mishka_gervaz", "Its author was not imported, so it has none")

  defp said("featured_image_missing"),
    do: dgettext("mishka_gervaz", "Its featured image was not imported, so it has none")

  defp said("connected"),
    do: dgettext("mishka_gervaz", "Already in the CMS, so linked and kept as it is")

  defp said("plugins_cannot_run"),
    do: dgettext("mishka_gervaz", "A plugin it needs is not loaded")

  defp said("plugins_failed"), do: dgettext("mishka_gervaz", "A plugin failed on it")

  defp said("draft_from_pending"),
    do: dgettext("mishka_gervaz", "Pending review at the source, so a draft")

  defp said("draft_from_private"),
    do: dgettext("mishka_gervaz", "Private at the source, so a draft")

  defp said("draft_from_password"),
    do: dgettext("mishka_gervaz", "Password-protected at the source, so a draft")

  defp said("draft_from_future"),
    do: dgettext("mishka_gervaz", "Scheduled at the source, so a draft")

  defp said("path_taken"),
    do: dgettext("mishka_gervaz", "The site already has a page at this address, so it is kept")

  defp said("path_made_ascii"),
    do: dgettext("mishka_gervaz", "Its address was made ASCII, so the old address is not served")

  defp said("not_on_source"),
    do: dgettext("mishka_gervaz", "Its file is not on the source's own site, so it is left there")

  defp said("type_not_allowed"),
    do: dgettext("mishka_gervaz", "Media cannot keep this type of file")

  defp said("wrong_type"),
    do: dgettext("mishka_gervaz", "The source says this file is another type than its name")

  defp said("too_big"), do: dgettext("mishka_gervaz", "Larger than Media takes")

  defp said("wrong_bytes"),
    do: dgettext("mishka_gervaz", "The file is not the type its name says, so it is left out")

  defp said("not_downloaded"), do: dgettext("mishka_gervaz", "The source did not send the file")

  defp said("unconverted: " <> names),
    do: dgettext("mishka_gervaz", "Kept as text: %{names}", names: names)

  defp said(reason), do: reason

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

  defp secret_taken(%{} = connection, changeset)
       when is_map_key(connection, "secret") or is_map_key(connection, :secret) do
    typed = Map.get(connection, "secret", Map.get(connection, :secret))

    changeset
    |> Ash.Changeset.force_change_attribute(
      :connection,
      Map.drop(connection, ["secret", :secret])
    )
    |> secret_argument(Ash.Changeset.get_argument(changeset, :secret), typed)
  end

  defp secret_taken(_no_secret, changeset), do: changeset

  defp secret_argument(changeset, given, _typed) when is_binary(given) and given != "",
    do: changeset

  defp secret_argument(changeset, _none, typed) when is_binary(typed) and typed != "",
    do: Ash.Changeset.set_argument(changeset, :secret, typed)

  defp secret_argument(changeset, _none, _blank), do: changeset

  defp sealed(changeset, secret) when is_binary(secret) and secret != "",
    do:
      Ash.Changeset.force_change_attribute(
        changeset,
        :connection_secret,
        Phoenix.Token.encrypt(@endpoint, @secret_salt, secret)
      )

  defp sealed(changeset, _none), do: changeset
end
