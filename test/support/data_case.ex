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
  connection with any process the test spawns, and puts the site cache and the runtime modules back
  as the test found them.

  The helpers come from the core too — `errors_on/1` and the rest of `MishkaCmsCore.DataCase`, the
  sites, users and runtime records of `MishkaCmsCore.Test.Factory`,
  `MishkaCmsCore.Test.VersionHelpers` — and this case adds this extension's fixtures
  (`MishkaCmsMigration.Test.Factory`), AshOban's and Oban's test helpers (`AshOban.Test`), a plugin
  for the length of a block (`with_plugin/3`) or of a test (`register_plugin!/2`), a node without
  the Blog (`without_blog!/0`, `with_blog!/0`), a site whose Blog pages are routed (`blog_routed!/1`),
  a site routed with the pages it has (`site_routed!/1`),
  the items an import recorded (`imported_items/1`),
  and the SQL a block ran (`queries_while/1`).

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

  @doc """
  Stops every Blog target in the installer for the rest of the test, so the node reads as one
  without the Blog, which `MishkaCmsMigration.Application.targets/0` leaves them out of, and starts
  them again when the test exits. `with_blog!/0` starts them again sooner.

      setup do: without_blog!()
  """
  def without_blog! do
    for target <- blog_targets(),
        do: {:ok, _stopped} = MishkaInstaller.Event.Event.stop(:name, target, false)

    on_exit(&with_blog!/0)
  end

  @doc "Starts the Blog targets `without_blog!/0` stopped again, as a node the Blog was installed on."
  def with_blog! do
    for target <- blog_targets(), do: MishkaInstaller.Event.Event.enable(target, false)
    :ok
  end

  defp blog_targets,
    do:
      Enum.filter(
        MishkaCmsMigration.Application.targets(),
        &(&1.id() in MishkaCmsMigration.Application.blog_kinds())
      )

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
  Provisions the Blog's pages on `site` and puts the site and its pages in the routing tables, as a
  running site's compile jobs put them, so an address is built at the page that serves it
  (`MishkaBlog.Address`). They are taken out again when the test exits.
  """
  def blog_routed!(site) do
    MishkaBlog.Provision.ensure!(site)
    site_routed!(site)
  end

  @doc """
  Puts `site` and the pages it has in the routing tables, as `blog_routed!/1` does with no Blog
  pages provisioned first.
  """
  def site_routed!(site) do
    :ok =
      MishkaCmsCore.Runtime.States.SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active,
        master: site.master
      })

    for page <-
          Ash.read!(MishkaCmsCore.Runtime.Page, tenant: site.id, authorize?: false, load: [:site]),
        do:
          :ok =
            page
            |> MishkaCmsCore.Runtime.Handlers.BootHandler.web_metadata_row("Page")
            |> MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState.save()

    ExUnit.Callbacks.on_exit(fn ->
      MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState.delete_by_site(site.name)
      MishkaCmsCore.Runtime.States.SiteState.delete(site.id)
    end)

    site
  end

  @doc """
  The items of `site` an import recorded: those with an outcome or a CMS record. A dry run records
  only each item's plan, so after one alone this is `[]`.
  """
  def imported_items(site) do
    MishkaCmsMigration.MigrationItem
    |> Ash.read!(tenant: site.id, authorize?: false)
    |> Enum.filter(&(&1.outcome || &1.target_id))
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
