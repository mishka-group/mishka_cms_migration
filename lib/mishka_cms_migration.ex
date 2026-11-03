# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration do
  @moduledoc """
  The migration extension's Ash domain. The extension moves a site from another CMS into a Mishka
  CMS site. No source ships yet: WordPress is planned as the first, and Joomla and others come later
  as plugins that reuse the same mapping, dry run, import job and report.

    * `MishkaCmsMigration.MigrationRun` — one move: its source, its choices, its life and its
      report.
    * `MishkaCmsMigration.MigrationItem` — what the last dry run would do with each item of a
      source and what the last import wrote for it, so a re-run updates instead of duplicating and
      keeps what an admin changed in the CMS.
    * `MishkaCmsMigration.MigrationLog` — a run's log: each step of its life, which the Migration
      page's Logs and the core's activity log show (`MishkaCmsMigration.Activity`).

  A source is a plugin behind `MishkaCmsMigration.Source`, each kind of item is written through an
  existing CMS action by a `MishkaCmsMigration.Target`, the jobs are the run's AshOban triggers
  (`MishkaCmsMigration.Workers`), and an import fires the events of `MishkaCmsMigration.Events`.
  Installing the extension on a site creates the permission names its runs are gated by
  (`MishkaCmsMigration.Provision`).

  ## Usage

  `"wordpress"` below stands for an installed source: until a source with that id is installed,
  `create_run` refuses the run (`MishkaCmsMigration.Source.fetch/1`).

      {:ok, run} =
        MishkaCmsMigration.create_run(
          %{source: "wordpress", source_host: "example.com",
            connection: %{"url" => "https://example.com", "user" => "admin"},
            options: %{pages: "draft"}, secret: "abcd efgh ijkl"},
          actor: admin, tenant: site.id
        )

      {:ok, run} = MishkaCmsMigration.start_dry_run(run, actor: admin, tenant: site.id)
      {:ok, run} = MishkaCmsMigration.start_import(run, actor: admin, tenant: site.id)
  """
  use Ash.Domain,
    otp_app: :mishka_cms_migration,
    validate_config_inclusion?: false,
    extensions: [MishkaGervaz.Domain]

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  mishka_gervaz do
    table do
      actor_key :current_user
      ui_adapter MishkaGervaz.UIAdapters.Tailwind

      pagination do
        type :load_more
        page_size 20
        page_size_options [20, 50, 100]
      end

      realtime do
        pubsub MishkaCmsCore.PubSub
      end

      actions do
        read {:master_read, :read}
        get {:master_get, :read}
      end
    end
  end

  resources do
    resource MishkaCmsMigration.MigrationRun do
      define :create_run, action: :create
      define :get_run, action: :read, get_by: :id
      define :start_dry_run, action: :start_dry_run
      define :start_import, action: :start_import
      define :cancel_run, action: :cancel
      define :finish_dry_run, action: :finish_dry_run, args: [:report, :extra]
      define :finish_import, action: :finish_import, args: [:report, :extra]
      define :fail_run, action: :fail, args: [:error]
      define :record_progress, action: :record_progress, args: [:progress]
    end

    resource MishkaCmsMigration.MigrationItem do
      define :items_by_sources,
        action: :by_sources,
        args: [:source_host, :source_kind, :source_ids]

      define :record_item, action: :record
      define :record_item_outcome, action: :record_outcome
      define :record_item_plan, action: :record_plan
      define :leave_out_item, action: :leave_out
      define :bring_back_item, action: :bring_back
    end

    resource MishkaCmsMigration.MigrationLog do
      define :record_log, action: :record
    end
  end
end
