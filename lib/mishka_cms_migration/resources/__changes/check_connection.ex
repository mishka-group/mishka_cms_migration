# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Resources.Changes.CheckConnection do
  @moduledoc """
  Connects to a new run's source before the run is saved
  (`c:MishkaCmsMigration.Source.connect/2`, with the run's `connection` and its sealed secret
  opened), so a run is only kept for a source it can reach. What the source says of itself
  (`c:MishkaCmsMigration.Source.extra/1`) becomes the run's `extra`.

  A run that names no `source_host` takes the host its source reads from the connection
  (`c:MishkaCmsMigration.Source.host/1`), so an admin types the address once. The action lists
  `source_host` in `allow_nil_input`, so a connection with no host is refused once, on the
  connection, rather than again as a missing host.

  A refusal is an error on the run's `connection`, in words for the reasons
  `MishkaCmsMigration.Source` names and as the reason itself for any other; a connection the
  source reads no host from is refused as `:invalid_address`. A run of a source that is not
  installed is left to `MishkaCmsMigration.Resources.Validations.SourceInstalled`.

      create :create do
        allow_nil_input [:source_host]
        change MishkaCmsMigration.Resources.Changes.CheckConnection
        validate present(:source_host), only_when_valid?: true
        change &MishkaCmsMigration.MigrationRun.seal_secret/2
      end

  The source is handed the connection as the run keeps it, as JSON with string keys, which is how
  a job reads it back; guarded_struct has turned the keys it knows into atoms by then.

  It connects in a `before_transaction` hook: once, when the action runs, outside its
  transaction, and never while a form only validates what is typed. The hook opens the secret
  `seal_secret/2` sealed, so it needs that change in the same action.
  """

  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  alias Ash.Error.Changes.InvalidAttribute
  alias MishkaCmsMigration.MigrationRun
  alias MishkaCmsMigration.Source

  @messages %{
    invalid_address:
      dgettext_noop("errors", "Type the site's address, such as https://example.com."),
    unreachable: dgettext_noop("errors", "Nothing answered at this address."),
    no_site: dgettext_noop("errors", "No %{source} site answers at this address."),
    unauthorized:
      dgettext_noop(
        "errors",
        "%{source} did not accept this user and application password. If both are right, ask your host to let the Authorization header through."
      )
  }

  @other dgettext_noop("errors", "Could not connect to %{source}: %{reason}.")

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.get_attribute(:source)
    |> Source.fetch()
    |> check(changeset)
  end

  defp check({:error, :not_installed}, changeset), do: changeset

  defp check({:ok, source}, changeset) do
    changeset
    |> Ash.Changeset.get_attribute(:source_host)
    |> hosted(source, changeset)
    |> Ash.Changeset.before_transaction(&connect(source, &1))
  end

  defp hosted(host, _source, changeset) when is_binary(host) and host != "", do: changeset

  defp hosted(_none, source, changeset),
    do: changeset |> connection() |> source.host() |> host_from(source, changeset)

  defp host_from(host, _source, changeset) when is_binary(host) and host != "",
    do: Ash.Changeset.force_change_attribute(changeset, :source_host, host)

  defp host_from(_none, source, changeset),
    do: Ash.Changeset.add_error(changeset, refused(source, :invalid_address))

  defp connect(source, changeset) do
    connection = connection(changeset)
    sealed = Ash.Changeset.get_attribute(changeset, :connection_secret)

    with {:ok, secret} <- MigrationRun.open_secret(%{connection_secret: sealed}),
         {:ok, conn} <- source.connect(connection, secret) do
      Ash.Changeset.force_change_attribute(changeset, :extra, source.extra(conn))
    else
      {:error, reason} -> Ash.Changeset.add_error(changeset, refused(source, reason))
    end
  end

  defp connection(changeset),
    do:
      (Ash.Changeset.get_attribute(changeset, :connection) || %{})
      |> Jason.encode!()
      |> Jason.decode!()

  defp refused(source, reason) do
    InvalidAttribute.exception(
      field: :connection,
      message: Map.get(@messages, reason, @other),
      vars: [source: source.label(), reason: MishkaCmsMigration.Report.reason(reason)]
    )
  end
end
