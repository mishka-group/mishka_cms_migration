# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

[
  import_deps: [
    :oban,
    :ash_postgres,
    :ash_phoenix,
    :ash,
    :reactor,
    :mishka_gervaz,
    :guarded_struct,
    :ecto,
    :ecto_sql,
    :phoenix
  ],
  subdirectories: ["priv/*/migrations"],
  plugins: [Spark.Formatter, Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{heex,ex,exs}",
    "dev/**/*.exs",
    "priv/*/seeds.exs"
  ]
]
