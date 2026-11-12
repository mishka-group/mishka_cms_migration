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
    * `:post_address` — `"keep"` (the default) serves each post at the address the source gave
      it: the run's detected permalink structure (`extra`'s `"permalinks"`) becomes the path of the
      Blog's post page, and its category, tag and author pages take the source's bases
      (`MishkaCmsMigration.Targets.Helpers.BlogPages`); a source with no structure detected keeps
      the Blog's own addresses. `"blog"` serves posts at `/blog/<slug>`; either way each old
      address the site does not serve at the same path is redirected with a 301
      (`MishkaCmsMigration.Targets.PostRedirect`). `"blog_without_redirects"` serves them at
      `/blog/<slug>` with no redirect.
    * `:comment_pages` — whether the source breaks a post's comments into pages, each at its own
      address (WordPress's `/comment-page-2/`); `false` by default. On, each page's address is
      redirected to its post, `ceil(N / comments_per_page)` pages for a post with N approved
      comments that answer no other (`MishkaCmsMigration.Sources.WordPress.Addresses`).
    * `:comments_per_page` — how many of those comments a page holds, `50` by default, WordPress's
      own; read only with `:comment_pages` on. Neither WordPress's REST API nor its export says.
    * `:posts_page` — where the Blog's list of posts is served: `"source"` (the default) at the
      source's posts page (its `"front_page"` facts, else the page whose address is the posts'),
      `"front"` at `/`, the id of one of the site's pages at that page's address (the page is
      archived to free it), or `"blog"` at the Blog's own `/blog`.
    * `:blog_pages` — `"use"` (the default) uses the site's Blog pages, moved where the post
      addresses and posts list page choices put them, and creates the missing ones there;
      `"create"` creates the missing ones at the Blog's default `/blog/...` paths and leaves the
      site's own where they are, so the source's addresses reach them through 301s. Either way a
      page of the site's own at the path one would take is left alone, and that Blog page waits
      (`MishkaCmsMigration.Targets.Helpers.BlogPages`).
    * `:confirm_users` — whether the users the authors choice creates have their email confirmed;
      `true` by default. Either way no "Confirm your email" mail is sent; a user left unconfirmed
      is confirmed later from the Users table's bulk Confirm email.
    * `:comments` — whether comments come too; `false` by default. A comment by a user of the
      site, or by someone whose email is one, is written on its Blog post as theirs, and a
      guest's with the name and email the guest gave.

  The authors and confirm users choices are read by the Blog's author target and the post addresses by the redirect
  target (`MishkaCmsMigration.Targets.PostRedirect`), the pages choice by the page target
  (`MishkaCmsMigration.Targets.CmsPage`) and the comments choice by the comment target
  (`MishkaCmsMigration.Targets.BlogComment`).

  ## Its life

      :pending ─ start_dry_run ─▶ :dry_running ─▶ :dry_run ─ start_import ─▶ :importing ─▶ :done
                                        │                                          │
                                        └───────────────────▶ :failed ◀────────────┘

      start_dry_run again: :dry_run, :done or :failed ─▶ :dry_running
      cancel: any status but :cancelled ─▶ :cancelled

  An admin creates a run (`:create`), asks for a dry run (`:start_dry_run`) and, once it has
  reported, for the import (`:start_import`). A run whose dry run is ready, that is done or that
  failed takes `:start_dry_run` again, Run again: a fresh dry run on the same run and connection,
  then the usual import, which brings what the source changed since and what an admin decided, left
  out or mapped since the last import. It empties how far the last job got (`progress`), when the
  run ended (`finished_at`) and why it failed (`reason`), and the dry run, once it has walked the
  whole source, empties the plan of each item of the run's source host it did not meet
  (`MishkaCmsMigration.Workers.Helpers.Pipeline`); the run's `report` stays until the new dry run
  replaces it, and the run's log keeps each step's counts.

  Each request queues the job of one of the run's AshOban triggers, `:run_dry_run` or
  `:run_import`, on the `migration` queue (`MishkaCmsMigration.Workers.DryRunWorker`,
  `MishkaCmsMigration.Workers.ImportWorker`), as the admin who asked
  (`MishkaCmsMigration.Resources.Changes.EnqueueJob`). A trigger has no
  scheduler: its job is queued by the request alone, and runs only while the run is in the status
  the trigger's `where` names. One run of a site is dry running or importing at a time: the
  `:one_active_per_site` identity is a unique index on the site over those two statuses, so the
  database refuses a second and nothing changes. A job tries three times, an hour each
  (`MishkaCmsMigration.Workers`).

  The job's action walks the source (`MishkaCmsMigration.Workers.Helpers.Pipeline`) and saves its
  `report` (`MishkaCmsMigration.Report`) through `:finish_dry_run` or `:finish_import`, or, for a
  job of picked items (see "Picked items"), `:finish_items`, and how far it is through
  `:record_progress`, whose `progress` each request empties for its new job; after its last
  attempt fails, AshOban runs `:fail`, the triggers' `on_error`, which keeps the reason. Those
  seven are the system's own: every actor is refused them, and only what AshOban runs, and what
  its job runs with its context, passes (`AshOban.Checks.AshObanInteraction`).

  An admin ends a run with `:cancel`, which frees the site for another and clears its secret and
  file: its job, waiting or running, is cancelled (`MishkaCmsMigration.Resources.Changes.CancelJobs`); a job that
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

  Running again, Run again on the same run or a new run of the same host, updates rather than
  duplicates: the items earlier runs wrote (`MishkaCmsMigration.MigrationItem`) are what makes it so.
  `created_count`, `updated_count`, `skipped_count`, `failed_count` and `undecided_count` count the
  items this run's import was the last to touch; a dry run records only each item's plan, which
  they do not count.

  ## Picked items

  An admin may dry run or import some of a run's items alone, from the Items page: Dry run this
  item, Import this item and Import the picked items (`:dry_run_items`, `:import_items`, with the
  ids of the picked `MishkaCmsMigration.MigrationItem`s, at most 100). Either takes a run that is
  waiting, ready, done or failed, moves it to `:dry_running` or `:importing` as its own steps do,
  so the site's one running job and its refusal hold the same way, and queues the job of the same
  trigger, with the items' source ids by kind and the status the run is in as its arguments
  (`MishkaCmsMigration.Resources.Changes.PickedItems`). The job walks those items alone and
  settles them as a whole run would, reading from the source only their rows
  (`c:MishkaCmsMigration.Source.rows/3`) and what they need, such as a post's files; an item whose
  parent, or what its record points at, was not imported waits, it never brings that in
  (`MishkaCmsMigration.Workers.Helpers.Needs`). It then saves what it did into the run's report
  (`MishkaCmsMigration.Report.merge/2`) and puts the run back in the status it was in
  (`:finish_items`), and the items' rows refresh from their broadcasts. Neither is a step of the
  run's log. A source that cannot answer for a picked kind, or cannot be connected to, fails those
  picked items alone, with the reason, and the run still goes back where it was; only an error
  saving the run fails a job of picked items, and its run, as the run's own job does.

  ## The source's secret

  The secret a source signs in with (such as a WordPress application password) is the `:create`
  action's `secret` argument. The New import form types it under the connection's `"secret"` key
  (`c:MishkaCmsMigration.Source.form_fields/0`); `take_secret/2` moves it from there into the
  argument before the run connects, so `connection` never holds it, and a `secret` argument a
  caller gives as well wins. Only its sealed form is kept, in `connection_secret`, sealed the way
  `MishkaCmsCore.Settings` seals a `:secret` setting: `Phoenix.Token.encrypt/4` with the endpoint's
  `secret_key_base`, under a salt of this extension's own. The argument is dropped once sealed. The
  sealed secret is kept from the run's creation until an admin cancels it, and is cleared then: a
  run that is done or failed keeps it, so it can run again; a job opens it with `open_secret/1` each
  time it connects to the source.

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
  commenters' addresses, is never public. The file is deleted once an admin cancels the run
  (`:cancel`), after the run is saved so: a run that is done or failed keeps it, as it keeps its
  secret, so it can run again.

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
  one whose dry run is ready (`:dry_run`), that is Imported (`:done`) or that Failed, both
  `:start_dry_run`, Import on a ready run (`:start_import`, once the admin confirms), and Cancel
  (`:cancel`, once the admin confirms) on any run that is not cancelled. They are `:event` row actions, run by the
  page (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.Index`). Every row also has Items, a link
  to the run's Items page (`items_path/1`, `MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Index`).
  They are drawn by the domain's Tailwind adapter as the Pages table draws its own: an icon, with
  the action's name as its tooltip and accessible name. The Actions column is always as wide as
  the most a row shows, four 30px squares 4px apart with 16px either side (`actions_layout`'s
  `width`), so a row whose status changes its buttons never moves the other columns. A row
  expands to what its last dry run or import found, kind by kind: the kind in words
  (`kind_label/1`), how many items the source listed, what was done with them
  (`result_summary/1`) and why the skipped ones were skipped (`reason_label/1`), and its latest
  items, each with links to its CMS record (`record_paths/2`, `record_links/1`).

  A source's card opens the run's Gervaz form with the card's source as the form's default. Its
  Connection is a `:key_map` whose keys the source names
  (`MishkaCmsMigration.Source.form_fields/1`), read each time the form is drawn and its params are
  read, so each source's New import asks for its own: WordPress's address, user and application
  password, and a plugin's source what its `form_fields/0` names. The secret's key is a masked
  password input that never shows what was typed. The field's description says where WordPress
  makes an application password, as a Gervaz key carries no description of its own. A source that
  reads a file asks for no Connection: the form shows its Export file instead, a dropzone taking
  one `.xml` file of up to 100 MB (see "The source's file"), the reason a file is refused under
  it. The window is Gervaz's `:wizard` of four steps, run by
  `MishkaCmsMigrationWeb.Live.Admin.Dashboard.ImportSteps` (Next checks a step, and Where from
  tries the connection, before it moves on): Where from, then What to bring, a `:key_map` of
  switches, all on but the comments (`bring_choices/1`, the Blog's each only while its target is
  installed), then Languages, a select of the site's languages (`language_choices/1`), whose empty
  choice keeps the source's languages, then the Review. Both are arguments of `:create`, folded
  into the run's `options` with the Advanced options
  (`MishkaCmsMigration.Resources.Changes.Choices`). The Advanced options, a collapsed group of the
  Review, are Choices for this run, a `:key_map` over `options` with a select for the authors, the pages
  and the post addresses, a toggle for confirming the imported users' email, on, and a toggle for
  each of the site's own settings WordPress brings, the title, logo and icon, on; its description
  says how post addresses are kept or redirected. A kind or setting switched off is
  left out as the admin's own leave-out (`left_out?/3`): the first run that meets its items records
  them as Left out by you, and the Items page brings them back. `one_language` puts every item
  with no language of the site's in that language (`one_language/2`). The authors, confirm users,
  post addresses and comments are the Blog's, asked only while the Blog target each is for
  is installed (`run_choices/1`). For
  a master the form asks for the site the content moves to as well (`:master_create`). Its button,
  Start the dry run, creates the run, which connects to the source first, or reads its file
  (`MishkaCmsMigration.Resources.Changes.CheckConnection`): a source that does not answer or
  refuses the user returns the window to Where from with the reason under the connection, and an
  error flash naming the step, and nothing is saved. While it runs the button reads "Checking the
  source…" (its `loading_label`). Gervaz takes a button's label as a string or a function of no
  arguments, so one label fits a connection and a file alike. A run that is not given a `source_host` takes the host its source reads from the
  connection (`c:MishkaCmsMigration.Source.host/1`).
  """

  use Ash.Resource,
    otp_app: :mishka_cms_migration,
    domain: MishkaCmsMigration,
    data_layer: AshPostgres.DataLayer,
    extensions: [GuardedStruct.AshResource, AshOban, MishkaGervaz.Resource],
    notifiers: [Ash.Notifier.PubSub, MishkaCmsMigration.Resources.Notifiers.Steps],
    authorizers: [Ash.Policy.Authorizer]

  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  import Phoenix.Component, only: [sigil_H: 2]
  import MishkaGervaz.UIAdapters.Tailwind, only: [copy_button: 1]

  alias Ash.Error.Changes.InvalidAttribute
  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.Resources.Validations.TenantContext

  alias MishkaCmsMigration.Resources.Changes.{
    CancelJobs,
    CheckConnection,
    EnqueueJob,
    PickedItems,
    Reason,
    SourceFile
  }

  alias MishkaCmsMigration.Resources.Calculations.Decisions
  alias MishkaCmsMigration.Resources.Validations.{Connectable, SiteIdle, SourceInstalled, Status}
  alias MishkaCmsMigration.Workers.Helpers.Pipeline
  alias MishkaCmsMigrationWeb.Live.Admin.Dashboard.ImportSteps
  alias MishkaGervaz.Table.Web.UrlSync

  # Mishka Blog is optional: its pages are linked only for the kinds its targets write.
  @compile {:no_warn_undefined, MishkaBlog.Provision}

  @statuses [:pending, :dry_running, :dry_run, :importing, :done, :failed, :cancelled]
  @endpoint Application.compile_env!(:mishka_cms_core, :endpoint)
  @secret_salt "mishka migration source secret"
  @outcomes MishkaCmsMigration.Report.outcomes()
  @run_choices [
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
        {dgettext_noop("mishka_gervaz", "Keep the WordPress addresses (the dry run says which)"),
         "keep"},
        {dgettext_noop("mishka_gervaz", "/blog/<slug> with 301s"), "blog"},
        {dgettext_noop("mishka_gervaz", "/blog/<slug>, no redirects"), "blog_without_redirects"}
      ]
    ],
    [
      name: :comment_pages,
      type: :toggle,
      label: dgettext_noop("mishka_gervaz", "WordPress breaks comments into pages")
    ],
    [
      name: :comments_per_page,
      type: :number,
      label: dgettext_noop("mishka_gervaz", "Comments a page")
    ],
    [
      name: :posts_page,
      type: :select,
      label: dgettext_noop("mishka_gervaz", "Posts list page"),
      options: [
        {dgettext_noop("mishka_gervaz", "WordPress's posts page"), "source"},
        {dgettext_noop("mishka_gervaz", "The front page /"), "front"},
        {dgettext_noop("mishka_gervaz", "Keep the Blog's /blog"), "blog"}
      ]
    ],
    [
      name: :blog_pages,
      type: :select,
      label: dgettext_noop("mishka_gervaz", "Blog pages"),
      options: [
        {dgettext_noop(
           "mishka_gervaz",
           "Use the site's Blog pages and create any that are missing"
         ), "use"},
        {dgettext_noop("mishka_gervaz", "Create Blog's default pages"), "create"}
      ]
    ],
    [
      name: :confirm_users,
      type: :toggle,
      label: dgettext_noop("mishka_gervaz", "Confirm imported users' email")
    ],
    [
      name: :site_title,
      type: :toggle,
      label: dgettext_noop("mishka_gervaz", "Site title")
    ],
    [
      name: :site_logo,
      type: :toggle,
      label: dgettext_noop("mishka_gervaz", "Site logo")
    ],
    [
      name: :site_icon,
      type: :toggle,
      label: dgettext_noop("mishka_gervaz", "Site icon (favicon)")
    ]
  ]
  @bring_choices [
    [name: :bring_posts, type: :toggle, label: dgettext_noop("mishka_gervaz", "Posts")],
    [name: :bring_pages, type: :toggle, label: dgettext_noop("mishka_gervaz", "Pages")],
    [
      name: :bring_media,
      type: :toggle,
      label: dgettext_noop("mishka_gervaz", "Pictures and files")
    ],
    [
      name: :bring_terms,
      type: :toggle,
      label: dgettext_noop("mishka_gervaz", "Categories and tags")
    ],
    [
      name: :bring_users,
      type: :toggle,
      label: dgettext_noop("mishka_gervaz", "Authors and users")
    ],
    [name: :bring_menus, type: :toggle, label: dgettext_noop("mishka_gervaz", "Menus")],
    [name: :comments, type: :toggle, label: dgettext_noop("mishka_gervaz", "Comments")]
  ]

  @choice_kinds %{
    authors: "user",
    confirm_users: "user",
    post_address: "post_redirect",
    comment_pages: "post_redirect",
    comments_per_page: "post_redirect",
    posts_page: "post",
    blog_pages: "post",
    comments: "comment",
    bring_posts: "post",
    bring_terms: "category",
    bring_users: "user",
    site_title: "setting",
    site_logo: "setting",
    site_icon: "setting"
  }
  @brought_kinds %{
    "user" => :bring_users,
    "category" => :bring_terms,
    "tag" => :bring_terms,
    "media" => :bring_media,
    "page" => :bring_pages,
    "post" => :bring_posts,
    "menu" => :bring_menus
  }
  @site_settings %{"title" => :site_title, "logo" => :site_logo, "icon" => :site_icon}
  @blog_pages %{"post" => :post, "category" => :category, "tag" => :tag, "user" => :author}
  @counts Enum.map(@outcomes, &{&1, [type: :integer, allow_nil?: false]})
  @pick_site dgettext_noop("errors", "Pick a site.")
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
        default: "keep",
        derives: "sanitize(trim) validate(enum=String[keep::blog::blog_without_redirects])"

      field :posts_page, :string,
        default: "source",
        validator: {MishkaCmsMigration.MigrationRun, :posts_page},
        derives: "sanitize(trim) validate(string, not_empty, max_len=36)"

      field :blog_pages, :string,
        default: "use",
        derives: "sanitize(trim) validate(enum=String[use::create])"

      field :confirm_users, :boolean,
        default: true,
        validator: {MishkaCmsMigration.MigrationRun, :switch},
        derives: "validate(boolean)"

      field :comments, :boolean,
        default: false,
        validator: {MishkaCmsMigration.MigrationRun, :switch},
        derives: "validate(boolean)"

      field :comment_pages, :boolean,
        default: false,
        validator: {MishkaCmsMigration.MigrationRun, :switch},
        derives: "validate(boolean)"

      field :comments_per_page, :integer,
        default: 50,
        derives: "sanitize(string_integer) validate(integer, min_len=1, max_len=1000)"

      for key <- ~w(bring_users bring_terms bring_media bring_pages bring_posts bring_menus
                    site_title site_logo site_icon)a do
        field key, :boolean,
          default: true,
          validator: {MishkaCmsMigration.MigrationRun, :switch},
          derives: "validate(boolean)"
      end

      field :one_language, :string,
        default: nil,
        derives: "sanitize(trim) validate(string, max_len=16)"
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
          always [:site, :decisions]
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
          requires [:status, :source, :report, :progress, :decisions]
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
          width "minmax(164px,max-content)"
        end

        action :expand, type: :accordion

        action :items do
          type :link
          path &MishkaCmsMigration.MigrationRun.items_path/1

          ui do
            label fn -> dgettext("mishka_gervaz", "Items") end
            icon "hero-list-bullet"
          end
        end

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

          visible fn record, _state ->
            record.status in [:dry_run, :done, :failed] and
              MishkaCmsMigration.MigrationRun.connectable?(record)
          end

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

          visible fn record, _state -> record.status != :cancelled end

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

        field :bring, :key_map do
          virtual true

          default %{
            "bring_posts" => true,
            "bring_pages" => true,
            "bring_media" => true,
            "bring_terms" => true,
            "bring_users" => true,
            "bring_menus" => true,
            "comments" => false
          }

          options fn state -> MishkaCmsMigration.MigrationRun.bring_choices(state) end

          ui do
            label fn -> dgettext("mishka_gervaz", "What to bring") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Switch off what you do not want: it is listed as Left out by you, and you can bring it back on the Items page. Comments are off by default: a comment by a user of the site is written as theirs, and a guest's with the name and email the guest gave."
              )
            end
          end
        end

        field :language, :select do
          virtual true
          options fn state -> MishkaCmsMigration.MigrationRun.language_choices(state) end

          ui do
            label fn -> dgettext("mishka_gervaz", "Import everything in one language") end
            placeholder fn -> dgettext("mishka_gervaz", "Keep the source's languages") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Import everything in one language, and translate or edit it later. Items the source gives in one of your site's languages keep it. The list is the languages under Settings → Languages; a language missing there answers 404, so add it first."
              )
            end
          end
        end

        field :options, :key_map do
          default %{
            "authors" => "connect",
            "pages" => "draft",
            "post_address" => "keep",
            "comments_per_page" => 50,
            "posts_page" => "source",
            "blog_pages" => "use"
          }

          options fn state -> MishkaCmsMigration.MigrationRun.run_choices(state) end

          ui do
            label fn -> dgettext("mishka_gervaz", "Choices for this run") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Authors: each post's author is matched to a user of your site by email; the rest are skipped, or created as new users. Confirm imported users' email: on, a user created this way counts as having confirmed their email; off, you confirm them later from the Users page. No email is sent either way. Pages: drafts you publish yourself, or live at their old addresses. Post addresses: kept as WordPress had them, where the dry run names the structure it found, or moved to /blog/<slug>; every old address the site does not serve as it was is sent on with a 301 redirect. WordPress breaks comments into pages: on, when Settings, Discussion breaks a post's comments into pages there, each page's address (/comment-page-2/) is sent to its post with a 301; Comments a page is the number WordPress shows a page, 50 unless you changed it. Posts list page: where the list of posts is served, WordPress's posts page, the front page, the address of one of your pages (that page is archived), or /blog. Blog pages: your site's Blog pages, with any missing ones created where the run serves posts, or the Blog's default /blog pages, which your old addresses reach through 301s. Site title, logo and icon: the WordPress site's own; one switched off is left out, and you can bring it back on the run's Items page."
              )
            end
          end
        end
      end

      groups do
        group :connection do
          fields [:site_id, :connection, :file]

          ui do
            label fn -> dgettext("mishka_gervaz", "1 of 4: Where from") end
            columns 1
          end
        end

        group :bring do
          fields [:bring]

          ui do
            label fn -> dgettext("mishka_gervaz", "2 of 4: What to bring") end
            columns 1
          end
        end

        group :language do
          fields [:language]

          ui do
            label fn -> dgettext("mishka_gervaz", "3 of 4: Languages") end
            columns 1
          end
        end

        group :options do
          fields [:options]
          collapsed true

          ui do
            label fn -> dgettext("mishka_gervaz", "Advanced options") end
            columns 1
          end
        end
      end

      layout do
        mode :wizard

        step :from do
          groups [:connection]

          ui do
            label fn -> dgettext("mishka_gervaz", "Where from") end
          end
        end

        step :bring do
          groups [:bring]

          ui do
            label fn -> dgettext("mishka_gervaz", "What to bring") end
          end
        end

        step :language do
          groups [:language]

          ui do
            label fn -> dgettext("mishka_gervaz", "Languages") end
          end
        end

        step :review do
          groups [:options]
          summary true

          ui do
            label fn -> dgettext("mishka_gervaz", "Review") end
          end
        end

        notice :start_over do
          position :form_top
          visible fn state -> state.dirty? end

          render fn _assigns, state ->
            ImportSteps.start_over(%{id: state.static.id, __changed__: nil})
          end
        end

        notice :review do
          position {:before_group, :options}
          render fn _assigns, state -> ImportSteps.review(%{state: state, __changed__: nil}) end
        end
      end

      events do
        step ImportSteps
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
        create label: fn -> dgettext("mishka_gervaz", "Start the dry run") end,
               loading_label: fn -> dgettext("mishka_gervaz", "Checking the source…") end

        cancel active: false
        position :bottom
      end

      presentation do
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Admin
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

      argument :bring, :map do
        allow_nil? true
        description "The switches of what the run brings, folded into its options"
      end

      argument :language, :string do
        allow_nil? true
        description "The one language every item of an unknown or unpublished language is put in"
      end

      validate {TenantContext, require_master: false}
      change MishkaCmsMigration.Resources.Changes.Choices
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

      argument :bring, :map do
        allow_nil? true
        description "The switches of what the run brings, folded into its options"
      end

      argument :language, :string do
        allow_nil? true
        description "The one language every item of an unknown or unpublished language is put in"
      end

      validate {TenantContext, require_master: true}
      validate present(:site_id), message: @pick_site
      change MishkaCmsMigration.Resources.Changes.Choices
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
      validate {Status, from: [:pending, :dry_run, :done, :failed]}
      validate Connectable

      change set_attribute(:status, :dry_running)
      change set_attribute(:progress, nil)
      change set_attribute(:finished_at, nil)
      change set_attribute(:reason, nil)
      change {EnqueueJob, trigger: :run_dry_run}

      description "Queues a dry run, a first one or Run again: what an import would create, update and skip, writing nothing"
    end

    update :dry_run_items do
      accept []

      argument :items, {:array, :uuid} do
        allow_nil? false
        constraints min_length: 1, max_length: 100
        description "The ids of the picked items, items of the run's site and source host"
      end

      validate {TenantContext, require_master: false}
      validate {Status, from: [:pending, :dry_run, :done, :failed], as_read: true}
      validate Connectable

      change set_attribute(:status, :dry_running)
      change set_attribute(:progress, nil)
      change PickedItems
      change {EnqueueJob, trigger: :run_dry_run}

      description "Queues a dry run of the picked items alone, which puts the run back where it was"
    end

    update :import_items do
      accept []

      argument :items, {:array, :uuid} do
        allow_nil? false
        constraints min_length: 1, max_length: 100
        description "The ids of the picked items, items of the run's site and source host"
      end

      validate {TenantContext, require_master: false}
      validate {Status, from: [:pending, :dry_run, :done, :failed], as_read: true}
      validate Connectable

      change set_attribute(:status, :importing)
      change set_attribute(:progress, nil)
      change PickedItems
      change {EnqueueJob, trigger: :run_import}

      description "Queues the import of the picked items alone, which puts the run back where it was"
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

      argument :items, :map do
        allow_nil? true
        description "The picked items' source ids by kind, for a job of picked items; nil for all"
      end

      argument :back_to, :atom do
        allow_nil? true
        constraints one_of: [:pending, :dry_run, :done, :failed]
        description "The status a job of picked items puts the run back in"
      end

      validate {Status, from: [:dry_running]}

      manual {Pipeline, mode: :dry_run}

      description "System-internal: the dry run's job walks the source and saves the report"
    end

    update :run_import do
      accept []
      transaction? false
      require_atomic? false

      argument :items, :map do
        allow_nil? true
        description "The picked items' source ids by kind, for a job of picked items; nil for all"
      end

      argument :back_to, :atom do
        allow_nil? true
        constraints one_of: [:pending, :dry_run, :done, :failed]
        description "The status a job of picked items puts the run back in"
      end

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

      description "System-internal: saves the import's report"
    end

    update :finish_items do
      accept [:report]

      argument :status, :atom do
        allow_nil? false
        constraints one_of: [:pending, :dry_run, :done, :failed]
        description "The status the run was in before the job of picked items"
      end

      validate {Status, from: [:dry_running, :importing]}

      change set_attribute(:status, arg(:status))

      description "System-internal: saves the report a job of picked items merged and puts the run back"
    end

    update :refresh_decisions do
      accept []
      change atomic_update(:updated_at, expr(now()))

      validate {TenantContext, require_master: false}

      description "Tells the runs of a source host that its items' decisions changed, so the Runs table draws their Result again"
    end

    update :cancel do
      accept []

      validate {TenantContext, require_master: false}
      validate {Status, from: [:pending, :dry_running, :dry_run, :importing, :done, :failed]}

      change set_attribute(:status, :cancelled)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change set_attribute(:connection_secret, nil)
      change {SourceFile, step: :drop}
      change CancelJobs

      description "Ends a run: its job is cancelled, its secret and file cleared, and it cannot run again"
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
             :finish_items,
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

      description "The source's secret, sealed (open_secret/1); cleared once an admin cancels the run"
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
                    duplicates: [
                      type: :map,
                      allow_nil?: true,
                      constraints: [
                        fields: [
                          found: [type: :integer, allow_nil?: false],
                          merged: [type: :integer, allow_nil?: false],
                          kept: [type: :integer, allow_nil?: false]
                        ]
                      ]
                    ],
                    guests: [type: :integer, allow_nil?: true],
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
      description "The items this run's import was the last to touch"
    end
  end

  calculations do
    calculate :decisions, :map, Decisions do
      public? true

      description "What waits for a decision now and what an admin decided among the items of the run's source host"
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

    count :undecided_count, :items do
      public? true
      filter expr(outcome == :undecided)
    end
  end

  identities do
    identity :one_active_per_site, [:site_id],
      where: expr(status in [:dry_running, :importing]),
      message: @busy
  end

  @doc """
  The run `id` as `user` may read it: a master's on any site, a site admin's on their own site
  alone, with what `opts[:load]` names loaded. `{:ok, nil}` for a run that is not there or that
  `user` may not read.
  """
  @spec fetch(String.t(), map(), keyword()) :: {:ok, struct() | nil} | {:error, term()}
  def fetch(id, user, opts \\ [])

  def fetch(id, %{site_id: nil} = user, opts),
    do:
      Ash.get(__MODULE__, id,
        action: :master_get,
        actor: user,
        not_found_error?: false,
        load: opts[:load] || []
      )

  def fetch(id, %{site_id: site_id} = user, opts),
    do:
      MishkaCmsMigration.get_run(id,
        actor: user,
        tenant: site_id,
        not_found_error?: false,
        load: opts[:load] || []
      )

  def fetch(_id, _no_user, _opts), do: {:ok, nil}

  @doc """
  Whether `run` still holds what its source connects with, so a job can connect again: the file it
  was handed, still in its folder, for a source that reads one (`MishkaCmsMigration.Source.file?/1`),
  and otherwise its sealed secret when its source's form asks for one as required
  (`MishkaCmsMigration.Source.form_fields/1`). A run an earlier release ended, which cleared its
  secret and deleted its file, and a cancelled one hold neither: Run again and the jobs of picked
  items are neither offered nor taken on them
  (`MishkaCmsMigration.Resources.Validations.Connectable`), and a New import asks for them again.
  Read from the run alone, with no query; a file is looked for on disk.
  """
  @spec connectable?(map()) :: boolean()
  def connectable?(%{source: source} = run),
    do: source |> MishkaCmsMigration.Source.file?() |> holds?(run)

  defp holds?(true, %{connection: %{"file" => path}}) when is_binary(path),
    do: File.regular?(path)

  defp holds?(true, _no_file), do: false

  defp holds?(false, %{source: source, connection_secret: sealed}),
    do:
      is_binary(sealed) or
        not Enum.any?(MishkaCmsMigration.Source.form_fields(source), &required_secret?/1)

  defp required_secret?(field), do: field[:name] == :secret and field[:required] == true

  @doc """
  Whether `error`, what a step of a run or an admin's choice on an item answered, refuses it only
  because a dry run or an import of the site is running now: the run's own
  (`MishkaCmsMigration.Resources.Validations.Status.running?/1`), another run of its site
  (`:one_active_per_site`), or any while an item is changed
  (`MishkaCmsMigration.Resources.Validations.SiteIdle.running?/1`). Nothing is wrong with what
  was asked, and the same request holds once that job is done, so the Items page says it as a
  notice, not as a failure. An error that also holds anything else is not.
  """
  @spec refused_while_running?(term()) :: boolean()
  def refused_while_running?(%{errors: [_ | _] = errors}),
    do: Enum.all?(errors, &refused_while_running?/1)

  def refused_while_running?(%InvalidAttribute{field: :site_id, message: @busy}), do: true

  def refused_while_running?(error),
    do: Status.running?(error) or SiteIdle.running?(error)

  @doc """
  What a cancelled run's alert says: that `:cancel` deleted what the run connected with, the export
  file when `file_source?` (`MishkaCmsMigration.Source.file?/1`), else the WordPress password, and
  that a New import brings the content again. The Items page's table shows it only for a cancelled
  run (`MigrationItem`'s `:cancelled_run` notice).
  """
  @spec cancelled_words(boolean()) :: String.t()
  def cancelled_words(true),
    do:
      dgettext(
        "mishka_gervaz",
        "This run was cancelled. Its export file was deleted, so it cannot run again. Start a New import to bring content again."
      )

  def cancelled_words(false),
    do:
      dgettext(
        "mishka_gervaz",
        "This run was cancelled. Its WordPress password was deleted, so it cannot run again. Start a New import to bring content again."
      )

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
  What a run's `report` counts, in one line:
  `"3 created · 1 updated · 2 skipped · 0 failed · 0 need your decision"`, or `"—"` before its
  first dry run.
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

  @doc """
  `result_outcomes/1` of `run`'s report, its count of what needs a decision being what waits for
  one now among the items of its source host (its `decisions` calculation, when loaded), as the
  Items page's Decisions panel counts it: so the run's Result chips and its details say the
  panel's number, 0 once the admin decided everything, not the number its report counted.
  """
  @spec outcomes_now(map()) :: [{atom(), non_neg_integer()}]
  def outcomes_now(%{report: report} = run),
    do:
      for(
        {outcome, count} <- result_outcomes(report),
        do: {outcome, waiting_now(outcome, count, decisions(run))}
      )

  @doc """
  One outcome's count in words, as a Result pill's tooltip begins: `"3 created"`, or
  `"2 need your decision"`.
  """
  @spec outcome_count(atom(), non_neg_integer()) :: String.t()
  def outcome_count(:undecided, count),
    do:
      dngettext(
        "mishka_gervaz",
        "%{number} needs your decision",
        "%{number} need your decision",
        count,
        number: MishkaCmsCore.Localized.number(count)
      )

  def outcome_count(outcome, count),
    do: "#{MishkaCmsCore.Localized.number(count)} #{outcome_label(outcome)}"

  @doc """
  The pill colours of an outcome's count: green created, blue updated, grey skipped, red failed,
  amber waiting for a decision.
  """
  @spec outcome_class(atom()) :: String.t()
  def outcome_class(:created), do: "bg-[#e6f6ee] text-[#177a53]"
  def outcome_class(:updated), do: "bg-[#eaf1fb] text-[#3a6cb5]"
  def outcome_class(:skipped), do: "bg-[#f2f1ec] text-[#8a877f]"
  def outcome_class(:failed), do: "bg-[#fdecea] text-[#c0473d]"
  def outcome_class(:undecided), do: "bg-[#fff6e0] text-[#8a5a00]"

  @doc """
  The heroicon of an outcome's pill: a plus created, arrows updated, a minus skipped, a warning
  failed, a raised hand waiting for a decision.
  """
  @spec outcome_icon(atom()) :: String.t()
  def outcome_icon(:created), do: "hero-plus"
  def outcome_icon(:updated), do: "hero-arrow-path"
  def outcome_icon(:skipped), do: "hero-minus"
  def outcome_icon(:failed), do: "hero-exclamation-triangle"
  def outcome_icon(:undecided), do: "hero-hand-raised"

  @doc """
  The heroicon that stands for the items of `kind` in the admin's lists, such as
  `"hero-document-text"` for `"post"`; a kind this extension does not name is a cube.
  """
  @spec kind_icon(String.t()) :: String.t()
  def kind_icon("user"), do: "hero-user"
  def kind_icon("category"), do: "hero-folder"
  def kind_icon("tag"), do: "hero-tag"
  def kind_icon("media"), do: "hero-photo"
  def kind_icon("setting"), do: "hero-cog-6-tooth"
  def kind_icon("stylesheet"), do: "hero-swatch"
  def kind_icon("page"), do: "hero-document"
  def kind_icon("post"), do: "hero-document-text"
  def kind_icon("comment"), do: "hero-chat-bubble-left-right"
  def kind_icon("post_redirect"), do: "hero-arrows-right-left"
  def kind_icon("menu"), do: "hero-bars-3"
  def kind_icon(_other), do: "hero-cube"

  @doc """
  Tells the runs of `run`'s source host on its site, as `user`, that the decisions on their items
  changed (`:refresh_decisions`): one `UPDATE` of those runs, whose broadcast makes the Runs table
  draw their Result chips again, with what waits for a decision and what was decided now
  (`decisions` calculation). `:ok` also when no run could be told.
  """
  @spec refresh_decisions(map(), map()) :: :ok
  def refresh_decisions(%{source_host: host, site_id: site_id}, user) do
    __MODULE__
    |> Ash.Query.filter(source_host == ^host)
    |> Ash.bulk_update(:refresh_decisions, %{},
      actor: user,
      tenant: site_id,
      strategy: :atomic,
      notify?: true,
      return_records?: true,
      return_errors?: true,
      load: [:decisions]
    )

    :ok
  end

  @doc """
  The Runs table's Result cell for `run`, drawn in the width its column gives it: its pills and
  chips wrap onto more lines rather than widen the column.

    * While the run is dry running or importing, how far its job is (`progress`): the kind it
      walks, with its icon, the items met so far, of how many the run's last report
      counted when it has one, and a thin bar of that share. Without a report the bar fills by the
      kinds of the source walked so far. Before the job's first page it reads Starting.
    * Otherwise, what its last report counted: a pill for each outcome counted more than none of,
      in `MishkaCmsMigration.Report.outcomes/0` order (green created, blue updated, grey skipped,
      red failed, amber waiting for a decision), each an icon and its count, its tooltip the count
      in words and, for skipped, failed or undecided items, the reason most of them share
      (`reason_label/1`). Under them a grey chip for
      each kind it met, the kind's icon (`kind_icon/1`) and how many the source listed, its
      tooltip the kind in words (`kind_label/1`). "Nothing to move" when it counted nothing, and "—" before the first
      dry run.

  The waiting pill counts what waits for a decision now (`decisions`), not what the dry run
  counted, so it reads 0 once the admin decided everything; a Decided chip (`hero-check`) beside it
  counts the items whose waiting decision the admin answered, and is not drawn while there are none.

  The data the page's tests read: `data-role="run-result"` on the cell, `"run-progress"` (with
  `data-kind`, `data-done` and `data-total`), `"run-outcome"` (`data-outcome`, `data-count` and
  `data-reason`, the shared reason as the report keeps it), `"run-decided"` (`data-count`) and
  `"run-kind"` (`data-kind`, `data-count`). The bar's width is one of the admin sheet's `w-[N%]` classes (0 to 100), so it
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
      <div :if={@decided} class="flex flex-wrap gap-[4px]">
        <span
          data-role="run-decided"
          data-count={@decided.count}
          title={@decided.title}
          class="inline-flex items-center gap-[3px] rounded-[20px] bg-[#eeedfb] px-[6px] py-[2px] text-[10px] font-bold whitespace-nowrap text-[#5b57d6]"
        >
          <MishkaCmsCore.CoreComponents.icon name="hero-check" class="size-[10px] flex-none" />
          {@decided.number}<span class="sr-only">{"\u00a0" <> @decided.label}</span>
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
    do: %{progress: progress(run), outcomes: [], decided: nil, kinds: [], note: nil}

  defp result(%{report: %{kinds: kinds} = report} = run) do
    decisions = decisions(run)

    outcomes =
      for {outcome, count} <- outcomes_now(run),
          do: outcome_pill(outcome, count, shared_reason(report, outcome, count))

    chips =
      for %{kind: kind} = kind_counts <- kinds,
          count = items(kind_counts),
          count > 0,
          do: kind_chip(kind, count)

    %{
      progress: nil,
      outcomes: outcomes,
      decided: decided_chip(decisions),
      kinds: chips,
      note: nothing_to_move(outcomes)
    }
  end

  defp result(_no_report),
    do: %{progress: nil, outcomes: [], decided: nil, kinds: [], note: "—"}

  defp decisions(%{decisions: %{waiting: _waiting, decided: _decided} = decisions}),
    do: decisions

  defp decisions(_not_loaded), do: nil

  defp waiting_now(:undecided, _reported, %{waiting: waiting}), do: waiting
  defp waiting_now(_outcome, count, _decisions), do: count

  defp decided_chip(%{decided: decided}) when decided > 0 do
    number = MishkaCmsCore.Localized.number(decided)

    %{
      count: decided,
      number: number,
      label: dgettext("mishka_gervaz", "decided"),
      title: dgettext("mishka_gervaz", "%{number} decided by you", number: number)
    }
  end

  defp decided_chip(_none), do: nil

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

  defp shared_reason(_report, :undecided, 0), do: nil
  defp shared_reason(report, outcome, _count), do: shared_reason(report, outcome)

  defp shared_reason(%{entries: entries}, outcome)
       when outcome in [:skipped, :failed, :undecided] do
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
  defp outcome_label(:undecided), do: dgettext("mishka_gervaz", "need your decision")

  defp kind_noun("user"), do: dgettext("mishka_gervaz", "users")
  defp kind_noun("category"), do: dgettext("mishka_gervaz", "categories")
  defp kind_noun("tag"), do: dgettext("mishka_gervaz", "tags")
  defp kind_noun("media"), do: dgettext("mishka_gervaz", "files")
  defp kind_noun("setting"), do: dgettext("mishka_gervaz", "settings")
  defp kind_noun("stylesheet"), do: dgettext("mishka_gervaz", "stylesheets")
  defp kind_noun("page"), do: dgettext("mishka_gervaz", "pages")
  defp kind_noun("post"), do: dgettext("mishka_gervaz", "posts")
  defp kind_noun("comment"), do: dgettext("mishka_gervaz", "comments")
  defp kind_noun("post_redirect"), do: dgettext("mishka_gervaz", "redirects")
  defp kind_noun("menu"), do: dgettext("mishka_gervaz", "menus")
  defp kind_noun(kind), do: kind

  @doc "One item of `kind`, as a sentence names it, such as page or category."
  @spec kind_one(String.t()) :: String.t()
  def kind_one("user"), do: dgettext("mishka_gervaz", "user")
  def kind_one("category"), do: dgettext("mishka_gervaz", "category")
  def kind_one("tag"), do: dgettext("mishka_gervaz", "tag")
  def kind_one("media"), do: dgettext("mishka_gervaz", "file")
  def kind_one("setting"), do: dgettext("mishka_gervaz", "setting")
  def kind_one("stylesheet"), do: dgettext("mishka_gervaz", "stylesheet")
  def kind_one("page"), do: dgettext("mishka_gervaz", "page")
  def kind_one("post"), do: dgettext("mishka_gervaz", "post")
  def kind_one("comment"), do: dgettext("mishka_gervaz", "comment")
  def kind_one("post_redirect"), do: dgettext("mishka_gervaz", "redirect")
  def kind_one("menu"), do: dgettext("mishka_gervaz", "menu")
  def kind_one(kind), do: kind

  @doc false
  def switch(field, "true"), do: {:ok, field, true}
  def switch(field, "false"), do: {:ok, field, false}
  def switch(field, value), do: {:ok, field, value}

  @doc """
  The items of `kind` as the admin reads them, such as `"Posts"` for `"post"`. A kind this
  extension does not name, one a source plugin of its own lists, reads as itself, capitalized.
  """
  @spec kind_label(String.t()) :: String.t()
  def kind_label("user"), do: dgettext("mishka_gervaz", "Users")
  def kind_label("category"), do: dgettext("mishka_gervaz", "Categories")
  def kind_label("tag"), do: dgettext("mishka_gervaz", "Tags")
  def kind_label("media"), do: dgettext("mishka_gervaz", "Media")
  def kind_label("setting"), do: dgettext("mishka_gervaz", "Settings")
  def kind_label("stylesheet"), do: dgettext("mishka_gervaz", "Stylesheets")
  def kind_label("page"), do: dgettext("mishka_gervaz", "Pages")
  def kind_label("post"), do: dgettext("mishka_gervaz", "Posts")
  def kind_label("comment"), do: dgettext("mishka_gervaz", "Comments")
  def kind_label("post_redirect"), do: dgettext("mishka_gervaz", "Redirects")
  def kind_label("menu"), do: dgettext("mishka_gervaz", "Menus")
  def kind_label(kind), do: String.capitalize(kind)

  @doc """
  Every kind the installed sources list, as `{label, kind}` pairs in the order the sources walk
  them (`kind_label/1`).
  """
  @spec kind_options() :: [{String.t(), String.t()}]
  def kind_options,
    do:
      MishkaCmsMigration.Source.all()
      |> Enum.flat_map(& &1.kinds())
      |> Enum.uniq()
      |> Enum.map(&{kind_label(&1), &1})

  @doc """
  The New import form's choices for the run (Choices for this run's keys): the authors, pages and
  post addresses selects and the confirm users and comments toggles, each Blog one only while the
  Blog target it is for is installed (`MishkaCmsMigration.Target.fetch/1`): Authors and Confirm
  imported users' email for `"user"`, Post addresses for
  `"post_redirect"`, Posts list page and Blog pages for `"post"` and the comments for `"comment"`. A node without the Blog asks for the pages
  alone.
  """
  @spec run_choices(map()) :: [keyword()]
  def run_choices(state),
    do:
      for(
        choice <- @run_choices,
        offered?(@choice_kinds[choice[:name]]),
        do: with_pages(choice, state)
      )

  defp with_pages(choice, state) do
    case choice[:name] do
      :posts_page -> Keyword.update!(choice, :options, &(&1 ++ page_choices(window_site(state))))
      _other -> choice
    end
  end

  # THE SITE'S OWN PAGES THE POSTS LIST MAY TAKE THE ADDRESS OF: those at a plain address, read in one
  # query, as the form is drawn.
  defp page_choices(site_id) when is_binary(site_id) do
    MishkaCmsCore.Runtime.Page
    |> Ash.Query.filter(not contains(path, ":") and not contains(path, "*"))
    |> Ash.Query.select([:id, :title, :path])
    |> Ash.Query.sort(path: :asc)
    |> Ash.Query.limit(200)
    |> Ash.read!(tenant: site_id, authorize?: false)
    |> Enum.map(&{dgettext("mishka_gervaz", "The address of %{page}", page: &1.path), &1.id})
  end

  defp page_choices(_no_site), do: []

  @doc """
  Checks a run's `posts_page` choice: `"source"`, `"front"`, `"blog"`, or the id of one of the
  site's pages (`run_choices/1`).
  """
  @spec posts_page(atom(), term()) :: {:ok, atom(), String.t()} | {:error, atom(), String.t()}
  def posts_page(field, value) when value in ["source", "front", "blog"], do: {:ok, field, value}

  def posts_page(field, value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, field, id}
      :error -> {:error, field, dgettext("errors", "Pick where the posts list goes.")}
    end
  end

  def posts_page(field, _value),
    do: {:error, field, dgettext("errors", "Pick where the posts list goes.")}

  @doc """
  The New import window's "What to bring" switches: posts, pages, pictures and files, categories
  and tags, authors and users, menus and comments, each only while the target it is for is
  installed (`MishkaCmsMigration.Target.fetch/1`), as `run_choices/1` offers its own.
  """
  @spec bring_choices(map()) :: [keyword()]
  def bring_choices(_state), do: Enum.filter(@bring_choices, &offered?(@choice_kinds[&1[:name]]))

  @doc """
  The New import window's Languages select: the languages of the site the run is for, its main
  language first (`MishkaCmsCore.Runtime.Languages.site/1`), each as `{name, code}`. Its empty
  choice keeps the source's languages. The site is the signed-in admin's, or, for a master, the one
  picked in the form. It reads the site's languages from the runtime settings, no query.
  """
  @spec language_choices(map()) :: [{String.t(), String.t()}]
  def language_choices(state),
    do: for(code <- state |> window_site() |> Languages.site(), do: {language_name(code), code})

  defp window_site(%{form: %{params: %{"site_id" => site_id}}}) when site_id not in [nil, ""],
    do: site_id

  defp window_site(%{current_user: %{site_id: site_id}}), do: site_id
  defp window_site(_state), do: nil

  defp offered?(nil), do: true
  defp offered?(kind), do: match?({:ok, _target}, MishkaCmsMigration.Target.fetch(kind))

  @doc """
  Whether the run's choices (`options`, as `MishkaCmsMigration.MigrationRun.Options`) leave the item
  of `kind` and `source_id` out: the kinds switched off in the New import window (`bring_users`,
  `bring_terms`, `bring_media`, `bring_pages`, `bring_posts`, `bring_menus`) and the site settings
  switched off in its Advanced options (`site_title`, `site_logo`, `site_icon`). The Workers decide
  it for an item no run has met; the admin's own leave-out and Bring back stay what they chose.
  """
  @spec left_out?(struct(), String.t(), String.t()) :: boolean()
  def left_out?(options, "setting", source_id),
    do: Map.get(options, Map.get(@site_settings, source_id)) == false

  def left_out?(options, kind, _source_id),
    do: Map.get(options, Map.get(@brought_kinds, kind)) == false

  @doc """
  The language code the run puts every item of an unknown language, or of one the site does not
  publish in, in (`one_language` of its options), or `nil` when the run keeps the source's
  languages or the code is not one of the site's (`MishkaCmsCore.Runtime.Languages.site/1`).
  """
  @spec one_language(struct() | map() | nil, String.t() | nil) :: String.t() | nil
  def one_language(%{one_language: code}, site_id), do: published(code, site_id)
  def one_language(%{"one_language" => code}, site_id), do: published(code, site_id)
  def one_language(_options, _site_id), do: nil

  defp published(code, site_id) when is_binary(code) and code != "",
    do: if(code in Languages.site(site_id), do: code)

  defp published(_none, _site_id), do: nil

  @doc """
  What the Items page says in one line for a run that put every item of an unknown or unpublished
  language in `language` (`one_language/2`): the items it covers keep that language, and they can
  be translated or edited later.
  """
  @spec one_language_words(String.t()) :: String.t()
  def one_language_words(language),
    do:
      dgettext(
        "mishka_gervaz",
        "This run puts every item with no language of your site in %{language}. Translate or edit them later.",
        language: language_name(language)
      )

  @doc "Every outcome as a `{word, outcome}` pair, in the order the report counts them."
  @spec outcome_options() :: [{String.t(), atom()}]
  def outcome_options, do: Enum.map(@outcomes, &{outcome_word(&1), &1})

  @doc "An outcome as its pill reads it, such as Created or Failed."
  @spec outcome_word(atom()) :: String.t()
  def outcome_word(:created), do: dgettext("mishka_gervaz", "Created")
  def outcome_word(:updated), do: dgettext("mishka_gervaz", "Updated")
  def outcome_word(:skipped), do: dgettext("mishka_gervaz", "Skipped")
  def outcome_word(:failed), do: dgettext("mishka_gervaz", "Failed")
  def outcome_word(:undecided), do: dgettext("mishka_gervaz", "Needs your decision")

  @doc "The admin address of the page that lists the items of `run`'s source on its site."
  @spec items_path(%{id: String.t()}) :: String.t()
  def items_path(%{id: id}), do: "/admin/dashboard/migration/runs/#{id}/items"

  @doc """
  Where the CMS record an item of `kind` was written to is, given `record` as its target's resource
  reads it: `%{admin: path, public: path | nil}`, or `nil` for a kind this extension names no pages
  for, such as one a source plugin lists.

  The admin has no address for one record: its pages edit in a modal over a list. `admin` is the
  record's list opened on the record, the way the list's own search writes its address
  (`MishkaGervaz.Table.Web.UrlSync`): a post, category, tag or blogger by its slug, a page by its
  path, a file by its name, a redirect by its old address, a comment on the list of its post's
  comments, a setting on the Settings page's tab of its category, a stylesheet on the Stylesheets
  page, and a menu on the layout it is the header's links of. `public` is the record's page on the
  site where it is live (`record_address/2`): a published post, an active category, a tag, a
  blogger's page, an active page and a file; a comment, a redirect, a setting, a stylesheet and a
  menu have none.
  """
  @spec record_paths(String.t(), struct()) :: %{admin: String.t(), public: String.t() | nil} | nil
  def record_paths("post", post),
    do: %{
      admin: listed("/admin/dashboard/blog/posts", post, %{search: post.slug}),
      public: live(post.status == :published, "post", post)
    }

  def record_paths("category", category),
    do: %{
      admin: listed("/admin/dashboard/blog/collections", category, %{search: category.slug}),
      public: live(category.status == :active, "category", category)
    }

  def record_paths("tag", tag),
    do: %{
      admin: listed("/admin/dashboard/blog/tags", tag, %{search: tag.slug}),
      public: live(true, "tag", tag)
    }

  def record_paths("user", blogger),
    do: %{
      admin: listed("/admin/dashboard/blog/bloggers", blogger, %{search: blogger.slug}),
      public: live(true, "user", blogger)
    }

  def record_paths("comment", comment),
    do: %{
      admin: listed("/admin/dashboard/blog/comments", comment, %{post_id: comment.post_id}),
      public: nil
    }

  def record_paths("page", page),
    do: %{
      admin: listed("/admin/dashboard/runtime/pages", page, %{search: page.path}),
      public: live(page.active, "page", page)
    }

  def record_paths("media", media),
    do: %{
      admin: listed("/admin/dashboard/runtime/medias", media, %{search: media.name}),
      public: media.relative_path
    }

  def record_paths("setting", setting),
    do: %{
      admin: "/admin/dashboard/settings?tab=" <> URI.encode_www_form(setting.category),
      public: nil
    }

  def record_paths("stylesheet", _stylesheet),
    do: %{admin: "/admin/dashboard/runtime/stylesheets", public: nil}

  def record_paths("post_redirect", redirect),
    do: %{
      admin:
        listed("/admin/dashboard/runtime/redirects", redirect, %{search: redirect.from_path}),
      public: nil
    }

  def record_paths("menu", %MishkaCmsCore.Runtime.Component{} = component),
    do: %{
      admin: listed("/admin/dashboard/runtime/components", component, %{search: component.name}),
      public: nil
    }

  def record_paths("menu", layout),
    do: %{
      admin: listed("/admin/dashboard/runtime/layouts", layout, %{search: layout.name}),
      public: nil
    }

  def record_paths(_other, _record), do: nil

  @doc """
  Where the site serves the CMS record an item of `kind` was written to, whether it is live yet or
  not, as the site's own address (`MishkaCmsCore.Runtime.Languages.url/3`): a page at its path, and
  a post, category, tag or blogger at its page of the Blog (`MishkaBlog.Provision.item_paths/0`), in
  the record's language, or the site's first for one without. `nil` for a kind with no page of its
  own. What a menu's links point at (`MishkaCmsMigration.Targets.CmsLayout`).
  """
  @spec record_address(String.t(), struct()) :: String.t() | nil
  def record_address("page", page),
    do: Languages.url(page.path, %{Languages.capture() => page.language}, page.site_id)

  def record_address(kind, record) when is_map_key(@blog_pages, kind) do
    captures = %{
      Languages.capture() => Map.get(record, :language) || Languages.primary(record.site_id),
      "slug" => record.slug
    }

    Languages.url(
      Map.fetch!(MishkaBlog.Provision.item_paths(), Map.fetch!(@blog_pages, kind)),
      captures,
      record.site_id
    )
  end

  def record_address(_kind, _record), do: nil

  defp listed(path, %resource{}, filters) do
    config = resource |> MishkaGervaz.Resource.Info.Table.url_sync() |> Map.new()
    UrlSync.build_path(path, %{filter_values: filters}, config)
  end

  defp live(true, kind, record), do: record_address(kind, record)
  defp live(_hidden, _kind, _record), do: nil

  @doc """
  The links to the CMS record `paths` (`record_paths/2`) names: an icon link to its place in the
  admin, and one to its page on the site where it has one. Nothing for `nil`.
  """
  def record_links(assigns) do
    ~H"""
    <span :if={@paths} data-role="record-links" class="inline-flex items-center gap-[6px]">
      <a
        href={@paths.admin}
        data-role="record-admin"
        title={dgettext("mishka_gervaz", "Open in the admin")}
        aria-label={dgettext("mishka_gervaz", "Open in the admin")}
        class="grid size-[26px] place-items-center rounded-[8px] bg-[#eeedfb] text-[#5b57d6] transition-opacity hover:opacity-80"
      >
        <MishkaCmsCore.CoreComponents.icon name="hero-pencil-square" class="size-[14px]" />
      </a>
      <a
        :if={@paths.public}
        href={@paths.public}
        target="_blank"
        rel="noopener"
        data-role="record-public"
        title={dgettext("mishka_gervaz", "View on the site")}
        aria-label={dgettext("mishka_gervaz", "View on the site")}
        class="grid size-[26px] place-items-center rounded-[8px] bg-[#f2f1ec] text-[#7c7a75] transition-opacity hover:opacity-80"
      >
        <MishkaCmsCore.CoreComponents.icon
          name="hero-arrow-top-right-on-square"
          class="size-[14px]"
        />
      </a>
    </span>
    """
  end

  @doc """
  Why an item was skipped or failed, or what was written otherwise than the source has it (a
  `MishkaCmsMigration.Report` entry's `reason`), as the admin reads it, each of its parts (joined by
  `"; "`) in words, as one sentence: a part after the first starts in lower case, unless it starts
  with an abbreviation such as URL. A plugin's own reason, and what a source or the CMS answered,
  read as they are.
  Given the item's `kind`, a reason about the item itself names it: `"deleted_in_cms"` reads "This
  page was deleted in Mishka CMS after it was imported", and without a kind, as a run's summary of
  items of every kind reads it, "Deleted in Mishka CMS after it was imported".
  """
  @spec reason_label(String.t(), String.t() | nil) :: String.t()
  def reason_label(reason, kind \\ nil) do
    [first | rest] = reason |> String.split("; ") |> Enum.map(&said(&1, kind))
    Enum.join([first | Enum.map(rest, &lower_first/1)], "; ")
  end

  defp lower_first(<<first::utf8, second::utf8, _rest::binary>> = text)
       when first in ?A..?Z and second not in ?A..?Z,
       do: String.downcase(<<first::utf8>>) <> binary_part(text, 1, byte_size(text) - 1)

  defp lower_first(text), do: text

  @doc """
  What makes the links an import writes differ from the source's addresses
  (`MishkaCmsMigration.Targets.Helpers.LanguageUrls.cause/2`), in words: a language plugin of the
  source, or the site giving every language a prefix.
  """
  @spec language_cause(String.t()) :: String.t()
  def language_cause("polylang"), do: dgettext("mishka_gervaz", "the source runs Polylang")
  def language_cause("wpml"), do: dgettext("mishka_gervaz", "the source runs WPML")

  def language_cause("prefix_all"),
    do: dgettext("mishka_gervaz", "the site gives every language a prefix")

  defp said("deleted_in_cms", nil),
    do: dgettext("mishka_gervaz", "Deleted in Mishka CMS after it was imported")

  defp said("deleted_in_cms", kind),
    do:
      dgettext("mishka_gervaz", "This %{kind} was deleted in Mishka CMS after it was imported",
        kind: kind_one(kind)
      )

  defp said(reason, _kind), do: said(reason)

  defp said("no_target"), do: dgettext("mishka_gervaz", "Nothing imports these yet")
  defp said("unchanged"), do: dgettext("mishka_gervaz", "Unchanged")
  defp said("edited_in_cms"), do: dgettext("mishka_gervaz", "Edited in the CMS, so kept")
  defp said("target_missing"), do: dgettext("mishka_gervaz", "Deleted in the CMS, so left out")

  defp said("archived_in_cms"),
    do: dgettext("mishka_gervaz", "Archived in the CMS: restore it, or leave it archived")

  defp said("restored"),
    do: dgettext("mishka_gervaz", "Restored from the archive, as you decided")

  defp said("duplicate_in_source"), do: dgettext("mishka_gervaz", "Listed twice by the source")

  defp said("parent_missing: " <> parent),
    do:
      dgettext(
        "mishka_gervaz",
        "Its parent %{parent} is not imported yet: import it first, then this one again",
        parent: parent
      )

  defp said("parent_undecided: " <> parent),
    do:
      dgettext(
        "mishka_gervaz",
        "Its parent %{parent} needs your decision: decide it and import it, then this one again",
        parent: parent
      )

  defp said("parent_missing"),
    do: dgettext("mishka_gervaz", "Its parent has no record in Mishka CMS yet")

  defp said("ancestor_undecided: " <> above),
    do:
      dgettext(
        "mishka_gervaz",
        "%{above}, above its parent, needs your decision: decide it, then import the branch, parents first",
        above: above
      )

  defp said("ancestor_missing: " <> above),
    do:
      dgettext(
        "mishka_gervaz",
        "%{above}, above its parent, is not imported yet: import the branch, parents first",
        above: above
      )

  defp said("ancestor_not_listed: " <> id),
    do:
      dgettext(
        "mishka_gervaz",
        "The source does not list #%{id}, above its parent: restore it there, then import the branch",
        id: id
      )

  defp said("without_parent: " <> parent),
    do:
      dgettext("mishka_gervaz", "Imported without its parent %{parent}, as you decided",
        parent: parent
      )

  defp said("parent_not_listed: " <> id),
    do:
      dgettext(
        "mishka_gervaz",
        "The source does not list its parent #%{id}: restore it there, then import this one again",
        id: id
      )

  defp said("waits_for: " <> kinds),
    do: dgettext("mishka_gervaz", "Waits until its %{kinds} are imported", kinds: nouns(kinds))

  defp said("forbidden: " <> kinds),
    do: dgettext("mishka_gervaz", "You may not change %{kinds} on this site", kinds: nouns(kinds))

  defp said("forbidden"), do: dgettext("mishka_gervaz", "You may not change this on this site")
  defp said("unreachable"), do: dgettext("mishka_gervaz", "The source did not answer")

  defp said("no_site"),
    do: dgettext("mishka_gervaz", "The source answered, but not as the site it was")

  defp said("unauthorized"),
    do: dgettext("mishka_gervaz", "The source refused the user or the password")

  defp said("no_user"), do: dgettext("mishka_gervaz", "No user with this email on the site")
  defp said("not_chosen"), do: dgettext("mishka_gervaz", "Left out by this run's choices")
  defp said("no_old_address"), do: dgettext("mishka_gervaz", "No public address at the source")
  defp said("post_missing"), do: dgettext("mishka_gervaz", "Its post was not imported")

  defp said("not_imported"),
    do: dgettext("mishka_gervaz", "What it points at was not imported")

  defp said("posts_list_here"),
    do: dgettext("mishka_gervaz", "The Blog's list of posts is served at its address")

  defp said("same_address"), do: dgettext("mishka_gervaz", "Already at its old address")

  defp said("not_served"),
    do:
      dgettext(
        "mishka_gervaz",
        "What it points at is not public on the site, so it has no redirect"
      )

  defp said("left_out_by_admin"), do: dgettext("mishka_gervaz", "Left out by you")
  defp said("parent_left_out"), do: dgettext("mishka_gervaz", "Its parent is left out")

  defp said("mapped_missing"),
    do: dgettext("mishka_gervaz", "The record it was mapped to is gone")

  defp said("guest_comment: " <> name),
    do: dgettext("mishka_gervaz", "A guest comment by %{name}", name: name)

  defp said("guest_email_dropped"),
    do: dgettext("mishka_gervaz", "The guest's email is not valid, so it is left out")

  defp said("page_comment"),
    do: dgettext("mishka_gervaz", "A comment on a page, which Blog cannot keep")

  defp said("not_a_comment"),
    do: dgettext("mishka_gervaz", "A pingback or trackback, which Blog does not keep")

  defp said("spam_or_trash"),
    do: dgettext("mishka_gervaz", "Spam or in the trash at the source, so left out")

  defp said("author_missing"),
    do: dgettext("mishka_gervaz", "Its author was not imported, so it has none")

  defp said("featured_image_missing"),
    do: dgettext("mishka_gervaz", "Its featured image was not imported, so it has none")

  defp said("srcset_file_missing"),
    do:
      dgettext(
        "mishka_gervaz",
        "A file in an image's srcset was not imported, so it keeps its old address"
      )

  defp said("user_created"),
    do:
      dgettext(
        "mishka_gervaz",
        "A user was created for the author, who signs in with Forgot password or a social sign-in"
      )

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

  defp said("frames_allowed: " <> origins),
    do:
      dgettext("mishka_gervaz", "Allowed its video player on the site: %{origins}",
        origins: origins
      )

  defp said("player_not_allowed"),
    do:
      dgettext(
        "mishka_gervaz",
        "Its YouTube or Vimeo player needs Sites pages may embed, which you may not change"
      )

  defp said("waits_for_admin"),
    do: dgettext("mishka_gervaz", "Waits for an admin who may allow its player, as you decided")

  defp said("player_left_out"),
    do: dgettext("mishka_gervaz", "Imported without its YouTube or Vimeo player, as you decided")

  defp said("site_own_kept"),
    do: dgettext("mishka_gervaz", "The site already has its own, so it is kept")

  defp said("site_has_own"), do: dgettext("mishka_gervaz", "The site already has its own")

  defp said("header_has_links"),
    do: dgettext("mishka_gervaz", "The site's header already has its own links")

  defp said("menu_goes_to"),
    do: dgettext("mishka_gervaz", "Choose where this menu goes")

  defp said("menu_goes_to: " <> menu),
    do:
      dgettext("mishka_gervaz", "Choose where this menu goes. Same links as %{menu}", menu: menu)

  defp said("component_written_first"),
    do:
      dgettext(
        "mishka_gervaz",
        "Waits for the component of the menu with the same name, written first, then connects to it"
      )

  defp said("component_name_taken"),
    do: dgettext("mishka_gervaz", "The site already has a component with this name")

  defp said("footer_has_links"),
    do: dgettext("mishka_gervaz", "The site's footer already has its own links")

  defp said("slug_taken"),
    do: dgettext("mishka_gervaz", "The site already has one at this address")

  defp said("address_taken"),
    do: dgettext("mishka_gervaz", "A page of the site is at this post's address")

  defp said("redirect_edited"),
    do:
      dgettext(
        "mishka_gervaz",
        "A redirect you edited no longer sends to its post, or hides the post's address"
      )

  defp said("blog_missing"), do: dgettext("mishka_gervaz", "Mishka Blog is not installed")

  defp said("same_file"), do: dgettext("mishka_gervaz", "Same file as another file of the source")

  defp said("same_file: " <> title),
    do: dgettext("mishka_gervaz", "Same file as %{title}", title: title)

  defp said("same_file_checked_at_download"),
    do: dgettext("mishka_gervaz", "Checked for an identical file when it is downloaded")

  defp said("same_file_used"),
    do:
      dgettext(
        "mishka_gervaz",
        "Same file as another: the original is used, and the old address redirects to it, as you decided"
      )

  defp said("same_file_used_no_redirect"),
    do:
      dgettext(
        "mishka_gervaz",
        "Same file as another: the original is used, with no redirect from the old address, as you decided"
      )

  defp said("same_file_kept"),
    do: dgettext("mishka_gervaz", "Same file as another, kept as its own, as you decided")

  defp said("draft_pages"), do: dgettext("mishka_gervaz", "Links to pages that are not live")

  defp said("draft_pages: " <> labels),
    do: dgettext("mishka_gervaz", "Links to pages that are not live: %{labels}", labels: labels)

  defp said("language_urls"),
    do: dgettext("mishka_gervaz", "Its links depend on how addresses name the language")

  defp said("language_urls: " <> cause),
    do:
      dgettext("mishka_gervaz", "Its links depend on how addresses name the language: %{cause}",
        cause: language_cause(cause)
      )

  defp said("waits_for_language_urls"),
    do: dgettext("mishka_gervaz", "Waits for the site's language addresses, as you decided")

  defp said("language_missing"),
    do: dgettext("mishka_gervaz", "Its language is not one of the site's languages")

  defp said("language_missing: " <> language),
    do:
      dgettext("mishka_gervaz", "%{language} is not one of the site's languages",
        language: language_name(language)
      )

  defp said("language_added: " <> language),
    do:
      dgettext("mishka_gervaz", "Adds %{language} to the site's languages, as you decided",
        language: language_name(language)
      )

  defp said("language_unknown"),
    do:
      dgettext(
        "mishka_gervaz",
        "The source does not say its language: the site's export file carries it"
      )

  defp said("waits_for_language"),
    do: dgettext("mishka_gervaz", "Waits for the site's export file, as you decided")

  defp said("translations: " <> languages),
    do:
      dgettext("mishka_gervaz", "The original of its translations: %{languages}",
        languages:
          languages |> String.split(", ") |> Enum.map(&language_name/1) |> Languages.join()
      )

  defp said("translation_of: " <> original),
    do: dgettext("mishka_gervaz", "Translation of %{original}", original: original)

  defp said("waits_for_blog"),
    do: dgettext("mishka_gervaz", "Waits for Mishka Blog, as you decided")

  defp said("another_slug"),
    do: dgettext("mishka_gervaz", "Imported as new beside the site's own, with another slug")

  defp said("site_own_replaced"),
    do: dgettext("mishka_gervaz", "Replaces the site's own, as you decided")

  defp said("no_setting"), do: dgettext("mishka_gervaz", "The CMS has no setting for it yet")

  defp said("no_layout"),
    do: dgettext("mishka_gervaz", "The site's layout has no header or footer to put it in")

  defp said("file_missing"), do: dgettext("mishka_gervaz", "Its file was not imported")

  defp said("scripts"),
    do: dgettext("mishka_gervaz", "Contains scripts or inline event handlers")

  defp said("scripts: " <> found),
    do:
      dgettext("mishka_gervaz", "Contains scripts or inline event handlers: %{found}",
        found: found
      )

  defp said("scripts_removed: " <> found),
    do:
      dgettext(
        "mishka_gervaz",
        "Its scripts and inline event handlers removed, as you decided: %{found}",
        found: found
      )

  defp said("scripts_kept: " <> found),
    do:
      dgettext(
        "mishka_gervaz",
        "Its scripts and inline event handlers kept, as you decided: %{found}",
        found: found
      )

  defp said("unsupported_widgets"),
    do: dgettext("mishka_gervaz", "Widgets the CMS has no equivalent for")

  defp said("unsupported_widgets: " <> names),
    do: dgettext("mishka_gervaz", "Widgets the CMS has no equivalent for: %{names}", names: names)

  defp said("no_fallback: " <> names),
    do:
      dgettext("mishka_gervaz", "No fallback available for %{names}, so they are left out",
        names: names
      )

  defp said("fallback_html: " <> names),
    do:
      dgettext("mishka_gervaz", "Imported with the fallback HTML for %{names}, as you decided",
        names: names
      )

  defp said("unconverted: " <> names),
    do: dgettext("mishka_gervaz", "Kept as text: %{names}", names: names)

  defp said("old_address: " <> titles),
    do: dgettext("mishka_gervaz", "Still at its old address: %{titles}", titles: titles)

  defp said(reason), do: reason

  defp language_name(code), do: Languages.name(code) || code

  defp nouns(kinds), do: kinds |> String.split(", ") |> kind_nouns()

  @doc """
  `kinds` named together as a sentence says them, such as "pages, posts and tags", in the reader's
  language (`MishkaCmsCore.Runtime.Languages.join/1`).
  """
  @spec kind_nouns([String.t()]) :: String.t()
  def kind_nouns(kinds), do: kinds |> Enum.map(&kind_noun/1) |> Languages.join()

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
