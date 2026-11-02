# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Repo do
  @moduledoc """
  The Postgres repo the extension's resources write through when it runs on its own. Inside the CMS
  the resources write through the CMS's repo, which `config :mishka_cms_core, repo: …` names.
  """

  use AshPostgres.Repo, otp_app: :mishka_cms_migration

  @doc "The oldest PostgreSQL the resources are written for."
  def min_pg_version do
    %Version{major: 16, minor: 9, patch: 0}
  end

  @doc """
  `false`: an action opens no transaction it does not need, the default AshPostgres moves to in
  its next major version.
  """
  def prefer_transaction? do
    false
  end

  @doc """
  The Postgres extensions the migration generator installs. They must match the CMS's
  `MishkaCms.Repo`: the resources are the same either way, and a user's `email` is a `citext`
  column, so a repo without it cannot hold the accounts tables this extension borrows.
  """
  def installed_extensions do
    ["ash-functions", "citext"]
  end
end
