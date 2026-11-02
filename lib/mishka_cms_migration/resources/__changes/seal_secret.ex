# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Resources.Changes.SealSecret do
  @moduledoc """
  Keeps an action's secret argument only in its sealed form (`MishkaCmsMigration.Secret`): writes
  it sealed to `:attribute` and drops the argument, so the plain text is neither stored nor carried
  on in the changeset.

      create :create do
        argument :secret, :string, sensitive?: true
        change {MishkaCmsMigration.Resources.Changes.SealSecret,
                argument: :secret, attribute: :connection_secret}
      end

  A blank or missing secret leaves the attribute as it is.
  """

  use Ash.Resource.Change

  alias MishkaCmsMigration.Secret

  @impl true
  def init(opts) do
    case {opts[:argument], opts[:attribute]} do
      {argument, attribute}
      when is_atom(argument) and is_atom(attribute) and argument != nil and attribute != nil ->
        {:ok, opts}

      _missing ->
        {:error, "expected :argument and :attribute"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    case Secret.seal(Ash.Changeset.get_argument(changeset, opts[:argument])) do
      nil ->
        Ash.Changeset.delete_argument(changeset, opts[:argument])

      sealed ->
        changeset
        |> Ash.Changeset.force_change_attribute(opts[:attribute], sealed)
        |> Ash.Changeset.delete_argument(opts[:argument])
    end
  end
end
