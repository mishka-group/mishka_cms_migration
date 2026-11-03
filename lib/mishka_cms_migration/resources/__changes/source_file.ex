# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Resources.Changes.SourceFile do
  @moduledoc """
  The file a run of a source that reads one (`c:MishkaCmsMigration.Source.file?/0`) is handed,
  kept from the run's creation until it ends (see "The source's file" in
  `MishkaCmsMigration.MigrationRun`).

      create :create do
        argument :file, {:array, :map}
        change {MishkaCmsMigration.Resources.Changes.SourceFile, step: :take}
        change MishkaCmsMigration.Resources.Changes.CheckConnection
      end

      update :cancel do
        change {MishkaCmsMigration.Resources.Changes.SourceFile, step: :drop}
      end

  `step: :take` drops a `"file"` the connection was typed with, and for a source that reads a file
  takes the first entry of the `file` argument, Gervaz's upload entry, when it names a file Gervaz
  staged (`MishkaCmsCore.Runtime.Media.staged_upload/2`; any other path, a symbolic link or a
  folder, is not taken). The staged file's path is the connection's `"file"` while the run is
  checked, so `CheckConnection` reads the source's host from it, and a `before_transaction` hook,
  which runs before `CheckConnection`'s connect when it comes first in the action, copies it into
  `files_dir/0` as `<uuid>.xml`, readable by the CMS's own user alone, and points `"file"` there.
  An `after_transaction` hook deletes the copy when the run is not saved. A form only validating
  what is typed has no upload, so nothing is copied until the run is created.

  `step: :drop` deletes the run's file once the action has saved the run, and only a file straight
  inside `files_dir/0`.
  """

  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  alias Ash.Error.Changes.InvalidArgument
  alias MishkaCmsCore.Runtime.Media
  alias MishkaCmsMigration.Source

  @not_kept dgettext_noop("errors", "The file could not be kept on the server: %{reason}.")

  @impl true
  def init(opts) when opts in [[step: :take], [step: :drop]], do: {:ok, opts}
  def init(_opts), do: {:error, "step must be :take or :drop"}

  @impl true
  def change(changeset, [step: :take], _context),
    do: changeset |> Ash.Changeset.get_attribute(:connection) |> untyped(changeset) |> taken()

  def change(changeset, [step: :drop], _context),
    do: Ash.Changeset.after_transaction(changeset, &dropped/2)

  @impl true
  def atomic(changeset, [step: :drop] = opts, context),
    do: {:ok, change(changeset, opts, context)}

  @doc """
  The folder a run's file is kept in until the run ends: `mishka_cms_migration` under the
  installer's project path (`MishkaInstaller.__information__/0`, the volume a host keeps its data
  on, `MISHKA_DATA_DIR` in the CMS), or under the system's temporary folder on a node that names
  none. Neither is a folder the CMS serves.
  """
  @spec files_dir() :: Path.t()
  def files_dir,
    do:
      Path.join(
        MishkaInstaller.__information__().path || System.tmp_dir!(),
        "mishka_cms_migration"
      )

  defp untyped(%{} = connection, changeset),
    do:
      Ash.Changeset.force_change_attribute(
        changeset,
        :connection,
        Map.drop(connection, ["file", :file])
      )

  defp untyped(_not_a_map, changeset), do: changeset

  defp taken(changeset) do
    with true <- changeset |> Ash.Changeset.get_attribute(:source) |> Source.file?(),
         [entry | _] <- Ash.Changeset.get_argument(changeset, :file) || [],
         {:ok, staged} <- entry |> entry_path() |> Media.staged_upload(site_id(changeset)) do
      kept(changeset, staged, Path.join(files_dir(), Ash.UUID.generate() <> ".xml"))
    else
      _no_file -> changeset
    end
  end

  defp entry_path(%{path: path}), do: path
  defp entry_path(%{"path" => path}), do: path
  defp entry_path(_entry), do: nil

  defp site_id(changeset),
    do: Ash.Changeset.get_attribute(changeset, :site_id) || changeset.tenant

  defp kept(changeset, staged, kept) do
    changeset
    |> named(staged)
    |> Ash.Changeset.before_transaction(&keep(&1, staged, kept))
    |> Ash.Changeset.after_transaction(&kept_if_saved(&1, &2, kept))
  end

  defp named(changeset, path),
    do:
      Ash.Changeset.force_change_attribute(
        changeset,
        :connection,
        changeset |> Ash.Changeset.get_attribute(:connection) |> Map.put("file", path)
      )

  # sobelow_skip ["Traversal.FileModule"]
  # `staged` is a file Gervaz staged (`Media.staged_upload/2`) and `kept` a name made in `taken/1`.
  defp keep(changeset, staged, kept) do
    with :ok <- File.mkdir_p(files_dir()),
         :ok <- File.chmod(files_dir(), 0o700),
         :ok <- File.cp(staged, kept),
         :ok <- File.chmod(kept, 0o600) do
      named(changeset, kept)
    else
      {:error, reason} ->
        Ash.Changeset.add_error(
          changeset,
          InvalidArgument.exception(
            field: :file,
            message: @not_kept,
            vars: [reason: reason |> :file.format_error() |> List.to_string()]
          )
        )
    end
  end

  defp kept_if_saved(_changeset, {:ok, _run} = saved, _kept), do: saved

  defp kept_if_saved(_changeset, refused, kept) do
    removed(kept)
    refused
  end

  defp dropped(_changeset, {:ok, %{connection: %{"file" => path}}} = saved)
       when is_binary(path) do
    removed(path)
    saved
  end

  defp dropped(_changeset, result), do: result

  defp removed(path), do: path |> Path.expand() |> Path.dirname() |> own?() |> removed(path)

  defp own?(dir), do: dir == Path.expand(files_dir())

  # sobelow_skip ["Traversal.FileModule"]
  # Only a file straight inside `files_dir/0` is removed.
  defp removed(true, path), do: File.rm(path)
  defp removed(false, _path), do: :ok
end
