# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.Helpers.ContentChecks do
  @moduledoc """
  What a post or a page may wait on before it is written, for the targets that write it
  (`MishkaCmsMigration.Targets.CmsPage`, `MishkaCmsMigration.Targets.BlogPost`), asked in this
  order, the first that waits answering: its language, which the site may not publish in or the
  source may not say (`MishkaCmsMigration.Targets.Helpers.Editions`), the widgets of a page builder
  the CMS has no equivalent for (`MishkaCmsMigration.Targets.Helpers.Widgets`), its scripts and
  inline event handlers
  (`MishkaCmsMigration.Targets.Helpers.Scripts`), and the video players the site does not allow
  yet (`MishkaCmsMigration.Targets.Helpers.Frames`). An admin decides each in turn.
  """

  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Target
  alias MishkaCmsMigration.Targets.Helpers.{Editions, Frames, Scripts, Widgets}

  @doc """
  What a target's `prepare/3` asks before the write: `:ok`, or what the first check that waits
  answers.
  """
  @spec call(Item.t(), Target.context()) ::
          :ok | {:error, term()} | {:skipped, String.t()} | {:undecided, String.t()}
  def call(item, context) do
    with :ok <- Editions.call(item, context),
         :ok <- Widgets.call(item, context),
         :ok <- Scripts.call(item, context),
         do: Frames.call(item, context)
  end

  @doc "What a target's `waiting/2` answers in a dry run: the first check that waits, or `nil`."
  @spec waiting(Item.t(), Target.context()) :: Target.found() | nil
  def waiting(item, context),
    do:
      Editions.waiting(item, context) || Widgets.waiting(item, context) ||
        Scripts.waiting(item, context) || Frames.waiting(item, context)
end
