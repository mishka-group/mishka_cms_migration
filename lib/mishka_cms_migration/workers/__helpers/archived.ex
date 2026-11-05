# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Workers.Helpers.Archived do
  @moduledoc """
  The CMS records an admin archived. A resource with `AshArchival.Resource` hides an archived
  record from its reads, so an item that remembers one (`MishkaCmsMigration.MigrationItem`'s
  `target_id` or `mapped_id`) reads as though it were deleted, and a write that points at it, such
  as a post's tags, is refused as a record "not found".

  `call/3` finds them through the read the record's Archived tab runs, and `restore/2` brings one
  back through the action its Restore runs: the actions the resource's mishka_gervaz archive
  configuration names for a site's admin (`MishkaGervaz.Resource.Info.Table.archive_action_for/3`,
  `:archived` and `:unarchive` unless the resource names others), as the admin running the job, on
  the run's site and under the CMS's own policies. A resource with no archive has none.
  """

  require Ash.Query

  alias MishkaGervaz.Resource.Info.Table

  @doc """
  The archived records of `resource` among `ids`, read as `context`'s `actor` on its `site_id`; `[]`
  for a resource with no archive and for an admin the CMS does not let read them. One query for
  each page of the archive read, a page holding up to its largest size.
  """
  @spec call(Ash.Resource.t(), [Ecto.UUID.t()], %{actor: term(), site_id: term()}) :: [struct()]
  def call(_resource, [], _context), do: []

  def call(resource, ids, context),
    do: resource |> Table.archive_action_for(:read, false) |> archived(resource, ids, context)

  @doc """
  Restores `record` as `context`'s `actor` on its `site_id`, inside the import's transaction for the
  item, and answers the record as the CMS restored it.
  """
  @spec restore(struct(), %{actor: term(), site_id: term()}) :: {:ok, struct()} | {:error, term()}
  def restore(%resource{} = record, context),
    do:
      record
      |> Ash.Changeset.for_update(
        Table.archive_action_for(resource, :restore, false),
        %{},
        opts(context) ++ [context: %{warn_on_transaction_hooks?: false}]
      )
      |> Ash.update()

  defp archived(nil, _resource, _ids, _context), do: []

  defp archived(action, resource, ids, context) do
    read = Ash.Resource.Info.action(resource, action)

    ids
    |> Enum.chunk_every(page_size(read, length(ids)))
    |> Enum.flat_map(&page(resource, read, &1, context))
  end

  defp page(resource, read, ids, context) do
    resource
    |> Ash.Query.for_read(read.name, %{}, opts(context))
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read(opts(context) ++ paged(read, ids))
    |> records()
  end

  defp page_size(%{pagination: %{max_page_size: size}}, _count) when is_integer(size), do: size
  defp page_size(_read, count), do: count

  defp paged(%{pagination: %{}}, ids), do: [page: [limit: length(ids)]]
  defp paged(_read, _ids), do: []

  defp records({:ok, %{results: records}}), do: records
  defp records({:ok, records}) when is_list(records), do: records
  defp records({:error, %Ash.Error.Forbidden{}}), do: []
  defp records({:error, error}), do: raise(error)

  defp opts(context), do: [actor: context.actor, tenant: context.site_id]
end
