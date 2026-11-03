# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

File.rm_rf!(MishkaCmsCore.Runtime.Media.static_dir())

:ok =
  MishkaCmsCore.Test.Boot.start!(
    otp_app: :mishka_cms_migration,
    repo: MishkaCmsMigration.Repo,
    endpoint: MishkaCmsMigration.TestEndpoint,
    plugins: MishkaCmsCore.Application.plugins() ++ MishkaCmsMigration.Application.plugins(),
    sweep: ["Elixir.MishkaCmsMigration.Test.Plugins."]
  )

ExUnit.start(assert_receive_timeout: 1_000)
Ecto.Adapters.SQL.Sandbox.mode(MishkaCmsMigration.Repo, :manual)
