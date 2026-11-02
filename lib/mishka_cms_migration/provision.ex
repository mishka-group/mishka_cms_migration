# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Provision do
  @moduledoc """
  What setting the migration up on a site gives it: the permission names its runs are gated by
  (`permissions/0`), so a site's admin can be granted them. The names are shared by every site, so
  the first site's install creates them and every later one finds them; the system writes them,
  whoever asked, as `MishkaCmsCore.Runtime.ExtensionProvision.ensure_permissions/1` does for every
  extension. The extension ships no components, pages or snippets.

  It runs when an admin installs the extension on a site (`MishkaCmsMigration.Plugins.Installer`),
  and needs `admin:dashboard:runtime:site` (`required/0`); a site's admin installs it only on their
  own site. With no actor it runs only while the CMS itself is being installed.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Install
  alias MishkaCmsCore.Runtime.ExtensionProvision

  @permissions [
    {"admin:dashboard:migration",
     "Moving a site from another CMS on the dashboard: migration runs, their dry runs, imports and reports."},
    {"admin:api:migration", "Migration runs and their items over the admin API."}
  ]

  @required ["admin:dashboard:runtime:site"]

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
      nil -> report(ExtensionProvision.ensure_permissions(%{permissions: @permissions}))
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
