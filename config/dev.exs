# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

import Config

config :mishka_cms_migration, MishkaCmsMigration.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "mishka_cms_migration_dev",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :ash, policies: [show_policy_breakdowns?: true]
