# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Provision do
  @moduledoc """
  What setting the migration up on a site gives it: the permission names its runs are gated by
  (`permissions/0`), so a site's admin can be granted them. The names are shared by every site, so
  the first site's install creates them and every later one finds them; the system writes them,
  whoever asked, through `MishkaCmsCore.Install.Bootstrap.ensure_permissions/1`, as
  `MishkaCmsCore.Runtime.ExtensionProvision` does for every extension. The extension ships no
  components, pages or snippets.

  The module is the extension's plugin on `installer:extension:install`
  (`MishkaCmsCore.Install.Extensions`): subscribing is what makes the extension installable, and
  `:extra` is what the installer's picker shows. It answers the payload whose `key` is
  `"mishka_cms_migration"` with `install/2`'s report, appended to `reports`, and hands every other
  payload on untouched. Installing needs `admin:dashboard:runtime:site` (`required/0`); a site's
  admin installs it only on their own site. With no actor it runs only while the CMS itself is
  being installed. `MishkaCmsMigration.Provision.Settings` registers the settings the installer
  records an install in.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  use MishkaInstaller.Event.Hook,
    event: "installer:extension:install",
    initial: %{
      priority: 60,
      extra: [
        %{
          label: gettext_noop("Migration"),
          summary: gettext_noop("Move a site's content here from another CMS"),
          fields: []
        }
      ]
    }

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Install
  alias MishkaCmsCore.Install.Bootstrap
  alias MishkaCmsCore.Runtime.ExtensionProvision

  @permissions [
    {"admin:dashboard:migration",
     "Moving a site from another CMS on the dashboard: migration runs, their dry runs, imports and reports."},
    {"admin:api:migration", "Migration runs and their items over the admin API."}
  ]

  @required ["admin:dashboard:runtime:site"]

  @key "mishka_cms_migration"

  @impl true
  def call(%{key: @key, site_id: site_id, ask: :install, reports: reports} = payload)
      when is_binary(site_id),
      do: {:reply, %{payload | reports: reports ++ [install(site_id, Map.get(payload, :actor))]}}

  def call(payload), do: {:reply, payload}

  @doc "The permission names the migration's runs are gated by, each with its description."
  @spec permissions() :: [{String.t(), String.t()}]
  def permissions, do: @permissions

  @doc "What a person needs to install the migration on a site."
  @spec required() :: [String.t()]
  def required, do: @required

  @doc """
  Installs the migration on `site_id` as `actor` and answers the report the installer shows, in the
  shape of `t:MishkaCmsCore.Runtime.ExtensionProvision.report/0` (`permissions` names the ones
  created by this install), or `%{error: message}` when `actor` may not.
  """
  @spec install(String.t(), map() | nil) :: ExtensionProvision.report() | %{error: String.t()}
  def install(site_id, actor) do
    case refusal(site_id, actor) do
      nil -> created() |> report()
      message -> %{error: message}
    end
  end

  defp refusal(_site_id, nil) do
    if Install.installed?(), do: missing_message(@required)
  end

  defp refusal(site_id, %{site_id: own}) when is_binary(own) and own != site_id,
    do: gettext("A site's admin sets the migration up on their own site only.")

  defp refusal(_site_id, actor) do
    actor = AccessPermissions.with_permissions(actor)

    case Enum.reject(@required, &AccessPermissions.match?(actor, %{}, permissions: [&1])) do
      [] -> nil
      names -> missing_message(names)
    end
  end

  defp missing_message(names),
    do:
      gettext("Setting the migration up needs these permissions: %{names}",
        names: Enum.join(names, ", ")
      )

  defp created do
    {:ok, %{created: created}} = Bootstrap.ensure_permissions(@permissions)
    Enum.map(created, & &1.name)
  end

  defp report(created) do
    %{
      version: :mishka_cms_migration |> Application.spec(:vsn) |> to_string(),
      permissions: created,
      components: [],
      pages: [],
      snippets: [],
      renamed_pages: [],
      skipped_pages: []
    }
  end
end

defmodule MishkaCmsMigration.Provision.Settings do
  @moduledoc """
  Registers the two per-site settings every installable extension carries, under the Migration tab
  of the Settings page, through `settings:register`: `mishka_cms_migration.installed`, the version a
  site was set up at, which the installer writes after an install, and
  `mishka_cms_migration.active`, the switch that hides the extension from a site
  (`MishkaCmsCore.Install.Extensions.settings/2`).
  """

  use MishkaInstaller.Event.Hook, event: "settings:register", initial: %{priority: 50}

  alias MishkaCmsCore.Install.Extensions

  @impl true
  def call(%{definitions: definitions} = data),
    do:
      {:reply,
       %{
         data
         | definitions: definitions ++ Extensions.settings(:mishka_cms_migration, "migration")
       }}

  def call(data), do: {:reply, data}
end
