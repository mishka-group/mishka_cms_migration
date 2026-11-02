# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.EventsTest do
  @moduledoc """
  The three events an import fires through Mishka Installer, each heard by a plugin registered
  for the test: what each is handed, and what a plugin's answer changes in what is written.
  """
  use MishkaCmsMigration.DataCase, async: false

  alias MishkaCmsCore.Runtime.Redirect
  alias MishkaCmsMigration.{Events, Item, MigrationItem}
  alias MishkaCmsMigration.Test.Plugins.{ContentConverter, FinishedProbe, ItemGate}

  setup do
    for {plugin, event} <- fake_plugins(), do: register_plugin!(plugin, event)
    register_plugin!(ItemGate, Events.before_import_event())
    register_plugin!(ContentConverter, Events.convert_event())
    register_plugin!(FinishedProbe, Events.finished_event())
    Process.register(self(), :__migration_probe__)

    site = create_site!()
    %{site: site, admin: migration_admin!(site)}
  end

  defp redirect(site, from_path),
    do:
      Redirect
      |> Ash.read!(tenant: site.id, authorize?: false)
      |> Enum.find(&(&1.from_path == from_path))

  defp item(site, source_id),
    do:
      MigrationItem
      |> Ash.read!(tenant: site.id, authorize?: false)
      |> Enum.find(&(&1.source_id == source_id))

  describe "migration:item:before_import" do
    test "is handed each item about to be written, with its run and who writes it", %{
      site: site,
      admin: admin
    } do
      run = migrate!(site, admin, %{"redirect" => [redirect_row(1, "/old", "/new")]})
      run_id = run.id
      site_id = site.id

      assert_receive {:before_import, payload, meta}

      assert %{
               site_id: ^site_id,
               run_id: ^run_id,
               source: "fake",
               source_host: "old.example.com",
               action: :create,
               decision: :import,
               reason: nil,
               item: %Item{kind: "redirect", source_id: "1"}
             } = payload

      assert %{site_id: ^site_id, actor: %{id: actor_id}} = meta
      assert actor_id == admin.id
    end

    test "lets a plugin skip, take or change an item", %{site: site, admin: admin} do
      rows = [
        redirect_row(1, "/skipped", "/a", %{"gate" => "skip"}),
        redirect_row(2, "/taken", "/b", %{"gate" => "take"}),
        redirect_row(3, "/changed", "/c", %{"gate" => "rename"})
      ]

      run = migrate!(site, admin, %{"redirect" => rows})

      assert run.report.counts == %{create: 1, update: 0, skip: 2, fail: 0}
      assert is_nil(redirect(site, "/skipped")) and is_nil(redirect(site, "/taken"))
      assert redirect(site, "/changed").to == "/renamed"
      assert %{outcome: :skipped, reason: "held back", target_id: nil} = item(site, "1")
      assert %{outcome: :skipped, reason: reason} = item(site, "2")
      assert byte_size(reason) > 0
    end

    test "is not fired by a dry run", %{site: site, admin: admin} do
      site
      |> create_run!(admin, %{"redirect" => [redirect_row(1, "/old", "/new")]})
      |> dry_run!(admin)

      refute_received {:before_import, _payload, _meta}
    end

    test "skips every item while one of its plugins cannot run", %{site: site, admin: admin} do
      MishkaCmsCore.Test.EventCannotRun.stub!(Events.before_import_event())

      run = migrate!(site, admin, %{"redirect" => [redirect_row(1, "/old", "/new")]})

      assert run.report.counts == %{create: 0, update: 0, skip: 1, fail: 0}
      assert is_nil(redirect(site, "/old"))
      assert %{outcome: :skipped, target_id: nil} = item(site, "1")
    end
  end

  describe "migration:content:convert" do
    test "converts a piece the source could not, and an unconverted one is kept as escaped text",
         %{
           site: site,
           admin: admin
         } do
      content = [
        %{"html" => "<p>Moved.</p>"},
        %{"name" => "shout", "attrs" => %{"level" => "2"}, "raw" => "see here"},
        %{"name" => "gallery", "raw" => "<b>[gallery]</b>"}
      ]

      run =
        migrate!(site, admin, %{
          "redirect" => [redirect_row(1, "/old", "/new", %{"content" => content})]
        })

      run_id = run.id

      assert_receive {:convert,
                      %{name: "shout", attrs: %{"level" => "2"}, raw: "see here", html: nil} =
                        payload, %{actor: %{}}}

      assert %{run_id: ^run_id, kind: "redirect", source_id: "1", source: "fake"} = payload
      assert_receive {:convert, %{name: "gallery"}, _meta}
      refute_received {:convert, %{name: nil}, _meta}

      description = redirect(site, "/old").description
      assert description =~ "<p>Moved.</p>"
      assert description =~ "<strong>SEE HERE</strong>"
      refute description =~ "<b>"
      assert description =~ "[gallery]"
    end

    test "skips an item with a piece to convert while one of its plugins cannot run", %{
      site: site,
      admin: admin
    } do
      MishkaCmsCore.Test.EventCannotRun.stub!(Events.convert_event())

      rows = [
        redirect_row(1, "/to-convert", "/a", %{"content" => [%{"name" => "shout", "raw" => "hi"}]}),
        redirect_row(2, "/converted", "/b", %{"content" => [%{"html" => "<p>ready</p>"}]})
      ]

      run = migrate!(site, admin, %{"redirect" => rows})

      assert run.report.counts == %{create: 1, update: 0, skip: 1, fail: 0}
      assert is_nil(redirect(site, "/to-convert"))
      assert redirect(site, "/converted").description == "<p>ready</p>"
      assert %{outcome: :skipped, reason: "plugins_cannot_run", target_id: nil} = item(site, "1")
    end
  end

  describe "migration:import:finished" do
    test "is handed the import's report once the run is done", %{site: site, admin: admin} do
      run = migrate!(site, admin, %{"redirect" => [redirect_row(1, "/old", "/new")]})
      run_id = run.id
      site_id = site.id

      assert_receive {:import_finished, payload, %{actor: %{}, site_id: ^site_id}}

      assert %{
               run_id: ^run_id,
               site_id: ^site_id,
               source: "fake",
               source_host: "old.example.com",
               report: %{
                 counts: %{create: 1},
                 kinds: [%{kind: "redirect"}],
                 entries: [%{source_id: "1"}]
               }
             } = payload

      assert MishkaCmsMigration.get_run!(run.id, actor: admin, tenant: site.id).status == :done
    end

    test "is not fired by a dry run", %{site: site, admin: admin} do
      site
      |> create_run!(admin, %{"redirect" => [redirect_row(1, "/old", "/new")]})
      |> dry_run!(admin)

      refute_received {:import_finished, _payload, _meta}
    end
  end
end
