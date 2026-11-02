# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Options do
  @moduledoc """
  The choices an admin makes for one run, saved with it (`MishkaCmsMigration.MigrationRun`'s
  `:options`) and handed to every target as `options` in its context.

    * `:authors` — `"connect"` (the default) ties each source author to an existing user, matched by
      email; `"create"` makes a user and a blog author for each.
    * `:pages` — `"draft"` (the default) brings pages in as drafts; `"publish"` puts them live at
      their old addresses.
    * `:post_address` — `"blog"` (the default) serves posts at `/blog/<slug>` with a 301 from each
      old address; `"keep"` keeps the source's own addresses.
    * `:comments` — whether comments come too; `false` by default.

  Any other key, or any other value, is refused. A choice is saved with the run and handed to every
  target; each target acts on the choices that concern it.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true, json: true do
    field :authors, String.t(),
      default: "connect",
      derives: "sanitize(trim) validate(enum=String[connect::create])"

    field :pages, String.t(),
      default: "draft",
      derives: "sanitize(trim) validate(enum=String[draft::publish])"

    field :post_address, String.t(),
      default: "blog",
      derives: "sanitize(trim) validate(enum=String[blog::keep])"

    field :comments, boolean(), default: false, derives: "validate(boolean)"
  end
end
