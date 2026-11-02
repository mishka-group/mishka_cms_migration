# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Resources.Changes.BuildStruct do
  @moduledoc """
  Builds a map attribute through a guarded_struct module (`builder/1`) and stores what it built as
  a plain map, every default filled in, so the row says the whole of what was chosen.

      create :create do
        change {MishkaCmsMigration.Resources.Changes.BuildStruct,
                attribute: :options, struct: MishkaCmsMigration.Options}
      end

  Each error the builder returns is the attribute's, at the key it names (`path: [attribute]`), so a
  form shows it beside that key. A missing attribute is built from an empty map.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def init(opts) do
    case {opts[:attribute], opts[:struct]} do
      {attribute, struct}
      when is_atom(attribute) and is_atom(struct) and not is_nil(attribute) and not is_nil(struct) ->
        {:ok, opts}

      _missing ->
        {:error, "expected :attribute and :struct"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    attribute = opts[:attribute]

    case opts[:struct].builder(Ash.Changeset.get_attribute(changeset, attribute) || %{}) do
      {:ok, built} ->
        Ash.Changeset.force_change_attribute(changeset, attribute, Map.from_struct(built))

      {:error, errors} ->
        Enum.reduce(errors, changeset, &Ash.Changeset.add_error(&2, error(&1, attribute)))
    end
  end

  defp error(%{field: field} = error, attribute),
    do:
      InvalidAttribute.exception(
        field: field,
        path: [attribute],
        message: Map.get(error, :message, "is invalid")
      )
end
