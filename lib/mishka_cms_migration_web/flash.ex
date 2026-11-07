# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Flash do
  @moduledoc """
  The flashes of the migration pages, said by what they mean and drawn with the kinds the core has.

    * `:success` — something is done: Run cancelled, 553 items decided, Import of 2 items: created;
    * `:info` — something started, was queued, or did not start: Dry run started, a step the run
      refuses while another run of the site is running;
    * `:warning` — done, but the admin should look: an import with skipped items or items that wait
      for a decision, a bulk choice that left some items as they were, a dry run that could not
      start after the run was saved;
    * `:error` — failed: a failed import, a run that is not there, a choice the core refused.

  The core draws the same four kinds (`MishkaCmsCore.Layouts.flash_group/1`): success green, info
  blue, warning amber and error red. `put/3` puts each meaning under its own core kind
  (`core_kind/1`), so a page and a test ask for the meaning and the admin sees its colour.

  `result_kind/1` is the meaning of what an item's dry run or import came to.
  """

  @kinds [:success, :info, :warning, :error]

  @typedoc "What a flash means."
  @type kind :: :success | :info | :warning | :error

  @doc "The kinds a flash can mean, from the calmest to the most serious."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Puts `message` on `socket`, as the core kind `core_kind/1` draws `kind` with."
  @spec put(Phoenix.LiveView.Socket.t(), kind(), String.t()) :: Phoenix.LiveView.Socket.t()
  def put(socket, kind, message),
    do: Phoenix.LiveView.put_flash(socket, core_kind(kind), message)

  @doc """
  The kind the core draws a flash of `kind` with: `:success`, `:info`, `:warning` and `:error` each
  have their own colour and icon.
  """
  @spec core_kind(kind()) :: kind()
  def core_kind(kind) when kind in [:success, :info, :warning, :error], do: kind

  @doc """
  What a flash about one item means, by what its dry run or import came to: created and updated are
  `:success`, failed is `:error`, and skipped, waiting for a decision or anything else the admin may
  want to look at is `:warning`.
  """
  @spec result_kind(atom()) :: kind()
  def result_kind(result) when result in [:created, :updated], do: :success
  def result_kind(:failed), do: :error
  def result_kind(_skipped_or_waiting), do: :warning
end
