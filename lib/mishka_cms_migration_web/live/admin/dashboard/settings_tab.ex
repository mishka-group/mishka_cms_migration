# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Live.Admin.Dashboard.SettingsTab do
  @moduledoc """
  The body of the Settings page's Migration tab (`MishkaCmsMigrationWeb.SettingsPanel`): a New
  import button for each installed source (`MishkaCmsMigration.Source.all/0`), and under them the
  admin's latest runs as the migration page's own Gervaz table (`MishkaCmsMigration.MigrationRun`),
  without writing its filters and page into the Settings address (`url_sync: false`) and without the
  row's expand control, whose details the migration page draws and the Settings page cannot
  (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.SettingsTab.RunsTemplate`).

  A button links to the migration page with `?new_import=<source>`, where the page opens the same
  New import form as its own button does (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.Index`).
  A run's step buttons and its expanded details are that page's, which the table's Items link and
  the Open the migration page link lead to.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  alias MishkaCmsMigration.{MigrationRun, Source}
  alias MishkaCmsMigrationWeb.Live.Admin.Dashboard.SettingsTab.RunsTemplate

  @page "/admin/dashboard/migration"

  @impl true
  def mount(socket), do: {:ok, assign(socket, :sources, Source.all())}

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} data-role="migration-settings-tab">
      <div class="mb-3 flex flex-wrap items-center gap-2">
        <.link
          :for={source <- @sources}
          navigate={@page <> "?new_import=" <> source.id()}
          data-role="migration-settings-new-import"
          data-source={source.id()}
          class="inline-flex h-[34px] items-center gap-1.5 rounded-[10px] bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] px-3 text-[12px] font-bold text-white shadow-[0_5px_14px_rgba(79,75,204,0.28)]"
        >
          <.icon name="hero-plus" class="size-[14px]" /> {gettext("New import")} ({Source.label(
            source.id()
          )})
        </.link>
        <.link
          navigate={@page}
          data-role="migration-settings-open"
          class="ms-auto text-[12.5px] font-semibold text-[#4f4bcc]"
        >
          {gettext("Open the migration page")}
        </.link>
      </div>

      <.live_component
        module={MishkaGervaz.Table.Web.Live}
        id="migration-settings-runs"
        resource={MigrationRun}
        current_user={@current_user}
        url_sync={false}
        template={RunsTemplate}
      />
    </div>
    """
  end

  @impl true
  def update(assigns, socket), do: {:ok, socket |> assign(assigns) |> assign(:page, @page)}
end
