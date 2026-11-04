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
  alias MishkaCmsMigration.{Events, MigrationItem}
  alias MishkaCmsMigration.Source.Item
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

  defp plugins_on(event),
    do: :event |> MishkaInstaller.Event.Event.get(event) |> Enum.map(& &1.name)

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
               outcome: :created,
               reason: nil,
               item: %Item{kind: "redirect", source_id: "1"}
             } = payload

      assert payload |> Map.keys() |> Enum.sort() ==
               [:item, :outcome, :reason, :run_id, :site_id, :source, :source_host]

      assert %{site_id: ^site_id, actor: %{id: actor_id}} = meta
      assert actor_id == admin.id
    end

    test "is never handed an item an admin left out or mapped to a CMS record", %{
      site: site,
      admin: admin
    } do
      migrate!(site, admin, %{"redirect" => [redirect_row(9, "/kept", "/k")]})
      assert_receive {:before_import, %{item: %Item{source_id: "9"}}, _meta}

      rows = [
        redirect_row(1, "/one", "/1"),
        redirect_row(2, "/two", "/2"),
        redirect_row(3, "/three", "/3")
      ]

      run = site |> create_run!(admin, %{"redirect" => rows}) |> dry_run!(admin)
      site |> item("1") |> MishkaCmsMigration.leave_out_item!(actor: admin, tenant: site.id)

      site
      |> item("2")
      |> MishkaCmsMigration.map_item!(redirect(site, "/kept").id, actor: admin, tenant: site.id)

      import!(run, admin)

      assert_received {:before_import, %{item: %Item{source_id: "3"}}, _meta}
      refute_received {:before_import, %{item: %Item{source_id: "1"}}, _meta}
      refute_received {:before_import, %{item: %Item{source_id: "2"}}, _meta}
    end

    test "says :updated for an item a second run writes over its earlier row", %{
      site: site,
      admin: admin
    } do
      migrate!(site, admin, %{"redirect" => [redirect_row(1, "/old", "/new")]})
      assert_receive {:before_import, %{outcome: :created}, _meta}

      migrate!(site, admin, %{"redirect" => [redirect_row(1, "/old", "/newer")]})
      assert_receive {:before_import, %{outcome: :updated, item: %Item{source_id: "1"}}, _meta}
      assert redirect(site, "/old").to == "/newer"
    end

    test "lets a plugin skip, take or change an item", %{site: site, admin: admin} do
      rows = [
        redirect_row(1, "/skipped", "/a", %{"gate" => "skip"}),
        redirect_row(2, "/taken", "/b", %{"gate" => "take"}),
        redirect_row(3, "/changed", "/c", %{"gate" => "rename"})
      ]

      run = migrate!(site, admin, %{"redirect" => rows})

      assert run.report.counts == %{created: 1, updated: 0, skipped: 2, failed: 0, undecided: 0}
      assert is_nil(redirect(site, "/skipped")) and is_nil(redirect(site, "/taken"))
      assert redirect(site, "/changed").to == "/renamed"
      assert %{outcome: :skipped, reason: "held back", target_id: nil} = item(site, "1")
      assert %{outcome: :skipped, reason: "taken by the gate"} = item(site, "2")
    end

    @tag capture_log: true
    test "skips an item a plugin raises on or answers with something that is not the payload, and writes the rest",
         %{site: site, admin: admin} do
      rows = [
        redirect_row(1, "/raised-on", "/a", %{"gate" => "raise"}),
        redirect_row(2, "/fine", "/b"),
        redirect_row(3, "/not-the-payload", "/c", %{"gate" => "nope"})
      ]

      run = migrate!(site, admin, %{"redirect" => rows})

      assert run.report.counts == %{created: 1, updated: 0, skipped: 2, failed: 0, undecided: 0}
      assert is_nil(redirect(site, "/raised-on")) and is_nil(redirect(site, "/not-the-payload"))
      assert %{outcome: :skipped, reason: "plugins_failed", target_id: nil} = item(site, "1")
      assert %{outcome: :skipped, reason: "plugins_failed", target_id: nil} = item(site, "3")
      assert redirect(site, "/fine")
    end

    test "runs only the plugins installed on it, none of the extension's own" do
      assert plugins_on(Events.before_import_event()) == [ItemGate]
    end

    test "writes the item as the import made it once an operator stopped every plugin of it", %{
      site: site,
      admin: admin
    } do
      {:ok, _stopped} =
        MishkaInstaller.Event.Event.stop(:event, Events.before_import_event(), false)

      run =
        migrate!(site, admin, %{
          "redirect" => [redirect_row(1, "/old", "/new", %{"gate" => "skip"})]
        })

      assert run.report.counts == %{created: 1, updated: 0, skipped: 0, failed: 0, undecided: 0}
      assert redirect(site, "/old").to == "/new"
      assert %{outcome: :created} = item(site, "1")
      refute_received {:before_import, _payload, _meta}
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

      assert run.report.counts == %{created: 0, updated: 0, skipped: 1, failed: 0, undecided: 0}
      assert is_nil(redirect(site, "/old"))
      assert %{outcome: :skipped, target_id: nil} = item(site, "1")
    end
  end

  describe "migration:content:convert" do
    test "converts a piece the source could not, and an unconverted one is kept as escaped text and named",
         %{
           site: site,
           admin: admin
         } do
      content = [
        %{"html" => "<p>Moved.</p>"},
        %{"name" => "shout", "attrs" => %{"level" => "2"}, "raw" => "see here"},
        %{"name" => "gallery", "raw" => "<b>[gallery]</b>"}
      ]

      items = %{"redirect" => [redirect_row(1, "/old", "/new", %{"content" => content})]}
      dry = site |> create_run!(admin, items) |> dry_run!(admin)
      run = import!(dry, admin)
      run_id = run.id

      assert [%{outcome: :created, reason: "unconverted: shout, gallery"}] = dry.report.entries
      assert [%{outcome: :created, reason: "unconverted: gallery"}] = run.report.entries
      assert item(site, "1").reason == "unconverted: gallery"

      assert_receive {:convert,
                      %{name: "shout", attrs: %{"level" => "2"}, raw: "see here", html: nil} =
                        payload, %{actor: %{}}}

      assert %{run_id: ^run_id, kind: "redirect", source_id: "1", source: "fake"} = payload

      assert payload |> Map.keys() |> Enum.sort() ==
               [
                 :attrs,
                 :html,
                 :kind,
                 :name,
                 :raw,
                 :run_id,
                 :site_id,
                 :source,
                 :source_host,
                 :source_id
               ]

      assert_receive {:convert, %{name: "gallery"}, _meta}
      refute_received {:convert, %{name: nil}, _meta}

      description = redirect(site, "/old").description
      assert description =~ "<p>Moved.</p>"
      assert description =~ "<strong>SEE HERE</strong>"
      refute description =~ "<b>"
      assert description =~ "[gallery]"
    end

    @tag capture_log: true
    test "skips an item whose piece a plugin raises on, instead of writing it unconverted", %{
      site: site,
      admin: admin
    } do
      content = [%{"name" => "explode", "raw" => "boom"}]

      run =
        migrate!(site, admin, %{
          "redirect" => [redirect_row(1, "/old", "/new", %{"content" => content})]
        })

      assert run.report.counts == %{created: 0, updated: 0, skipped: 1, failed: 0, undecided: 0}
      assert is_nil(redirect(site, "/old"))
      assert %{outcome: :skipped, reason: "plugins_failed"} = item(site, "1")
    end

    test "runs only the plugins installed on it, none of the extension's own" do
      assert plugins_on(Events.convert_event()) == [ContentConverter]
    end

    test "keeps a piece as escaped text once an operator stopped every plugin of it", %{
      site: site,
      admin: admin
    } do
      {:ok, _stopped} = MishkaInstaller.Event.Event.stop(:event, Events.convert_event(), false)
      content = [%{"name" => "shout", "raw" => "<b>hi</b>"}]

      run =
        migrate!(site, admin, %{
          "redirect" => [redirect_row(1, "/old", "/new", %{"content" => content})]
        })

      assert run.report.counts == %{created: 1, updated: 0, skipped: 0, failed: 0, undecided: 0}
      assert %{outcome: :created, reason: "unconverted: shout"} = item(site, "1")
      description = redirect(site, "/old").description
      assert description =~ "hi"
      refute description =~ "<b>" or description =~ "<strong>"
      refute_received {:convert, _payload, _meta}
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

      assert run.report.counts == %{created: 1, updated: 0, skipped: 1, failed: 0, undecided: 0}
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
                 counts: %{created: 1},
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
