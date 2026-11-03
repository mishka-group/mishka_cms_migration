# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.RunDetails do
  @moduledoc """
  A run's expanded row on the migration page (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.Home.Index`),
  drawn as the admin dashboard's cards are drawn (`MishkaCmsCore.Dashboard.Widget`). `panel/1` takes
  the run as the page reads it.

    * The head says where the run is (`MishkaCmsMigration.MigrationRun.status_label/1`), what the
      report it shows came from and when that finished: the import of a run that is done, its last
      dry run otherwise. Under it, how many items the source listed, a bar of what came of them and
      a pill for each outcome counted more than none of
      (`MishkaCmsMigration.MigrationRun.result_outcomes/1`), with the icon and colours of the row's
      Result pills (`outcome_icon/1`, `outcome_class/1`). A failed run says why it stopped, in
      words for the reasons a source and the job give (`MishkaCmsMigration.Report.reason/1`) and
      as it is for any other.
    * A card for each kind the report counts, with its icon (`kind_icon/1`) and name
      (`kind_label/1`): how many items of it the source listed, a bar of their outcomes, and how
      many of them wait for the admin's decision, else failed, else were skipped, with the reason
      most of those entries give (`reason_label/1`): "54 skipped: No public address at the source"
      when that reason covers all 54, "most often" before it when others are among them.
    * The latest items, the report's last entries newest first, each with links to its CMS record
      when it has one (`item_paths/2`, `MishkaCmsMigration.MigrationRun.record_links/1`), and how
      many more it counted, which opens the run's Items page.
    * What the source said of itself when the run connected (`extra`: a WordPress site's name, its
      address, which opens in a new tab, its timezone and who signed in) and the admin's choices
      (`options`, read with `MishkaCmsMigration.MigrationRun.Options.builder/1`), in words.

  A run waiting for its first dry run says so, what a dry run reads and where to start one. A run
  dry running or importing shows how far its job is instead of its last report: the kind it reads
  among the source's kinds (`c:MishkaCmsMigration.Source.kinds/0`) and the counts so far, from
  `progress`.

  An address a source gave is a link only when it is an `http` or `https` one. The bars are SVG
  shapes, not `style` attributes, so the admin's Content-Security-Policy may close `style-src-attr`.
  Every part carries a `data-role`, and its figures `data-*` attributes, so a test reads what the
  panel says without reading its markup.
  """

  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  alias MishkaCmsCore.Dashboard.Widget
  alias MishkaCmsCore.Localized
  alias MishkaCmsMigration.{MigrationRun, Report, Source}
  alias MishkaCmsMigration.MigrationRun.Options

  @latest 8
  @running [:dry_running, :importing]
  @card "rounded-[16px] border border-[#ecebe6] bg-white px-5 py-[18px] shadow-[0_1px_2px_rgba(30,28,24,0.04)]"

  attr :run, MigrationRun, required: true, doc: "the run, with its report, progress and extra"

  attr :paths, :map,
    default: %{},
    doc: "the CMS record paths of the latest items by `{kind, source id}`, from `item_paths/2`"

  @doc "The expanded row of `run`: its head, its kinds, its latest items and its source."
  def panel(assigns) do
    %MigrationRun{} = run = assigns.run
    report = shown_report(run)

    assigns =
      assign(assigns,
        id: "run-details-#{run.id}",
        report: report,
        total: report && total(report.counts),
        kinds: kinds(report),
        progress: progress(run),
        failure: failure(run),
        source: Source.label(run.source),
        source_icon: MigrationRun.source_icon(run.source)
      )

    ~H"""
    <section
      id={@id}
      data-role="run-details"
      data-status={@run.status}
      data-step={step(@run)}
      aria-labelledby={"#{@id}-title"}
      class="grid gap-4"
    >
      <.head id={@id} run={@run} report={@report} total={@total} />
      <.stopped :if={@failure} failure={@failure} />

      <section
        :if={@kinds != []}
        aria-labelledby={"#{@id}-kinds"}
        data-role="run-details-kinds"
      >
        <h4
          id={"#{@id}-kinds"}
          class="m-0 mb-2.5 text-[11px] font-semibold uppercase tracking-[0.05em] text-[#a8a5a0]"
        >
          {gettext("By kind")}
        </h4>
        <div class="grid grid-cols-5 gap-3 max-[1180px]:grid-cols-3! max-[980px]:grid-cols-2!">
          <.kind_card :for={kind <- @kinds} kind={kind} />
        </div>
      </section>

      <div class="grid grid-cols-3 items-start gap-4 max-[980px]:grid-cols-1!">
        <div class="col-span-2 min-w-0 max-[980px]:col-span-1!">
          <.progress_card :if={@progress} id={@id} progress={@progress} />
          <.first_dry_run :if={@run.status == :pending} run={@run} />
          <.latest
            :if={@kinds != []}
            id={@id}
            run={@run}
            report={@report}
            total={@total}
            paths={@paths}
          />
          <.no_report
            :if={!@progress and @run.status != :pending and @kinds == []}
            report={@report}
          />
        </div>
        <.about id={@id} run={@run} source={@source} source_icon={@source_icon} />
      </div>
    </section>
    """
  end

  @doc """
  The report's entries the panel lists as the latest items, newest first.
  """
  @spec latest_entries(map()) :: [Report.entry()]
  def latest_entries(%{entries: entries}), do: entries |> Enum.take(-@latest) |> Enum.reverse()

  @doc """
  The CMS record paths (`MishkaCmsMigration.MigrationRun.record_paths/2`) of `run`'s latest items,
  by `{kind, source id}`, read as `user` under the run's site. An item with no record, one whose
  record is gone, and every item when the read fails, have none.
  """
  @spec item_paths(MigrationRun.t(), map()) :: %{{String.t(), String.t()} => map()}
  def item_paths(%MigrationRun{report: %{entries: _entries} = report} = run, user) do
    report
    |> latest_entries()
    |> Enum.filter(& &1.source_id)
    |> Enum.group_by(& &1.kind, & &1.source_id)
    |> Enum.flat_map(fn {kind, ids} -> kept(run, kind, ids, user) end)
    |> loaded(run, user)
  end

  def item_paths(_run, _user), do: %{}

  defp kept(run, kind, ids, user) do
    case MishkaCmsMigration.items_by_sources(run.source_host, kind, ids,
           actor: user,
           tenant: run.site_id
         ) do
      {:ok, items} -> items
      {:error, _unreadable} -> []
    end
  end

  defp loaded([], _run, _user), do: %{}

  defp loaded(items, run, user) do
    case Ash.load(items, :record_paths, actor: user, tenant: run.site_id) do
      {:ok, items} -> Map.new(items, &{{&1.source_kind, &1.source_id}, &1.record_paths})
      {:error, _unreadable} -> %{}
    end
  end

  attr :id, :string, required: true
  attr :run, MigrationRun, required: true
  attr :report, :map, default: nil
  attr :total, :integer, default: nil

  defp head(assigns) do
    assigns =
      assign(assigns, moment: moment(assigns.run), running?: assigns.run.status in @running)

    ~H"""
    <div data-role="run-details-head" class={card()}>
      <div class="flex flex-wrap items-center justify-between gap-x-6 gap-y-3">
        <div class="flex min-w-0 items-center gap-3">
          <span class={[
            "grid size-10 flex-none place-items-center rounded-[11px]",
            MigrationRun.status_class(@run.status)
          ]}>
            <.icon
              name={status_icon(@run.status)}
              class={if @running?, do: "size-[19px] motion-safe:animate-spin", else: "size-[19px]"}
            />
          </span>
          <div class="min-w-0">
            <h3
              id={"#{@id}-title"}
              class="m-0 font-['Space_Grotesk'] text-[16px] font-bold leading-tight text-[#17161a]"
            >
              {MigrationRun.status_label(@run.status)}
            </h3>
            <p
              data-role="run-details-moment"
              class="m-0 mt-[3px] text-[12px] font-medium text-[#8a877f]"
            >
              {@moment.text} ·
              <time datetime={@moment.iso} class="whitespace-nowrap">{@moment.absolute}</time>
            </p>
          </div>
        </div>

        <div :if={@report} class="text-end">
          <div
            data-role="run-details-total"
            data-count={@total}
            class="font-['Space_Grotesk'] text-[28px] font-semibold leading-none tracking-[-0.03em] text-[#17161a]"
          >
            {Localized.number(@total)}
          </div>
          <div class="mt-1 text-[11.5px] font-medium text-[#a8a5a0]">
            {ngettext("item found", "items found", @total)}
          </div>
        </div>
      </div>

      <div :if={@report && @total > 0} class="mt-4">
        <.bar counts={@report.counts} class="h-[8px]" />
        <div data-role="run-details-outcomes" class="mt-3 flex flex-wrap gap-[6px]">
          <.outcome_pill
            :for={{outcome, count} <- MigrationRun.result_outcomes(@report)}
            role="run-details-outcome"
            outcome={outcome}
            count={count}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :role, :string, required: true
  attr :outcome, :atom, required: true
  attr :count, :integer, required: true

  defp outcome_pill(assigns) do
    ~H"""
    <span
      data-role={@role}
      data-outcome={@outcome}
      data-count={@count}
      class={[
        "inline-flex items-center gap-[5px] rounded-[20px] px-[10px] py-[4px] text-[11px] font-bold whitespace-nowrap",
        MigrationRun.outcome_class(@outcome)
      ]}
    >
      <.icon name={MigrationRun.outcome_icon(@outcome)} class="size-[13px]" />
      {MigrationRun.outcome_count(@outcome, @count)}
    </span>
    """
  end

  attr :failure, :map, required: true

  defp stopped(assigns) do
    ~H"""
    <div
      data-role="run-details-reason"
      data-reason={@failure.code}
      class="flex items-start gap-3 rounded-[14px] border border-[#f3d5d0] bg-[#fdf0ee] px-4 py-3.5"
    >
      <span class="grid size-8 flex-none place-items-center rounded-[9px] bg-[#fbe9e7] text-[#c0473d]">
        <.icon name="hero-exclamation-triangle" class="size-4" />
      </span>
      <div class="min-w-0">
        <h4 class="m-0 text-[13px] font-bold text-[#b3433a]">{gettext("Why it stopped")}</h4>
        <p class="m-0 mt-0.5 text-[12.5px] font-medium leading-[1.5] text-[#a5352c]">
          {@failure.words}
        </p>
        <p :if={@failure.detail} class="m-0 mt-1 break-all font-mono text-[11px] text-[#c0473d]">
          {@failure.detail}
        </p>
      </div>
    </div>
    """
  end

  attr :kind, :map, required: true

  defp kind_card(assigns) do
    ~H"""
    <div
      data-role="run-details-kind"
      data-kind={@kind.kind}
      data-found={@kind.found}
      class="flex min-w-0 flex-col rounded-[15px] border border-[#ecebe6] bg-white p-4 shadow-[0_1px_2px_rgba(30,28,24,0.04)]"
    >
      <div class="flex items-center gap-2.5">
        <span class={[
          "grid size-9 flex-none place-items-center rounded-[10px]",
          kind_tone(@kind.kind)
        ]}>
          <.icon name={MigrationRun.kind_icon(@kind.kind)} class="size-[17px]" />
        </span>
        <h5 class="m-0 truncate text-[12.5px] font-semibold text-[#5c5a54]">{@kind.label}</h5>
      </div>
      <div class="mt-3 flex items-baseline gap-1.5">
        <span class="font-['Space_Grotesk'] text-[26px] font-semibold leading-none tracking-[-0.03em] text-[#17161a]">
          {Localized.number(@kind.found)}
        </span>
        <span class="text-[11.5px] font-medium text-[#a8a5a0]">{gettext("found")}</span>
      </div>
      <.bar counts={@kind.counts} class="mt-3 h-[6px]" />
      <p
        :if={@kind.note}
        data-role="run-details-kind-reason"
        data-outcome={@kind.note.outcome}
        data-count={@kind.note.count}
        title={@kind.note.text}
        class={[
          "m-0 mt-2.5 line-clamp-2 text-[11px] font-medium leading-[1.45]",
          note_tone(@kind.note.outcome)
        ]}
      >
        {@kind.note.text}
      </p>
    </div>
    """
  end

  attr :counts, :map, required: true
  attr :class, :string, default: nil

  defp bar(assigns) do
    assigns =
      assign(assigns,
        segments: segments(assigns.counts),
        label: MigrationRun.result_summary(%{counts: assigns.counts})
      )

    ~H"""
    <div
      role="img"
      aria-label={@label}
      data-role="run-details-bar"
      class={["overflow-hidden rounded-full bg-[#f2f1ec]", @class]}
    >
      <svg
        viewBox="0 0 100 1"
        preserveAspectRatio="none"
        aria-hidden="true"
        class="block h-full w-full"
      >
        <rect
          :for={segment <- @segments}
          data-role="run-details-segment"
          data-outcome={segment.outcome}
          data-count={segment.count}
          x={segment.x}
          y="0"
          width={segment.width}
          height="1"
          fill={outcome_fill(segment.outcome)}
        />
        <line
          :for={segment <- Enum.drop(@segments, 1)}
          x1={segment.x}
          y1="0"
          x2={segment.x}
          y2="1"
          stroke="#ffffff"
          stroke-width="2"
          vector-effect="non-scaling-stroke"
        />
      </svg>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :run, MigrationRun, required: true
  attr :report, :map, required: true
  attr :total, :integer, required: true
  attr :paths, :map, default: %{}

  defp latest(assigns) do
    items = latest_entries(assigns.report)
    assigns = assign(assigns, items: items, more: max(assigns.total - length(items), 0))

    ~H"""
    <section aria-labelledby={"#{@id}-items"} data-role="run-details-items" class={card()}>
      <.card_title
        id={"#{@id}-items"}
        icon="hero-queue-list"
        tone="bg-[#eeedfb] text-[#5b57d6]"
        title={gettext("Latest items")}
        subtitle={latest_subtitle(@run)}
      />
      <ul class="m-0 list-none divide-y divide-[#f4f3ee] p-0">
        <li
          :for={item <- @items}
          data-role="run-details-item"
          data-kind={item.kind}
          data-outcome={item.outcome}
          data-source-id={item.source_id}
          class="flex items-center gap-3 py-2.5"
        >
          <span class={[
            "grid size-8 flex-none place-items-center rounded-[9px]",
            kind_tone(item.kind)
          ]}>
            <.icon name={MigrationRun.kind_icon(item.kind)} class="size-[15px]" />
          </span>
          <div class="min-w-0 flex-1">
            <div
              data-role="run-details-item-title"
              title={item.title}
              class="truncate text-[12.5px] font-bold text-[#1b1a18]"
            >
              {item.title || gettext("Untitled")}
            </div>
            <div class="mt-[3px] flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-[11px] font-medium text-[#a8a5a0]">
              <Widget.badge label={MigrationRun.kind_label(item.kind)} />
              <span :if={item.source_id} class="font-['Space_Grotesk']">
                {"#" <> item.source_id}
              </span>
              <span :if={item.reason} data-role="run-details-item-reason" class="min-w-0 truncate">
                {MigrationRun.reason_label(item.reason)}
              </span>
            </div>
          </div>
          <MigrationRun.record_links paths={@paths[{item.kind, item.source_id}]} />
          <span class={[
            "inline-flex flex-none items-center rounded-[20px] px-[9px] py-[3px] text-[10px] font-bold whitespace-nowrap",
            MigrationRun.outcome_class(item.outcome)
          ]}>
            {MigrationRun.outcome_word(item.outcome)}
          </span>
        </li>
      </ul>
      <p
        :if={@more > 0}
        data-role="run-details-items-more"
        data-count={@more}
        class="m-0 mt-1 border-t border-[#f4f3ef] pt-3 text-[11.5px] font-semibold text-[#a8a5a0]"
      >
        <a
          href={MigrationRun.items_path(@run)}
          data-role="run-details-items-link"
          class="text-[#5b57d6] transition-opacity hover:opacity-80"
        >
          {gettext("and %{count} more", count: Localized.number(@more))}
        </a>
      </p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :progress, :map, required: true

  defp progress_card(assigns) do
    ~H"""
    <section aria-labelledby={"#{@id}-progress"} data-role="run-details-progress" class={card()}>
      <.card_title
        id={"#{@id}-progress"}
        icon="hero-arrow-path"
        tone="bg-[#eef0ff] text-[#4f4bcc]"
        title={@progress.title}
        subtitle={@progress.subtitle}
      />
      <div
        role="progressbar"
        aria-label={@progress.title}
        aria-valuemin="0"
        aria-valuemax={length(@progress.steps)}
        aria-valuenow={@progress.done}
        aria-valuetext={@progress.subtitle}
        data-role="run-details-progress-bar"
        data-kind={@progress.kind}
        class="flex gap-[3px]"
      >
        <span
          :for={step <- @progress.steps}
          data-role="run-details-progress-step"
          data-kind={step.kind}
          data-state={step.state}
          class={["h-[8px] min-w-0 flex-1 rounded-full", step_class(step.state)]}
        ></span>
      </div>
      <div class="mt-2 flex gap-[3px]" aria-hidden="true">
        <span
          :for={step <- @progress.steps}
          class={[
            "min-w-0 flex-1 truncate text-[10.5px] font-semibold",
            (step.state == :next && "text-[#a8a5a0]") || "text-[#5c5a54]"
          ]}
        >
          {step.label}
        </span>
      </div>
      <div class="mt-4 flex flex-wrap items-center justify-between gap-3 border-t border-[#f4f3ef] pt-3.5">
        <div data-role="run-details-progress-read" data-count={@progress.read}>
          <span class="font-['Space_Grotesk'] text-[18px] font-semibold text-[#17161a]">
            {Localized.number(@progress.read)}
          </span>
          <span class="ms-1 text-[11.5px] font-medium text-[#8a877f]">
            {ngettext("item so far", "items so far", @progress.read)}
          </span>
        </div>
        <div class="flex flex-wrap gap-[6px]">
          <.outcome_pill
            :for={{outcome, count} <- @progress.outcomes}
            role="run-details-progress-outcome"
            outcome={outcome}
            count={count}
          />
        </div>
      </div>
    </section>
    """
  end

  attr :run, MigrationRun, required: true

  defp first_dry_run(assigns) do
    assigns = assign(assigns, :kinds, source_kinds(assigns.run))

    ~H"""
    <section
      data-role="run-details-empty"
      class="flex flex-col items-center gap-3 rounded-[16px] border border-dashed border-[#e3e1da] bg-white px-6 py-8 text-center"
    >
      <span class="grid size-11 place-items-center rounded-[12px] bg-[#eeedfb] text-[#5b57d6]">
        <.icon name="hero-play" class="size-5" />
      </span>
      <div>
        <h4 class="m-0 font-['Space_Grotesk'] text-[15px] font-bold text-[#17161a]">
          {gettext("No dry run yet")}
        </h4>
        <p class="m-0 mx-auto mt-1 max-w-[440px] text-[12.5px] font-medium leading-[1.5] text-[#8a877f]">
          {gettext(
            "Run one to see what this site holds. A dry run reads every item and writes nothing in the CMS."
          )}
        </p>
      </div>
      <ul :if={@kinds != []} class="m-0 flex list-none flex-wrap justify-center gap-[6px] p-0">
        <li
          :for={kind <- @kinds}
          data-role="run-details-reads"
          data-kind={kind}
          class="inline-flex items-center gap-[6px] rounded-[9px] border border-[#ecebe6] bg-[#faf9f6] px-2.5 py-[5px] text-[11.5px] font-semibold text-[#5c5a54]"
        >
          <.icon name={MigrationRun.kind_icon(kind)} class="size-[13px] text-[#8a877f]" />
          {MigrationRun.kind_label(kind)}
        </li>
      </ul>
      <p class="m-0 inline-flex items-center gap-2 rounded-[10px] bg-[#f4f3fd] px-3 py-2 text-[12px] font-semibold text-[#4f4bcc]">
        <span class="grid size-[22px] flex-none place-items-center rounded-[7px] border border-[#dcdbf5] bg-white">
          <.icon name="hero-play" class="size-[12px]" />
        </span>
        {gettext("Press Dry run in this row's actions to start one.")}
      </p>
    </section>
    """
  end

  attr :report, :map, default: nil

  defp no_report(assigns) do
    ~H"""
    <div
      data-role="run-details-none"
      class="flex flex-col items-center gap-2.5 rounded-[16px] border border-dashed border-[#e3e1da] bg-white px-6 py-8 text-center"
    >
      <span class="grid size-10 place-items-center rounded-[11px] bg-[#f2f1ec] text-[#a8a5a0]">
        <.icon name="hero-inbox" class="size-[18px]" />
      </span>
      <p class="m-0 text-[12.5px] font-medium text-[#8a877f]">
        {if @report,
          do: gettext("The source listed nothing to move."),
          else: gettext("This run ended before a dry run reported what the site holds.")}
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :run, MigrationRun, required: true
  attr :source, :string, required: true
  attr :source_icon, :string, required: true

  defp about(assigns) do
    assigns = assign(assigns, facts: facts(assigns.run), choices: choices(assigns.run.options))

    ~H"""
    <aside aria-labelledby={"#{@id}-source"} data-role="run-details-source" class={card()}>
      <.card_title
        id={"#{@id}-source"}
        icon={@source_icon}
        tone="bg-[#f1edfb] text-[#7a5bd0]"
        title={gettext("About the source")}
        subtitle={@source}
      />
      <dl class="m-0 grid gap-y-2.5">
        <div
          :for={fact <- @facts}
          data-role="run-details-fact"
          data-fact={fact.key}
          class="flex items-baseline justify-between gap-3"
        >
          <dt class="flex-none text-[11.5px] font-semibold text-[#a8a5a0]">{fact.label}</dt>
          <dd class="m-0 min-w-0 text-end text-[12.5px] font-semibold text-[#3a382f]">
            <a
              :if={fact.href}
              href={fact.href}
              target="_blank"
              rel="noopener noreferrer"
              class="inline-flex max-w-full items-center gap-1 text-[#4f4bcc] hover:underline"
            >
              <span class="truncate">{fact.value}</span>
              <.icon name="hero-arrow-top-right-on-square" class="size-[12px] flex-none" />
              <span class="sr-only">{gettext("(opens in a new tab)")}</span>
            </a>
            <span :if={!fact.href} class="block truncate" title={fact.value}>{fact.value}</span>
          </dd>
        </div>
      </dl>

      <div :if={@choices != []} class="mt-4 border-t border-[#f4f3ef] pt-3.5">
        <h5 class="m-0 mb-2.5 text-[10.5px] font-bold uppercase tracking-[0.08em] text-[#a8a5a0]">
          {gettext("Choices for this run")}
        </h5>
        <dl class="m-0 grid gap-y-2.5">
          <div
            :for={choice <- @choices}
            data-role="run-details-option"
            data-option={choice.key}
            data-value={to_string(choice.value)}
          >
            <dt class="text-[11.5px] font-semibold text-[#a8a5a0]">{choice.label}</dt>
            <dd class="m-0 mt-px text-[12.5px] font-medium leading-[1.45] text-[#3a382f]">
              {choice.words}
            </dd>
          </div>
        </dl>
      </div>
    </aside>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :tone, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil

  defp card_title(assigns) do
    ~H"""
    <div class="mb-[14px] flex min-w-0 items-center gap-[11px]">
      <span class={["grid size-8 flex-none place-items-center rounded-[9px]", @tone]}>
        <.icon name={@icon} class="size-4" />
      </span>
      <div class="min-w-0">
        <h4 id={@id} class="m-0 truncate text-[14.5px] font-semibold text-[#1b1a18]">{@title}</h4>
        <div :if={@subtitle} class="mt-px truncate text-[11.5px] font-medium text-[#a8a5a0]">
          {@subtitle}
        </div>
      </div>
    </div>
    """
  end

  defp card, do: @card

  defp shown_report(%MigrationRun{status: status}) when status in @running, do: nil
  defp shown_report(%MigrationRun{report: %{counts: _counts} = report}), do: report
  defp shown_report(_no_report), do: nil

  defp step(%MigrationRun{status: status}) when status in [:importing, :done], do: :import
  defp step(%MigrationRun{status: :dry_running}), do: :dry_run
  defp step(%MigrationRun{report: %{counts: _counts}}), do: :dry_run
  defp step(_no_step), do: nil

  defp total(counts), do: counts |> Map.take(Report.outcomes()) |> Map.values() |> Enum.sum()

  defp kinds(%{kinds: [_ | _] = kinds, entries: entries}) do
    for %{kind: kind} = counts <- kinds do
      counts = Map.take(counts, Report.outcomes())

      %{
        kind: kind,
        label: MigrationRun.kind_label(kind),
        found: total(counts),
        counts: counts,
        note:
          Enum.find_value([:undecided, :failed, :skipped], &kind_note(entries, counts, kind, &1))
      }
    end
  end

  defp kinds(_no_kinds), do: []

  defp kind_note(entries, counts, kind, outcome) do
    reasons =
      for %{kind: ^kind, outcome: ^outcome, reason: reason} when is_binary(reason) <- entries,
          do: reason

    reasons
    |> Enum.frequencies()
    |> Enum.max_by(&elem(&1, 1), fn -> nil end)
    |> noted(outcome, counts[outcome])
  end

  defp noted(nil, _outcome, _count), do: nil

  defp noted({reason, covered}, outcome, count),
    do: %{
      outcome: outcome,
      count: count,
      text:
        note_text(outcome, covered == count,
          count: Localized.number(count),
          reason: MigrationRun.reason_label(reason),
          waiting: MigrationRun.outcome_count(outcome, count)
        )
    }

  defp note_text(:undecided, true, words), do: gettext("%{waiting}: %{reason}", words)

  defp note_text(:undecided, false, words),
    do: gettext("%{waiting}, most often: %{reason}", words)

  defp note_text(:failed, true, words), do: gettext("%{count} failed: %{reason}", words)

  defp note_text(:failed, false, words),
    do: gettext("%{count} failed, most often: %{reason}", words)

  defp note_text(:skipped, true, words), do: gettext("%{count} skipped: %{reason}", words)

  defp note_text(:skipped, false, words),
    do: gettext("%{count} skipped, most often: %{reason}", words)

  defp segments(counts) do
    total = total(counts)

    %{counts: counts}
    |> MigrationRun.result_outcomes()
    |> Enum.map_reduce(0.0, &segment(&1, &2, total))
    |> elem(0)
  end

  defp segment({outcome, count}, x, total) do
    width = count * 100 / total

    {%{outcome: outcome, count: count, x: Float.round(x, 3), width: Float.round(width, 3)},
     x + width}
  end

  defp progress(%MigrationRun{status: status} = run) when status in @running do
    kinds = source_kinds(run)
    {kind, counts} = progressed(run.progress)
    done = done_kinds(kinds, kind)
    current = Enum.at(kinds, done)

    %{
      kind: kind && current,
      title: progress_title(status),
      subtitle: progress_subtitle(kind, current, done, length(kinds)),
      done: done,
      steps:
        kinds
        |> Enum.with_index()
        |> Enum.map(fn {step, index} ->
          %{
            kind: step,
            label: MigrationRun.kind_label(step),
            state: step_state(index, done, kind)
          }
        end),
      read: total(counts),
      outcomes: MigrationRun.result_outcomes(%{counts: counts})
    }
  end

  defp progress(_run), do: nil

  defp progressed(%{kind: kind, counts: counts}) when is_binary(kind), do: {kind, counts}
  defp progressed(_none), do: {nil, %{}}

  defp done_kinds(_kinds, nil), do: 0
  defp done_kinds(kinds, kind), do: Enum.find_index(kinds, &(&1 == kind)) || 0

  defp step_state(index, done, _kind) when index < done, do: :done
  defp step_state(index, index, kind) when is_binary(kind), do: :current
  defp step_state(_index, _done, _kind), do: :next

  defp progress_title(:dry_running), do: gettext("Dry run in progress")
  defp progress_title(:importing), do: gettext("Import in progress")

  defp progress_subtitle(nil, _current, _done, _steps),
    do: gettext("Waiting for its job to start")

  defp progress_subtitle(_kind, current, done, steps),
    do:
      gettext("Step %{step} of %{steps}: %{kind}",
        kind: MigrationRun.kind_label(current),
        step: Localized.number(done + 1),
        steps: Localized.number(steps)
      )

  defp source_kinds(%MigrationRun{source: source} = run),
    do: source |> Source.fetch() |> walked_kinds(run)

  defp walked_kinds({:ok, source}, _run), do: source.kinds()
  defp walked_kinds(_not_installed, %MigrationRun{progress: %{kind: kind}}), do: [kind]
  defp walked_kinds(_not_installed, _run), do: []

  defp moment(%MigrationRun{status: :pending, inserted_at: at}),
    do: said_at(gettext("Connected %{when}", when: Localized.ago(at)), at)

  defp moment(%MigrationRun{status: status, updated_at: at}) when status in @running,
    do: said_at(gettext("Updated %{when}", when: Localized.ago(at)), at)

  defp moment(%MigrationRun{status: :dry_run, updated_at: at}),
    do: said_at(gettext("Dry run finished %{when}", when: Localized.ago(at)), at)

  defp moment(%MigrationRun{status: :done} = run),
    do: said_at(gettext("Import finished %{when}", when: Localized.ago(ended(run))), ended(run))

  defp moment(%MigrationRun{status: :failed} = run),
    do: said_at(gettext("Stopped %{when}", when: Localized.ago(ended(run))), ended(run))

  defp moment(%MigrationRun{status: :cancelled} = run),
    do: said_at(gettext("Cancelled %{when}", when: Localized.ago(ended(run))), ended(run))

  defp said_at(text, at),
    do: %{text: text, iso: DateTime.to_iso8601(at), absolute: Localized.datetime(at, :yMMMdHm)}

  defp ended(%MigrationRun{finished_at: %DateTime{} = at}), do: at
  defp ended(%MigrationRun{updated_at: at}), do: at

  defp latest_subtitle(%MigrationRun{status: :done}),
    do: gettext("What the import did with the last items, newest first")

  defp latest_subtitle(_run),
    do: gettext("What an import would do with the last items, newest first")

  defp failure(%MigrationRun{status: :failed, reason: reason} = run),
    do: reason |> stopped_because(run) |> failed(reason)

  defp failure(_run), do: nil

  defp failed(reason, reason), do: %{code: reason, words: reason, detail: nil}
  defp failed(words, reason), do: %{code: reason, words: words, detail: reason}

  defp stopped_because("unauthorized", run),
    do:
      gettext(
        "%{source} no longer accepts the user and password this run signed in with. They may have been changed or revoked: start a new run with the new ones.",
        source: Source.label(run.source)
      )

  defp stopped_because("unreachable", run),
    do:
      gettext("Nothing answered at %{host}. Once the site is up again, start a new run.",
        host: run.source_host
      )

  defp stopped_because("no_site", run),
    do:
      gettext("%{host} answered, but not as a %{source} site.",
        host: run.source_host,
        source: Source.label(run.source)
      )

  defp stopped_because("unreadable_secret", _run),
    do:
      gettext(
        "The saved password can no longer be opened, as this CMS's secret key has changed since. Start a new run and type it again."
      )

  defp stopped_because("no_file", _run),
    do: gettext("The file this run was given is no longer there. Start a new run with it.")

  defp stopped_because("unreadable_file", run),
    do:
      gettext(
        "The file this run was given is not a %{source}, or it is damaged. Start a new run with the export made again.",
        source: Source.label(run.source)
      )

  defp stopped_because("forbidden", _run),
    do: gettext("The CMS refused what this run writes to the admin who started it.")

  defp stopped_because(nil, _run), do: gettext("The job stopped without saying why.")
  defp stopped_because(reason, _run), do: reason

  defp facts(%MigrationRun{extra: extra, source_host: host}) do
    [
      fact("name", gettext("Site"), extra["name"]),
      address(extra["home"], host),
      fact("timezone", gettext("Timezone"), extra["timezone"]),
      fact("signed_in_as", gettext("Signed in as"), extra["signed_in_as"])
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp fact(key, label, value) when is_binary(value) and value != "",
    do: %{key: key, label: label, value: value, href: nil}

  defp fact(_key, _label, _none), do: nil

  defp address(home, host), do: home |> web_address() |> addressed(home, host)

  defp web_address(home) when is_binary(home), do: URI.parse(home)
  defp web_address(_no_home), do: nil

  defp addressed(%URI{scheme: scheme, host: site}, home, _host)
       when scheme in ["http", "https"] and is_binary(site) and site != "",
       do: %{key: "home", label: gettext("Address"), value: shown_address(home), href: home}

  defp addressed(_not_a_web_address, _home, host), do: fact("home", gettext("Address"), host)

  defp shown_address(home),
    do: home |> String.replace(~r{^https?://}, "") |> String.trim_trailing("/")

  defp choices(stored) do
    stored |> Options.builder() |> chosen()
  end

  defp chosen({:ok, %Options{} = options}) do
    [
      %{
        key: "authors",
        label: gettext("Authors"),
        value: options.authors,
        words: authors(options.authors)
      },
      %{key: "pages", label: gettext("Pages"), value: options.pages, words: pages(options.pages)},
      %{
        key: "post_address",
        label: gettext("Post addresses"),
        value: options.post_address,
        words: post_address(options.post_address)
      },
      %{
        key: "comments",
        label: gettext("Comments"),
        value: options.comments,
        words: comments(options.comments)
      }
    ]
  end

  defp chosen(_unreadable), do: []

  defp authors("create"), do: gettext("Matched to users by email, a new user for the rest")
  defp authors(_connect), do: gettext("Matched to users by email, the rest skipped")

  defp pages("publish"), do: gettext("Published at their old addresses")
  defp pages(_draft), do: gettext("Brought in as drafts")

  defp post_address("blog_without_redirects"),
    do: gettext("Under /blog, with no redirect from the old addresses")

  defp post_address(_blog), do: gettext("Under /blog, with a redirect from each old address")

  defp comments(true), do: gettext("Brought in too")
  defp comments(_false), do: gettext("Left behind")

  defp status_icon(:pending), do: "hero-link"
  defp status_icon(status) when status in @running, do: "hero-arrow-path"
  defp status_icon(:dry_run), do: "hero-eye"
  defp status_icon(:done), do: "hero-check-circle"
  defp status_icon(:failed), do: "hero-exclamation-triangle"
  defp status_icon(:cancelled), do: "hero-no-symbol"

  defp kind_tone("user"), do: "bg-[#eeedfb] text-[#5b57d6]"
  defp kind_tone("category"), do: "bg-[#fbf1df] text-[#cf8a24]"
  defp kind_tone("tag"), do: "bg-[#e9effb] text-[#3b6fd4]"
  defp kind_tone("page"), do: "bg-[#e6f6ee] text-[#1f9d6b]"
  defp kind_tone("post"), do: "bg-[#f1edfb] text-[#7a5bd0]"
  defp kind_tone("comment"), do: "bg-[#fbeaf0] text-[#c2477a]"
  defp kind_tone("post_redirect"), do: "bg-[#eaf1fb] text-[#3a6cb5]"
  defp kind_tone(_other), do: "bg-[#f2f1ec] text-[#6d6a63]"

  defp note_tone(:failed), do: "text-[#c0473d]"
  defp note_tone(:undecided), do: "text-[#8a5a00]"
  defp note_tone(:skipped), do: "text-[#8a877f]"

  defp outcome_fill(:created), do: "#1f9d6b"
  defp outcome_fill(:updated), do: "#3b6fd4"
  defp outcome_fill(:skipped), do: "#c3c0b8"
  defp outcome_fill(:failed), do: "#d5544b"
  defp outcome_fill(:undecided), do: "#e0a028"

  defp step_class(:done), do: "bg-[#5b57d6]"
  defp step_class(:current), do: "bg-[#bcb8ee] motion-safe:animate-pulse"
  defp step_class(:next), do: "bg-[#eeedea]"
end
