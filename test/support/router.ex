# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.TestRouter do
  @moduledoc """
  The routes this extension's suite drives: the CMS's admin dashboard, which is where the extension
  shows up (a tab of the Settings page and a button on another extension's dashboard).

  The pipeline is the CMS's `:browser` pipeline: the session, the site of the request's host, the
  signed-in user and the actor. Dropping any of them changes what a page does — tenancy and
  authorization are enforced through them, so a suite that skipped them would be testing a different
  application.

  The admin pages are behind the CMS's entry gate: anything held under `admin:dashboard`.
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router
  use AshAuthentication.Phoenix.Router

  import MishkaCmsCore.ExtensionRouter
  import MishkaCmsCore.Runtime.Plugs.SiteLookupPlug, only: [confirm_tenant: 2]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MishkaCmsMigration.TestLayouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug MishkaCmsCore.Runtime.Plugs.SiteLookupPlug
    plug :load_from_session
    plug :confirm_tenant
    plug :set_actor, :user
  end

  scope "/admin/dashboard" do
    pipe_through [:browser]

    ash_authentication_live_session :test_authenticated_routes,
      on_mount: [
        {MishkaCmsCore.LiveUserAuth, :live_user_required},
        {MishkaCmsCore.LiveUserAuth, {:require_permission, [{:under, "admin:dashboard"}]}}
      ] do
      extension_routes(:admin)
    end
  end
end
