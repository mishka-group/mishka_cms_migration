# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Resources.Validations.SourceInstalled do
  @moduledoc """
  Refuses a run whose `source` names no installed source plugin
  (`MishkaCmsMigration.Source.fetch/1`), on its `source` field, so a run is never created for a
  source no job could read.

      create :create do
        validate MishkaCmsMigration.Resources.Validations.SourceInstalled, before_action?: true
      end

  Run it `before_action?`, after the input is cleaned.
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  alias Ash.Error.Changes.InvalidAttribute
  alias MishkaCmsMigration.Source

  @message dgettext_noop("errors", "No source called %{source} is installed.")

  @impl true
  def supports(_opts), do: [Ash.Changeset]

  @impl true
  def validate(changeset, _opts, _context) do
    source = Ash.Changeset.get_attribute(changeset, :source)
    source |> Source.fetch() |> installed(source)
  end

  defp installed({:ok, _module}, _source), do: :ok

  defp installed({:error, _reason}, source),
    do:
      {:error,
       InvalidAttribute.exception(field: :source, message: @message, vars: [source: source])}
end
