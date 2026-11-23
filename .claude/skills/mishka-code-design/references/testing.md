# Testing

Copy the repo's test support (`DataCase`, factories, test plugins) and the style of its nearest test file.

## What a test proves

A test checks behaviour: what the code does for a user or a caller.

- A dry run writes nothing.
- A re-run updates and doesn't duplicate.
- A record edited by a person is kept.
- Site B can't see site A's records.
- A user without the permission is refused.
- An event fires with its documented payload.
- A failure is recorded with a reason.

Assert on outcomes and meaning: status, counts, which records exist, error type and field. Don't assert on exact strings, full markup or the order of unrelated output. A loose match (`=~ "already redirects"`) is enough where wording may change.

## Waiting without timeouts

Never use `Process.sleep`, retry or poll loops, "eventually" helpers, or a bigger `assert_receive` timeout. Make the test wait on the real event:

- **A process that sets up in `handle_continue`:** call it once with any sync call. The reply comes after `handle_continue` has run. For example, call the Oban producer before sending it signals.
- **A process that must be done:** `Process.monitor` with `assert_receive {:DOWN, …}`, or `:sys.get_state/1` as a barrier.
- **Asynchronous work that announces itself:** wait for the message or telemetry event it sends. If it sends none and a test needs it, add a telemetry event to the library code.
- **A limit or a delay** (a timeout, a retry wait): never let the test sit through it. Give the code a value of 0 (or the smallest) and assert on the telemetry event that reports the decision, such as the `:wait` it chose or the `:outcome` it ended with. See `references/telemetry.md`.
- **Jobs:** Oban `testing: :manual`, then `perform_job`, `Oban.drain_queue`, or AshOban's `assert_triggered`.
- **Plugins:** core's `Test.Installer.await/1` and the repo's `register_plugin!` helpers.

A flaky test gets a deterministic fix, and sometimes the race is in the library code. Prove it with `mix test <file> --repeat-until-failure 300`. To flush out races, also run it under load (`ELIXIR_ERL_OPTIONS="+S 2:2"` plus CPU load).

## External systems

Test against the real thing: for example a real WordPress in Docker, seeded with realistic data. Unit tests replay responses recorded from it, and integration tests tagged for the live service are excluded by default. Never hand-write mock JSON that the real system wouldn't send. Scrub secrets from recordings.

## Running

- While working, run only the tests of the files you changed.
- Run the full gate once at the end: the repo's CI alias (`mix ci` where it exists) and, for an Ash repo, a fresh `MIX_ENV=test mix ash.codegen setup && mix test`, then a few random seeds.
- Where GitHub Actions is off for a repo, this local gate is the check.
- Check background test runs for hangs, and use `/bin/rm`, `/bin/cp` and `/bin/ls`, because the shell aliases prompt and hang.

## The final check

When a task is done, a separate check tests it twice over:

- **as a developer:** the gate, reading the docs, probing edge cases;
- **as an end user:** in the admin UI through the browser, where there is UI.

Only then report it as ready.

## Waiting for a page that loads in the background

- A page that reads with `assign_async/4` and draws a gervaz component inside the result starts the component's own read only after the page's read has been drawn: wait twice (`render_async/2`, then `render_async/2`), never with a sleep.
- A table reloaded by a message the page sends itself (`send_update/2`) starts its read after that message: call `render/1` first (the page answers it after the message), then `render_async/2`.
- Prove a wait is not a race with `mix test --repeat-until-failure 40 <file>`.

## A payment stage is done when the real sandbox says so

A mock answers what its authors fixed: stripe-mock never returns a payment that was paid, refunded or pending, and it knows nothing of the account's own defaults (a sandbox that sells as merchant of record, which refused every checkout until products carried a tax category, a thing no mock test showed). Run the stage's truth test against the real sandbox once before calling it done, with the key only in the environment of the test command, and make it clean up what it made at the provider. The fast suite stubs only what the mock cannot answer, by path, from the SDK's own objects (`Support.StripeMock.stub!/1`).

## Proving a race

The sandbox gives every test one shared connection, so requests in a test take turns and a read-then-write bug passes. A rule that must hold under concurrency (a download count at its limit, a claim that only one caller wins) is proved in its own module that switches the repo to real connections (`Sandbox.mode(Repo, :auto)`), writes committed rows and deletes the site, which takes its rows with it, when it ends; it starts many `Task.async_stream` callers at the rule and asserts the exact number that got through. Break the rule once (leave the limit out of the update) and see the test fail, so it is known to catch something.

## Email in tests

The accounts a test makes get the core's confirmation email, so `assert_email_sent/0` finds the wrong one: keep the receipts apart (`Support.Store.sent_emails/0`, `flush_mail!/0`; mail runs inline in tests, so a drain waits for nothing). The function given to `assert_email_sent/1` must end in a truthy value: a `refute` ends in `nil`.

## Browser runs sign in once

A browser run signs in once per role and saves the browser's storage state (Playwright `storageState`), and every later page and run reuses it. Posting the sign-in form again and again trips the CMS sign-in limiter, and each locked try resets the lock, so the run stalls for hours. If the limiter is hit on a test copy, restart that copy's server (the limiter lives in memory) instead of waiting.
