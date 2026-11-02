# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.DataCase do
  @moduledoc """
  Test case for anything that touches the database but not the web layer — the resources, their
  actions and policies, the import job.

  The core's `MishkaCmsCore.DataCase` with this extension's helpers on top. The sandbox is the
  core's (`MishkaCmsCore.DataCase.setup_sandbox/1`): each test gets its own sandboxed connection and
  everything it writes is rolled back at the end; `async: false` (the default here) shares that
  connection with any process the test spawns, and puts the site cache and the runtime modules back as
  the test found them.

  The helpers come from the core too — `errors_on/1` and the rest of `MishkaCmsCore.DataCase`, the
  sites, users and runtime records of `MishkaCmsCore.Test.Factory`, `MishkaCmsCore.Test.VersionHelpers`
  — and this case adds this extension's fixtures (`MishkaCmsMigration.Test.Factory`), Oban's test
  helpers (`Oban.Testing`), a plugin for the length of a block (`with_plugin/3`) or of a test
  (`register_plugin!/2`), and the SQL a block ran (`queries_while/1`).

  ## How the suite boots

  The CMS's application supervisor owns the runtime around the core, so running this suite on its
  own means starting it, and `test_helper.exs` does it with the core's harness,
  `MishkaCmsCore.Test.Boot.start!/1`: it creates Oban's tables (they are not an Ash resource, so
  `mix ash.codegen` never emits them), then starts the repo, Oban, the core's caches and runtime
  compiler, AshAuthentication and the endpoint, the way a host starts them. The run starts once the
  core's plugins and this extension's own are live, each having registered from its own
  `handle_continue`. A test plugin a killed run left registered in `mishka_installer`'s Mnesia
  (any module under `MishkaCmsMigration.Test.Plugins`) is swept first.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias MishkaCmsMigration.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import MishkaCmsCore.DataCase
      import MishkaCmsCore.Test.Factory
      import MishkaCmsCore.Test.VersionHelpers
      import MishkaCmsMigration.DataCase
      import MishkaCmsMigration.Test.Factory

      use AshOban.Test, repo: MishkaCmsMigration.Repo
    end
  end

  setup tags do
    MishkaCmsCore.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Runs `fun` with `module` registered and started as the plugin for `event`, and unregisters it
  afterwards.

      with_plugin(MyPlugin, "migration:item:before_import", fn -> ... end)
  """
  def with_plugin(module, event, fun) do
    register(module, event)

    try do
      fun.()
    after
      MishkaInstaller.Event.Event.unregister(:name, module, false)
    end
  end

  @doc """
  Registers and starts `module` as the plugin for `event` for the rest of the test, and unregisters
  it when the test exits.

      setup do: register_plugin!(MyPlugin, "migration:import:finished")
  """
  def register_plugin!(module, event) do
    register(module, event)
    on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, module, false) end)
  end

  defp register(module, event) do
    {:ok, _registered} =
      MishkaInstaller.Event.Event.write(%{
        name: module,
        event: event,
        extension: :mishka_installer,
        status: :started
      })

    :ok = MishkaInstaller.Event.EventHandler.do_compile(event, :start, false)
  end

  @doc """
  Runs `fun` and returns the SQL of every query the repo ran meanwhile, off the repo's own
  telemetry — the only mark a read whose answer nothing shows leaves.

      assert queries_while(fn -> render(view) end) == []
  """
  def queries_while(fun) do
    handler = "queries-#{System.unique_integer([:positive])}"
    listener = self()

    :telemetry.attach(
      handler,
      [:mishka_cms_migration, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        send(listener, {handler, metadata.query})
      end,
      nil
    )

    try do
      fun.()
      drain(handler, [])
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(handler, gathered) do
    receive do
      {^handler, query} -> drain(handler, [query | gathered])
    after
      0 -> gathered
    end
  end
end
