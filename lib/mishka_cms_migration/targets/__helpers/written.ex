# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.Helpers.Written do
  @moduledoc """
  The CMS records the same run, or an earlier one, wrote for a source's items of another kind, for
  a target whose record points at them, such as a post's redirect at its post or a post's image at
  its file: the items are read by the run's source host, the kind and their source ids
  (`MishkaCmsMigration.MigrationItem`), and the records they were written to by their ids, as the
  admin running the job (`MishkaCmsMigration.Targets.Helpers.Read`).

  An item that was never written, or was skipped or failed, is left out, and so is one an admin left
  out (its record, written by an earlier import, is not pointed at) and one whose record the CMS no
  longer has or the admin may not read.
  """

  require Ash.Query

  alias MishkaCmsMigration.Target
  alias MishkaCmsMigration.Targets.Helpers.Read

  @doc "The `resource` records written for the `kind` items `source_ids` name, by source id."
  @spec call(Ash.Resource.t(), String.t(), [term()], Target.context()) :: %{
          String.t() => struct()
        }
  def call(resource, kind, source_ids, context) do
    written =
      context.source_host
      |> MishkaCmsMigration.items_by_sources!(kind, Enum.map(source_ids, &to_string/1),
        actor: context.actor,
        tenant: context.site_id
      )
      |> Enum.filter(&(is_binary(&1.target_id) and not &1.left_out))

    records = written |> Enum.map(& &1.target_id) |> records(resource, context)

    for %{source_id: source_id, target_id: id} <- written,
        record = records[id],
        into: %{},
        do: {source_id, record}
  end

  defp records([], _resource, _context), do: %{}

  defp records(ids, resource, context) do
    resource
    |> Ash.Query.filter(id in ^ids)
    |> Read.call(context)
    |> Map.new(&{&1.id, &1})
  end
end
