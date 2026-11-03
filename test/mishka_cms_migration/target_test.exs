# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.TargetTest do
  @moduledoc """
  A target is refused when it compiles if its resource cannot keep an admin's edits or be found
  again by a re-run: no UUID `:id`, no `updated_at`, or actions it does not have.
  """
  use ExUnit.Case, async: true

  defp compile_target(resource, opts \\ []) do
    name = Module.concat(__MODULE__, "Target#{System.unique_integer([:positive])}")
    options = Keyword.merge([kind: "thing", resource: resource], opts)

    Code.compile_quoted(
      quote do
        defmodule unquote(name) do
          use MishkaCmsMigration.Target, unquote(options)

          @impl MishkaCmsMigration.Target
          def attrs(_item, _context), do: %{}
        end
      end
    )
  end

  test "a resource with a UUID id, updated_at and both actions is taken" do
    assert [{_module, _bytecode} | _] = compile_target(MishkaCmsCore.Runtime.Redirect)
  end

  test "a resource without updated_at is refused" do
    assert_raise ArgumentError, ~r/updated_at/, fn ->
      compile_target(MishkaCmsCore.Runtime.Redirect.Version)
    end
  end

  test "a resource whose updated_at is a plain attribute, not an update_timestamp, is refused" do
    assert_raise ArgumentError, ~r/update_timestamp/, fn ->
      compile_target(MishkaCmsMigration.Test.PlainTimestampResource)
    end
  end

  test "a resource whose updated_at an action may be handed is refused" do
    assert_raise ArgumentError, ~r/update_timestamp/, fn ->
      compile_target(MishkaCmsMigration.Test.WritableTimestampResource)
    end
  end

  test "a resource whose id is not a UUID is refused" do
    assert_raise ArgumentError, ~r/UUID/, fn ->
      compile_target(MishkaCmsMigration.Test.IntegerResource)
    end
  end

  test "a generic action that answers one of the resource's records may be its create, and no other" do
    assert [{_module, _bytecode} | _] =
             compile_target(MishkaCmsCore.Runtime.Media, create: :upload)

    assert_raise ArgumentError, ~r/:read is not one of its create actions, nor a generic/, fn ->
      compile_target(MishkaCmsCore.Runtime.Media, create: :read)
    end
  end

  test "a create action that upserts may be its update, and no other create" do
    assert [{_module, _bytecode} | _] =
             compile_target(MishkaCmsCore.Runtime.Setting, create: :set, update: :set)

    assert_raise ArgumentError, ~r/:create is not one of its update actions, nor a create/, fn ->
      compile_target(MishkaCmsCore.Runtime.Redirect, update: :create)
    end
  end

  test "a module that is not a resource, or an action the resource does not have, is refused" do
    assert_raise ArgumentError, ~r/not an Ash resource/, fn ->
      compile_target(MishkaCmsMigration.Source.Item)
    end

    assert_raise ArgumentError, ~r/:publish/, fn ->
      compile_target(MishkaCmsCore.Runtime.Redirect, update: :publish)
    end
  end
end
