# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

import Config

config :mishka_cms_migration,
  ecto_repos: [MishkaCmsMigration.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [MishkaCmsMigration]

# Which repo the resources write through and which endpoint they broadcast on — the same two settings
# the CMS sets for itself. Read with `Application.compile_env!/2` in `postgres do repo … end` and
# `pub_sub do module … end`, which is what lets these resources compile outside the CMS at all.
# Compile-time, so it costs nothing per query.
# Whose admin routes `extension_routes(:admin)` mounts — on its own, only the core's.
config :mishka_cms_core, extensions: [MishkaCmsCoreWeb]

config :mishka_cms_core,
  repo: MishkaCmsMigration.Repo,
  endpoint: MishkaCmsMigration.TestEndpoint,
  host_app: :mishka_cms_migration

config :ash,
  default_string_length_count: :codepoints,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :postgres,
        :json_api,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [:json_api, :resources, :policies, :authorization, :domain, :execution]
    ]
  ]

import_config "#{config_env()}.exs"
