# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Playground do
  @moduledoc """
  Tries the migration engine by hand over the suite's fake source
  (`MishkaCmsMigration.Test.Plugins.FakeSource`), on the test database, inside one transaction that
  is rolled back when the session ends.

  `mix playground` walks through a run step by step and stops. `iex -S mix playground` does the
  same and stays in IEx with this module, on a new, empty site with an admin who may run
  migrations and write redirects:

      Playground.import([%{"id" => 1, "from" => "/old", "to" => "/new"}]).report.counts
      Playground.redirects()
      Playground.edit("/old", "/kept-by-admin")
      Playground.import([%{"id" => 1, "from" => "/old", "to" => "/from-source"}]).report.entries

  `Playground.help/0` lists the functions. `rows` is a list of the source's redirect rows, each a
  map with an `"id"` and the `"from"` and `"to"` addresses, or a map of kind to rows. Redirects are
  what it writes here: a `"note"` row is reported as skipped (`no_target`), and a `"page"` row goes
  to the CMS page target (`MishkaCmsMigration.Targets.CmsPage`), which this admin may not use. A run
  created here is the admin's and goes through the domain's own actions and policies, and its job
  runs inline with its retries, so a run that fails ends as `:failed` with its reason.
  """

  alias MishkaCmsCore.Runtime.Redirect
  alias MishkaCmsMigration.MigrationItem
  alias MishkaCmsMigration.Test.Factory

  @context {__MODULE__, :context}

  @doc """
  Starts over with a new, empty site and an admin of it, the ones every other function uses. What
  was written on the earlier site stays in the transaction but is out of reach.
  """
  @spec reset() :: :ok
  def reset do
    unique = System.unique_integer([:positive])

    site =
      MishkaCmsCore.Test.Factory.create_site!(
        host: "playground#{unique}.com",
        name: "Playground #{unique}"
      )

    :persistent_term.put(@context, %{site: site, admin: Factory.migration_admin!(site)})
  end

  @doc "The site the functions work on."
  def site, do: :persistent_term.get(@context).site

  @doc "The admin of that site: the actor of every run and every redirect read or edit."
  def admin, do: :persistent_term.get(@context).admin

  @doc """
  Creates a run over `rows` and dry runs it. Nothing is written to the CMS: the report on the
  returned run says what an import would do.
  """
  def dry_run(rows) do
    site()
    |> Factory.create_run!(admin(), kinds(rows))
    |> perform(&MishkaCmsMigration.start_dry_run!/2)
  end

  @doc """
  Creates a run over `rows`, dry runs it and imports it. Run it again with other rows to see what a
  second run updates, skips and leaves to the admin. A run whose dry run failed is returned as it
  is, without an import.
  """
  def import(rows), do: rows |> dry_run() |> imported()

  @doc """
  Runs the migration jobs that are waiting, retries included, as Oban would, and answers Oban's
  counts. The jobs' log lines are left out; a run that failed says why in its `reason`.
  """
  def drain do
    Logger.put_process_level(self(), :none)
    Oban.drain_queue(queue: :migration, with_scheduled: true, with_recursion: true)
  after
    Logger.delete_process_level(self())
  end

  @doc "The CMS's redirects of the site as `{from_path, to}`, read as the admin."
  @spec redirects() :: [{String.t(), String.t()}]
  def redirects, do: Enum.map(read_redirects(), &{&1.from_path, &1.to})

  @doc """
  What the migration recorded for each item, as `{kind, source_id, plan, outcome, reason}`, read as
  the admin: what the last dry run would do with it, and what the last import did and why (`nil`
  before an import met it).
  """
  @spec items() :: [{String.t(), String.t(), atom() | nil, atom() | nil, String.t() | nil}]
  def items do
    MigrationItem
    |> Ash.Query.sort(:source_id)
    |> Ash.read!(actor: admin(), tenant: site().id)
    |> Enum.map(&{&1.source_kind, &1.source_id, &1.plan, &1.outcome, &1.reason})
  end

  @doc """
  Changes where the redirect from `from_path` goes, as the admin does in the CMS. The admin's value
  stays: a later import that changes the same source row reports it as skipped with
  `"edited_in_cms"`. An address the redirect refuses comes back as the error.
  """
  @spec edit(String.t(), String.t()) :: :ok | {:error, :no_such_redirect | Ash.Error.t()}
  def edit(from_path, to),
    do: read_redirects() |> Enum.find(&(&1.from_path == from_path)) |> edit_to(to)

  @doc "Prints the functions of this module."
  @spec help() :: :ok
  def help do
    IO.puts("""

    Playground, on a new empty site with its admin (rolled back when IEx exits):

      Playground.import(rows)       dry runs and imports rows, returns the run
      Playground.dry_run(rows)      dry runs rows, writes no redirect or item, returns the run
      Playground.redirects()        the CMS's redirects as {from, to}
      Playground.items()            what the migration recorded for each item
      Playground.edit(from, to)     changes a redirect as the admin does in the CMS
      Playground.reset()            a new empty site and admin
      Playground.site() / admin()   the site and the admin

    rows: [%{"id" => 1, "from" => "/old", "to" => "/new"}], or a map of kind to rows.
    """)
  end

  defp read_redirects do
    Redirect
    |> Ash.Query.sort(:from_path)
    |> Ash.read!(actor: admin(), tenant: site().id)
  end

  defp edit_to(nil, _to), do: {:error, :no_such_redirect}

  defp edit_to(redirect, to) do
    redirect
    |> Ash.Changeset.for_update(:update, %{to: to}, actor: admin(), tenant: site().id)
    |> Ash.update()
    |> edited()
  end

  defp edited({:ok, _redirect}), do: :ok
  defp edited({:error, error}), do: {:error, error}

  defp imported(%{status: :dry_run} = run), do: perform(run, &MishkaCmsMigration.start_import!/2)
  defp imported(run), do: run

  defp perform(run, start) do
    start.(run, actor: admin(), tenant: site().id)
    drain()

    MishkaCmsMigration.get_run!(run.id,
      actor: admin(),
      tenant: site().id,
      load: [:created_count, :updated_count, :skipped_count, :failed_count]
    )
  end

  defp kinds(rows) when is_list(rows), do: %{"redirect" => rows}
  defp kinds(%{} = kinds), do: kinds
end

defmodule Playground.Session do
  @moduledoc """
  Starts what the walk-through needs and puts everything back, the way `test/test_helper.exs` and
  `MishkaCmsMigration.DataCase` do for the suite.

  `start!/0` boots the runtime with the suite's options, opens one sandboxed connection shared by
  every process for the whole session, and registers the fake source and the redirect target as
  `mishka_installer` plugins. The runtime is started from the process that runs the script, which
  is gone by the time IEx opens, so its supervisor is unlinked from it to stay up.

  `finish/2` ends the session. In a script it stops the sandbox owner, which rolls back every
  write, unregisters the plugins and checks the tables hold what they held before. Under IEx it
  keeps the sandbox open, so the rollback happens when the VM exits, and a plugin a killed session
  leaves registered is swept at the next boot.
  """

  import MishkaCmsMigration.Test.Factory, only: [fake_plugins: 0]

  alias Ecto.Adapters.SQL.Sandbox
  alias MishkaCmsCore.Accounts.{Permission, User}
  alias MishkaCmsCore.Runtime.{Redirect, Site}
  alias MishkaCmsMigration.{MigrationItem, MigrationRun, Repo}
  alias MishkaInstaller.Event.{Event, EventHandler}

  @resources [Site, User, Permission, Redirect, MigrationRun, MigrationItem]

  @doc "Boots the runtime, opens the shared sandbox and registers the fake plugins."
  @spec start!() :: %{owner: pid(), before: map()}
  def start! do
    :ok =
      MishkaCmsCore.Test.Boot.start!(
        otp_app: :mishka_cms_migration,
        repo: Repo,
        endpoint: MishkaCmsMigration.TestEndpoint,
        plugins: MishkaCmsCore.Application.plugins() ++ MishkaCmsMigration.Application.plugins(),
        sweep: ["Elixir.MishkaCmsMigration.Test.Plugins."]
      )

    MishkaCmsCore.TestSupervisor |> Process.whereis() |> Process.unlink()
    owner = Sandbox.start_owner!(Repo, shared: true)

    for {module, event} <- fake_plugins() do
      {:ok, _registered} =
        Event.write(%{name: module, event: event, extension: :mishka_installer, status: :started})

      :ok = EventHandler.do_compile(event, :start, false)
    end

    %{owner: owner, before: counts()}
  end

  @doc """
  Ends the session after a walk-through that ran `checks` checks and failed `failed` of them. In a
  script it rolls back, counts the rollback as one more check and raises when any check failed, so
  the command exits with an error; under IEx it hands over a new site and prints the help.
  """
  @spec finish(map(), %{checks: non_neg_integer(), failed: non_neg_integer()}) :: :ok
  def finish(session, tour), do: finish(session, tour, IEx.started?())

  defp finish(_session, tour, true) do
    IO.puts("\n" <> summary(tour))
    Playground.reset()
    Playground.help()
  end

  defp finish(session, tour, false) do
    Sandbox.stop_owner(session.owner)
    Sandbox.mode(Repo, :auto)
    for {module, _event} <- fake_plugins(), do: Event.unregister(:name, module, false)

    left = counts()
    IO.puts("")
    conclude(rolled_back(left, session.before, tour))
  end

  defp rolled_back(same, same, tour) do
    IO.puts("Rolled back: nothing was left in the test database.")
    %{tour | checks: tour.checks + 1}
  end

  defp rolled_back(left, _before, tour) do
    IO.puts("Not rolled back, the tables hold: #{inspect(left)}")
    %{tour | checks: tour.checks + 1, failed: tour.failed + 1}
  end

  defp conclude(%{failed: 0} = tour), do: IO.puts(summary(tour))
  defp conclude(tour), do: Mix.raise(summary(tour))

  defp summary(%{checks: checks, failed: 0}), do: "All #{checks} checks passed."
  defp summary(%{checks: checks, failed: failed}), do: "#{failed} of #{checks} checks failed."

  defp counts, do: Map.new(@resources, &{&1, count(AshPostgres.DataLayer.Info.table(&1))})

  defp count(table) do
    %{rows: [[count]]} = Repo.query!(~s|SELECT count(*) FROM "#{table}"|)
    count
  end
end

defmodule Playground.Tour do
  @moduledoc """
  The walk-through: thirteen steps over a real run on the fake source. Each step prints what it
  does, what the code answered and, for each behaviour it expects, a tick or a cross. `run/0`
  answers how many checks there were and how many failed.

  The steps share one site, so what one step leaves in the CMS is what the next one starts from.
  A run's job is drained from the `migration` queue in this process, as the suite's factory does.
  A job that fails is drained with its retries and without its log lines, so the run ends the way
  it ends after Oban's last attempt.
  """

  import MishkaCmsCore.Test.Factory, only: [create_site!: 0, create_user_with_permissions!: 2]
  import MishkaCmsMigration.Test.Factory

  alias MishkaCmsMigration.{MigrationRun, Report, Repo}

  @rows [
    redirect_row(1, "/old-one", "/one"),
    redirect_row(2, "/old-two", "/two"),
    redirect_row(3, "/old-three", "/three")
  ]

  @defaults %{
    "authors" => "connect",
    "pages" => "draft",
    "post_address" => "blog",
    "comments" => false
  }

  @doc "Plays every step and answers `%{checks: total, failed: how_many}`."
  @spec run() :: %{checks: non_neg_integer(), failed: non_neg_integer()}
  def run do
    IO.puts("Mishka CMS Migration playground")
    IO.puts("Every write below is rolled back at the end.")

    {_context, checks} =
      steps()
      |> Enum.with_index(1)
      |> Enum.reduce({%{}, []}, &play/2)

    %{checks: length(checks), failed: Enum.count(checks, &match?({_expected, false}, &1))}
  end

  defp steps do
    [
      {"Setup", "A site, an admin with migration permissions and a source holding 3 redirects.",
       &setup/1},
      {"Create a run", "The admin creates a run over the fake source; nothing runs yet.",
       &create/1},
      {"Bad input is refused", "A run with an option the engine does not know is refused.",
       &refuse/1},
      {"Dry run", "A dry run walks the source and reports what an import would do.", &dry_run/1},
      {"Import", "The import writes the redirects into the CMS and records each item.",
       &import_rows/1},
      {"Run again with one row changed", "A new run updates the changed row and skips the rest.",
       &run_again/1},
      {"The admin edits, the source changes the same row",
       "A row an admin changed in the CMS is not overwritten.", &edited/1},
      {"A row it cannot read and a kind no target writes",
       "The unreadable row fails and the kind with no target is skipped.", &unreadable/1},
      {"Wrong source password",
       "A run is refused when its source does not take the password, and nothing is saved.",
       &wrong_password/1},
      {"Password revoked after the run was saved",
       "The job fails twice, and its third attempt ends the run as failed.", &revoked_password/1},
      {"Cancel", "A run is cancelled before its job runs, so the job writes nothing.", &cancel/1},
      {"One active run per site", "A second run cannot start while one is waiting or running.",
       &one_active/1},
      {"Another site", "Another site's admin sees nothing of this site's runs.", &other_site/1},
      {"No migration permission", "A user without the migration permission is refused.",
       &no_permission/1}
    ]
  end

  defp play({{title, what, step}, number}, {context, checks}) do
    IO.puts("\n#{number}. #{title}\n   #{what}")
    {context, results} = step.(context)
    Enum.each(results, &report/1)
    {context, checks ++ results}
  end

  defp report({expected, true}), do: IO.puts("   ✓ #{expected}")
  defp report({expected, false}), do: IO.puts("   ✗ #{expected}")

  defp say(text), do: IO.puts("   - #{text}")

  defp setup(context) do
    Playground.reset()
    permissions = Enum.map(Playground.admin().permissions, & &1.name)

    say("admin holds #{permissions |> Enum.sort() |> Enum.join(" and ")}")
    say("source rows: " <> Enum.map_join(@rows, ", ", &"#{&1["from"]} -> #{&1["to"]}"))

    {context,
     [
       {"the admin may run migrations and write redirects",
        Enum.sort(permissions) == [
          "admin:dashboard:migration",
          "admin:dashboard:runtime:redirect"
        ]},
       {"the CMS starts with no redirect and no migration item",
        Playground.redirects() == [] and Playground.items() == []}
     ]}
  end

  defp create(context) do
    run = new_run(%{"redirect" => @rows})
    stored = MishkaCmsMigration.get_run!(run.id, as_admin())

    say("status #{run.status}")
    say("options #{pairs(stored.options)}")

    {Map.put(context, :run, run),
     [
       {"the run is pending", run.status == :pending},
       {"the options hold the defaults the admin did not choose", stored.options == @defaults},
       {"the source password is kept only sealed",
        is_binary(run.connection_secret) and run.connection_secret != "letmein"}
     ]}
  end

  defp refuse(context) do
    refusal =
      %{source: "fake", source_host: "old.example.com", options: %{pages: "nope"}}
      |> MishkaCmsMigration.create_run(as_admin())
      |> refusal()

    say("pages: \"nope\" was #{describe(refusal)}")

    {context,
     [
       {"the engine names the field and its place in the options",
        match?(%{kind: :invalid, field: :pages, path: [:options]}, refusal)},
       {"no second run was created",
        match?([_only_the_first], Ash.read!(MigrationRun, as_admin()))}
     ]}
  end

  defp dry_run(%{run: run} = context) do
    run = dry_run!(run, Playground.admin())

    say("status #{run.status}, the report plans: #{tally(run)}")

    {%{context | run: run},
     [
       {"the report says 3 to create",
        run.report.counts == %{created: 3, updated: 0, skipped: 0, failed: 0, undecided: 0}},
       {"the CMS still has no redirect", Playground.redirects() == []},
       {"each item's plan is recorded, and none is imported",
        Playground.items() == [
          {"redirect", "1", :created, nil, nil},
          {"redirect", "2", :created, nil, nil},
          {"redirect", "3", :created, nil, nil}
        ]}
     ]}
  end

  defp import_rows(%{run: run} = context) do
    run = import!(run, Playground.admin())

    say("status #{run.status}, report: #{tally(run)}")
    Enum.each(Playground.redirects(), fn {from, to} -> say("redirect #{from} -> #{to}") end)

    {%{context | run: run},
     [
       {"the run is done", run.status == :done},
       {"the CMS has the 3 redirects",
        Playground.redirects() ==
          [{"/old-one", "/one"}, {"/old-three", "/three"}, {"/old-two", "/two"}]},
       {"3 items are recorded", match?([_, _, _], Playground.items())},
       {"the source password is cleared", is_nil(run.connection_secret)}
     ]}
  end

  defp run_again(context) do
    run = Playground.import(List.replace_at(@rows, 1, redirect_row(2, "/old-two", "/two-moved")))

    say("report: #{tally(run)}")
    say(outcomes_line(run))

    {context,
     [
       {"1 row is updated and 2 are skipped as unchanged",
        run.report.counts == %{created: 0, updated: 1, skipped: 2, failed: 0, undecided: 0}},
       {"the CMS still has 3 redirects, with the changed one moved",
        Playground.redirects() ==
          [{"/old-one", "/one"}, {"/old-three", "/three"}, {"/old-two", "/two-moved"}]}
     ]}
  end

  defp edited(context) do
    :ok = Playground.edit("/old-one", "/kept-by-admin")

    run =
      Playground.import([
        redirect_row(1, "/old-one", "/from-source"),
        redirect_row(2, "/old-two", "/two-moved"),
        redirect_row(3, "/old-three", "/three")
      ])

    say("the admin set /old-one -> /kept-by-admin, the source says /from-source")
    say(outcomes_line(run))

    {context,
     [
       {"the row is skipped as edited_in_cms", outcomes(run)["1"] == {:skipped, "edited_in_cms"}},
       {"the admin's value stays", {"/old-one", "/kept-by-admin"} in Playground.redirects()}
     ]}
  end

  defp unreadable(context) do
    before = Playground.redirects()

    run =
      Playground.import(%{
        "redirect" => [%{"id" => 7, "unreadable" => true}],
        "note" => [%{"id" => 9, "title" => "A note"}]
      })

    say("report: #{tally(run)}")
    say(outcomes_line(run))

    {context,
     [
       {"1 row failed and 1 was skipped",
        run.report.counts == %{created: 0, updated: 0, skipped: 1, failed: 1, undecided: 0}},
       {"the unreadable row failed as unreadable", outcomes(run)[nil] == {:failed, "unreadable"}},
       {"the note was skipped as no_target", outcomes(run)["9"] == {:skipped, "no_target"}},
       {"the run still ended as done and the CMS is unchanged",
        run.status == :done and Playground.redirects() == before}
     ]}
  end

  defp wrong_password(context) do
    runs = Ash.count!(MigrationRun, as_admin())

    {:error, error} =
      MishkaCmsMigration.create_run(
        %{source: "fake", source_host: "old.example.com", connection: %{}, secret: "wrong"},
        as_admin()
      )

    say("refused: #{Report.reason(error)}")

    {context,
     [
       {"the run was refused on its connection",
        match?(%{errors: [%{field: :connection} | _]}, error)},
       {"no run was saved", Ash.count!(MigrationRun, as_admin()) == runs}
     ]}
  end

  defp revoked_password(context) do
    run = new_run(%{"redirect" => @rows})

    Repo.query!(
      ~s(UPDATE mishka_cms_migration_runs SET connection = connection || '{"revoked": true}' WHERE id = $1),
      [Ecto.UUID.dump!(run.id)]
    )

    MishkaCmsMigration.start_dry_run!(run, as_admin())
    jobs = Playground.drain()
    run = MishkaCmsMigration.get_run!(run.id, as_admin())

    say("the job ran #{jobs.success + jobs.failure} times, #{jobs.failure} of them failed")
    say("status #{run.status}, reason #{inspect(run.reason)}")

    {context,
     [
       {"the job was tried 3 times and the last attempt ended the run",
        match?(%{success: 1, failure: 2}, jobs)},
       {"the run ended as failed with the source's reason",
        {run.status, run.reason} == {:failed, "unauthorized"}},
       {"the source password is cleared", is_nil(run.connection_secret)}
     ]}
  end

  defp cancel(context) do
    before = {Playground.redirects(), Playground.items()}
    started = %{"redirect" => @rows} |> new_run() |> MishkaCmsMigration.start_dry_run!(as_admin())
    cancelled = MishkaCmsMigration.cancel_run!(started, as_admin())
    jobs = Playground.drain()

    say("status #{started.status}, then #{cancelled.status}")
    say("the queue ran #{jobs.success + jobs.failure} jobs")

    {context,
     [
       {"the run is cancelled and its password cleared",
        {cancelled.status, cancelled.connection_secret} == {:cancelled, nil}},
       {"draining the queue runs no job", match?(%{success: 0, failure: 0}, jobs)},
       {"nothing was written", {Playground.redirects(), Playground.items()} == before}
     ]}
  end

  defp one_active(context) do
    first = %{} |> new_run() |> MishkaCmsMigration.start_dry_run!(as_admin())
    second = new_run(%{})

    refusal = second |> MishkaCmsMigration.start_dry_run(as_admin()) |> refusal()
    waiting = MishkaCmsMigration.get_run!(second.id, as_admin())

    MishkaCmsMigration.cancel_run!(first, as_admin())
    started = MishkaCmsMigration.start_dry_run!(second, as_admin())
    MishkaCmsMigration.cancel_run!(started, as_admin())
    Playground.drain()

    say("the second run was #{describe(refusal)}")
    say("it stayed #{waiting.status} until the first was cancelled, then it started")

    {context,
     [
       {"the second run is refused because another is active",
        match?(%{kind: :invalid, field: :site_id, message: "Another migration" <> _}, refusal)},
       {"the second run is still pending", waiting.status == :pending},
       {"cancelling the first frees the site for the second", started.status == :dry_running}
     ]}
  end

  defp other_site(context) do
    other = create_site!()
    other_admin = create_user_with_permissions!(["*"], site_id: other.id)
    own = Ash.read!(MigrationRun, as_admin())
    seen = Ash.read!(MigrationRun, actor: other_admin, tenant: other.id)

    asked =
      MigrationRun |> Ash.read(actor: other_admin, tenant: Playground.site().id) |> refusal()

    say("this site has #{length(own)} runs")
    say("the other site's admin, holding every permission, sees #{length(seen)}")
    say("asking for this site's runs was #{describe(asked)}")

    {context,
     [
       {"the other site's admin sees none of the runs", seen == []},
       {"naming this site does not help", asked == %{kind: :forbidden}}
     ]}
  end

  defp no_permission(context) do
    site = Playground.site()
    writer = create_user_with_permissions!(["admin:dashboard:runtime:redirect"], site_id: site.id)
    reading = MigrationRun |> Ash.read(actor: writer, tenant: site.id) |> refusal()

    creating =
      %{source: "fake", source_host: "old.example.com"}
      |> MishkaCmsMigration.create_run(actor: writer, tenant: site.id)
      |> refusal()

    say("a user who may only write redirects: reading runs was #{describe(reading)}")
    say("creating a run was #{describe(creating)}")

    {context,
     [
       {"reading the site's runs is refused", reading == %{kind: :forbidden}},
       {"creating a run is refused", creating == %{kind: :forbidden}}
     ]}
  end

  defp new_run(items, attrs \\ %{}),
    do: create_run!(Playground.site(), Playground.admin(), items, attrs)

  defp as_admin, do: [actor: Playground.admin(), tenant: Playground.site().id]

  defp tally(%{report: %{counts: counts}}),
    do: Enum.map_join(Report.outcomes(), ", ", &"#{counts[&1]} #{&1}")

  defp pairs(map),
    do: map |> Enum.sort() |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{value}" end)

  defp outcomes(run), do: Map.new(run.report.entries, &{&1.source_id, {&1.outcome, &1.reason}})

  defp outcomes_line(run),
    do:
      Enum.map_join(
        run.report.entries,
        ", ",
        &"#{&1.source_id || "an unreadable row"}: #{&1.outcome}#{reason(&1.reason)}"
      )

  defp reason(nil), do: ""
  defp reason(reason), do: " (#{reason})"

  defp refusal({:ok, _result}), do: %{kind: :accepted}
  defp refusal({:error, %Ash.Error.Forbidden{}}), do: %{kind: :forbidden}

  defp refusal(
         {:error, %Ash.Error.Invalid{errors: [%{field: field, path: path, message: message} | _]}}
       ),
       do: %{kind: :invalid, field: field, path: path, message: message}

  defp describe(%{kind: :accepted}), do: "accepted"
  defp describe(%{kind: :forbidden}), do: "refused: the user is not allowed"

  defp describe(%{kind: :invalid, field: field, path: [], message: message}),
    do: "refused on #{inspect(field)}: #{message}"

  defp describe(%{kind: :invalid, field: field, path: path, message: message}),
    do: "refused on #{inspect(field)} in #{inspect(path)}: #{message}"
end

session = Playground.Session.start!()
tour = Playground.Tour.run()
Playground.Session.finish(session, tour)
