# Plugins, events and UI

## mishka_installer

Repo: [mishka_installer](https://github.com/mishka-group/mishka_installer), or a local checkout or `deps/mishka_installer` if you have one. Key files: `lib/event/hook.ex`, `lib/event/event.ex`, `lib/event/module_state_compiler.ex`.

- **A plugin:**
  ```elixir
  use MishkaInstaller.Event.Hook, event: "area:thing:verb", initial: %{priority: 50}
  @impl true
  def call(state), do: {:reply, state}
  ```
  Every plugin has the same `call/1`. That is the pattern to copy for any family of modules.
- **Firing an event:** `MishkaInstaller.Event.Hook.call(event, payload, cannot_run: …, meta: %{actor: actor, site_id: site_id})`. Pass `cannot_run:` so an event whose plugins can't run is handled on purpose. Today a plugin that raises is rescued and logged, and the input comes back unchanged. Design payloads so that doesn't silently let something through, and see mishka_cms_migration#18 for the proposed `raised:` option.
- **Who is installed:** `MishkaInstaller.Event.Event.get(:event, "area:things")` returns the registered plugins with `name`, `priority`, `status` and `extension`. Filter for running status, sort by priority, and match by the plugin's own id. Don't build a parallel registry, and don't discover plugins by calling them.
- **Supervision:** an extension supervises its plugins in its `Application` (`plugins/0`), as `MishkaBlog.Application` does. Every plugin has a `child_spec`. Stopping a plugin in the installer is the on/off switch.
- **Extension points for other extensions are events.** Define the event names in one place, for example `Events.before_import_event/0`, and use those functions everywhere, including in the `use` macros.

## mishka_gervaz (admin)

Repo: [mishka_gervaz](https://github.com/mishka-group/mishka_gervaz), or a local checkout or `deps/mishka_gervaz` if you have one.

- Admin forms and tables are gervaz DSL resources: fields, types, filters, actions and error display. Never hand-write form markup or validation display for the admin.
- Before writing a helper, check gervaz for a field type or template helper. Example: `MishkaGervaz.Form.Types.Field.Json.parse_params/2` for JSON fields.
- Errors reach the user through gervaz's error handling (`MishkaGervaz.Errors.translate_error/2`) as short sentences.
- A `:link` row action always gets a `path` function. Without one, a link named `:edit` or `:show` makes gervaz build the address itself, and that crashes on the table state (mishka_gervaz#43); with a `path` any name works.
- Gervaz's own filter bar has no segmented control and no `data-testid`. A page that needs them draws its toolbar and only writes the table's URL parameters (`<prefix>_search`, `<prefix>_filter_<name>`, `<prefix>_template`), then patches; the table reads them back with `UrlSync.decode/3`. Turn the gervaz bar off with `features` that leave out `:filter`.
- A gervaz action button (Archive, Bring back) carries no test id: a test finds it by `[phx-value-event=<event>]` inside the row.
- A form window opened or closed from the server goes over the `gervaz:exec-js` bridge (`MyExtensionWeb.Modals`).
- Comments in gervaz: sentence case, saying what the code does for a caller, with no ALL-CAPS lead phrase and no history.
- A failure an admin can see (a job, an event, a delivery) gets Skip and Bring back the CMS's one way, `MishkaCmsCore.Skip`: the fields `skipped_at`, `skipped_by_id`, `skip_reason`, a `:skipped` state, the `:skip`/`:bring_back` actions with `MishkaCmsCore.Skip.Changes.Skip`/`BringBack` (they cancel the row's AshOban jobs and call `Skip.changed/1`, which cleans the item's notifications, recounts the sidebar and the bell and fires `failure:skip:changed`), the reason asked in `MishkaCmsCoreWeb.Live.Admin.Components.SkipQuestion`, an Undo toast, a grey Skipped pill beside the red Failed one and a Skipped filter. A count of open problems counts the failed state only, so a skipped row drops out with no other change; an extension's own menu numbers follow with a plugin on `failure:skip:changed` (for example its own `Plugins.SkipChanged`).

## LiveView

- **Behaviour in the markup:** `Phoenix.LiveView.JS` (`show`, `hide`, `toggle`, `add_class`, `remove_class`, `toggle_class`, `set_attribute`, `remove_attribute`, `toggle_attribute`, `focus`, `dispatch`, `push`, `exec`, `transition`), plus bindings like `phx-mounted`, `phx-click-away`, `phx-window-keydown` and `phx-remove`. `to:` takes any CSS selector, `html` and `body` included. Write a hook or JS file only when `JS` can't do it, and say what was missing.
- **A helper called from a template** (`list_path(@socket, ...)`) gets a socket without assigns there: pass it the values it needs, never read `socket.assigns` inside it.
- **Security:** authorise in `mount` and in every `handle_event`. Never trust params; check the resource's policy through Ash, as described in LiveView's security model.

## CSS, JS and HTML

- **Parse CSS with `igniter_css` and JS with `igniter_js`.** Never use regex or hand-written walkers. If a parser lacks something, add it to that library's Rust side as a path dependency while you work.
- **Tailwind decides which classes exist.** Use its compiler or scanner output, never a hand-written class extractor. Never ship project source files in `priv` or a release.
- **HTML content rules follow the WHATWG spec.** For example, a `<p>`, a heading, `<button>` and `<label>` hold phrasing content only, so a block `<div>` inside one becomes a `<span>`.

## Mishka Chelekom

- Headless components carry no Tailwind classes; styling lives only in the styled components.
- After changing component templates, regenerate the CMS bundles with the repo's export task. Don't edit `priv/cms_ui_kits/*.json` by hand.

- **A public kit block draws its first answer in the first HTTP render** (the storefront's card, grid, pricing table and coupon banner, as Blog's blocks do): its first read runs inline, on the dead render and again on the connected mount, so a search engine and a link preview get the title, text and price and the page shows no skeleton after connect. Only a later change of what is asked reads in a task, with the drawn content kept until the answer replaces it. A block of one buyer or member (download box, members only, library) reads in the background behind a skeleton, so the dead render never holds what only they may see.
