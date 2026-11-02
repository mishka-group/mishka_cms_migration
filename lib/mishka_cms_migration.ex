# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration do
  @moduledoc """
  The migration extension's Ash domain. The extension moves a site from another CMS into a Mishka
  CMS site: WordPress is the first source, and Joomla and others come later as plugins that reuse the
  same mapping, dry run, import job and report.

  The domain holds the resources of an import run once they exist; it has none yet.
  """
  use Ash.Domain,
    otp_app: :mishka_cms_migration,
    validate_config_inclusion?: false,
    extensions: [MishkaGervaz.Domain]

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext
end
