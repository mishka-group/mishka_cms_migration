# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Decisions do
  @moduledoc """
  The Items page's Decisions panel (`MishkaCmsMigrationWeb.Live.Admin.Dashboard.Item.Index`): what
  waits for a decision no admin has made among the items of the run's source host, grouped, so a
  whole group is decided in one step instead of item by item. It reads the groups in one query
  (`MishkaCmsMigration.MigrationItem.waiting_groups/3`) once the page is connected, and again once
  after any change to the items it is told of (`refresh: true`, which the page sends for every
  item's broadcast): a refresh asked for while one is read, or while a decision is applied, is read
  once that is done, so a decision over a thousand items reads the groups once more, not a
  thousand times. Nothing waits, nothing is drawn.

  ## Simple

  One card for each conflict, such as "The source does not say its language", with how many items
  wait for it and of which kinds ("1,668 items: 120 pages, 1,400 posts…"), and its choices in
  words, the recommended one first and marked so (`MishkaCmsMigration.MigrationItem.choice_options/1`).
  A choice asks first, "Answer 1,668 items with “Import it in the site's main language”? …", then
  decides them all (`MishkaCmsMigration.MigrationItem.decide_waiting/5`); a flash says how many.
  Show them narrows the table to what waits for a decision (the Plan filter).

  ## Advanced

  One rule for each kind and conflict, each with its own choice and a switch to include it, and an
  optional text that narrows every rule to the items whose title holds it, or whose source id it
  is. Preview counts reads, in one query, how many items each rule would decide; Apply asks first,
  then decides each included rule's items with its choice.

  A decision holds for every later dry run and import and imports nothing: the panel's foot says
  that the next import writes them, parents before their children. Every decision runs as the
  signed-in admin, on the run's site, under the items' own policies and their check that no run of
  the site is running (`MishkaCmsMigration.Resources.Validations.SiteIdle`); one refused is said in
  a flash.

  Every part carries a `data-role` (`decisions`, `decision-group` with `data-conflict`,
  `decision-choice` with `data-choice` and `data-recommended`, `decision-rule` with `data-key`,
  `decision-preview`, `decision-apply`), so a test reads it without reading its markup.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaGervaz.UIAdapters.Tailwind, only: [select: 1, checkbox: 1, text_input: 1]

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsMigration.{MigrationItem, MigrationRun}
  alias MishkaGervaz.Errors
  alias Phoenix.LiveView.JS

  @impl true
  def mount(socket),
    do:
      {:ok,
       assign(socket,
         groups: nil,
         reading?: false,
         stale?: false,
         applying?: false,
         mode: :simple,
         rules: %{},
         search: "",
         preview: nil
       )}

  @impl true
  def update(%{refresh: true}, socket), do: {:ok, read(socket)}

  def update(assigns, socket),
    do:
      {:ok,
       socket
       |> assign(Map.take(assigns, [:id, :run, :current_user, :list_path]))
       |> first_read(connected?(socket))}

  @impl true
  def handle_event("mode", %{"mode" => mode}, socket) when mode in ["simple", "advanced"],
    do: {:noreply, assign(socket, mode: String.to_existing_atom(mode), preview: nil)}

  def handle_event("decide_group", %{"conflict" => conflict, "choice" => choice}, socket),
    do: {:noreply, apply_rules(socket, [{conflict, choice, nil}], nil)}

  def handle_event("rules", params, socket),
    do:
      {:noreply,
       assign(socket, rules: ruled(params), search: params["search"] || "", preview: nil)}

  def handle_event("preview", params, socket) do
    socket = assign(socket, rules: ruled(params), search: params["search"] || "")
    %{run: run, current_user: user, search: search} = socket.assigns

    {:noreply, run |> MigrationItem.waiting_groups(user, search) |> previewed(socket)}
  end

  def handle_event("apply_rules", _params, socket) do
    rules =
      for group <- socket.assigns.groups,
          rule = rule(socket.assigns.rules, group),
          rule.on,
          do: {group.conflict, rule.choice, [group.kind]}

    {:noreply, apply_rules(socket, rules, socket.assigns.search)}
  end

  @impl true
  def handle_async(:groups, {:ok, {:ok, groups}}, socket),
    do: {:noreply, socket |> assign(groups: groups, reading?: false) |> read_again()}

  def handle_async(:groups, _failed, socket),
    do: {:noreply, socket |> assign(reading?: false) |> read_again()}

  def handle_async(:apply, {:ok, result}, socket) do
    send(self(), {:put_flash, flash_kind(result), applied_words(result)})
    {:noreply, socket |> assign(applying?: false, stale?: false, preview: nil) |> read()}
  end

  def handle_async(:apply, {:exit, reason}, socket) do
    send(self(), {:put_flash, :error, error_words(reason)})
    {:noreply, socket |> assign(applying?: false, stale?: false) |> read()}
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        conflicts: conflicts(assigns.groups),
        total: Enum.sum(Enum.map(assigns.groups || [], & &1.count))
      )

    ~H"""
    <div id={@id}>
      <section
        :if={@total > 0}
        data-role="decisions"
        data-mode={@mode}
        class="mb-[22px] rounded-[16px] border border-[#f3e2b8] bg-[#fffaf0] p-4 shadow-[0_1px_2px_rgba(30,28,24,0.04)]"
      >
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div class="min-w-0">
            <h2 class="m-0 flex items-center gap-2 text-[15px] font-bold text-[#1b1a18]">
              <MishkaCmsCore.CoreComponents.icon
                name="hero-hand-raised"
                class="size-[16px] text-[#8a5a00]"
              />
              {ngettext(
                "%{count} item needs your decision",
                "%{count} items need your decision",
                @total
              )}
            </h2>
            <p class="m-0 mt-1 max-w-[680px] text-[12.5px] font-medium text-[#6d5413]">
              {gettext(
                "Decide a whole group at once. A decision holds for every later dry run and import, and imports nothing by itself."
              )}
            </p>
          </div>
          <div class="inline-flex rounded-[10px] border border-[#ecebe6] bg-white p-[3px]">
            <button
              :for={{mode, word} <- [simple: gettext("Simple"), advanced: gettext("Advanced")]}
              type="button"
              data-role="decisions-mode"
              data-mode={mode}
              phx-click="mode"
              phx-value-mode={mode}
              phx-target={@myself}
              class={[
                "h-[28px] rounded-[8px] px-3 text-[12px] font-bold transition-colors",
                if(@mode == mode,
                  do: "bg-[#5b57d6] text-white",
                  else: "text-[#5c5a54] hover:bg-[#f7f6f3]"
                )
              ]}
            >
              {word}
            </button>
          </div>
        </div>

        <p
          :if={@applying?}
          data-role="decisions-applying"
          class="m-0 mt-3 text-[12.5px] font-semibold text-[#5b57d6]"
        >
          {gettext("Deciding… The rows change as each item is decided.")}
        </p>

        <div :if={@mode == :simple} class="mt-3 grid gap-2">
          <article
            :for={group <- @conflicts}
            data-role="decision-group"
            data-conflict={group.conflict}
            data-count={group.count}
            class="rounded-[12px] border border-[#ecebe6] bg-white p-3"
          >
            <h3 class="m-0 text-[13px] font-bold text-[#1b1a18]">
              {MigrationRun.reason_label(group.conflict)}
            </h3>
            <p class="m-0 mt-[3px] text-[12px] font-medium text-[#7c7a75]">
              {ngettext("%{count} item: %{kinds}", "%{count} items: %{kinds}", group.count,
                kinds: counted(group.kinds)
              )}
            </p>
            <div class="mt-2.5 flex flex-wrap items-center gap-2">
              <button
                :for={
                  {{word, choice}, index} <-
                    Enum.with_index(MigrationItem.choice_options(group.conflict))
                }
                type="button"
                data-role="decision-choice"
                data-choice={choice}
                data-recommended={index == 0 && "true"}
                disabled={@applying?}
                phx-click="decide_group"
                phx-value-conflict={group.conflict}
                phx-value-choice={choice}
                phx-target={@myself}
                data-confirm={confirm_words(group.count, word)}
                class={choice_class(index == 0)}
              >
                <MishkaCmsCore.CoreComponents.icon
                  :if={index == 0}
                  name="hero-star"
                  class="size-[13px]"
                />
                {word}
                <span :if={index == 0} class="text-[10.5px] font-semibold opacity-80">
                  {gettext("(recommended)")}
                </span>
              </button>
              <button
                type="button"
                data-role="decision-show"
                phx-click={JS.patch(shown(@list_path, group.kinds))}
                class="inline-flex h-[30px] items-center px-1.5 text-[12px] font-semibold text-[#4f4bcc] hover:underline"
              >
                {gettext("Show them")}
              </button>
            </div>
          </article>
        </div>

        <form
          :if={@mode == :advanced}
          id={"#{@id}-rules"}
          data-role="decision-rules"
          phx-change="rules"
          phx-submit="preview"
          phx-target={@myself}
          class="mt-3 grid gap-3"
        >
          <div class="max-w-[420px]">
            <.text_input
              name="search"
              value={@search}
              placeholder={gettext("Only items whose title holds this, or with this id")}
              aria_label={gettext("Only items whose title holds this, or with this id")}
            />
          </div>
          <div class="grid gap-1.5">
            <div
              :for={group <- @groups}
              data-role="decision-rule"
              data-key={key(group)}
              class="grid grid-cols-[auto_minmax(0,1fr)_minmax(180px,280px)] items-center gap-3 rounded-[10px] border border-[#ecebe6] bg-white px-3 py-2"
            >
              <.checkbox
                name={"rules[#{key(group)}][on]"}
                value="true"
                checked={rule(@rules, group).on}
                hidden_input={true}
              />
              <div class="min-w-0">
                <div class="text-[12.5px] font-bold text-[#1b1a18]">
                  {MigrationRun.kind_label(group.kind)} · {counted_now(@preview, group)}
                </div>
                <div class="truncate text-[11.5px] font-medium text-[#7c7a75]">
                  {MigrationRun.reason_label(group.conflict, group.kind)}
                </div>
              </div>
              <.select
                name={"rules[#{key(group)}][choice]"}
                value={rule(@rules, group).choice}
                options={MigrationItem.choice_options(group.conflict)}
                prompt={nil}
              />
            </div>
          </div>
          <p
            :if={@preview}
            data-role="decision-preview"
            data-count={previewed(@preview, @groups, @rules)}
            class="m-0 text-[12.5px] font-semibold text-[#3a382f]"
          >
            {ngettext(
              "These rules decide %{count} item.",
              "These rules decide %{count} items.",
              previewed(@preview, @groups, @rules)
            )}
          </p>
          <div class="flex flex-wrap items-center gap-2">
            <button
              type="submit"
              data-role="decision-preview-button"
              class="inline-flex h-[30px] items-center rounded-[9px] border border-[#ecebe6] bg-white px-3 text-[12px] font-bold text-[#3a382f] hover:bg-[#f7f6f3]"
            >
              {gettext("Preview counts")}
            </button>
            <button
              type="button"
              data-role="decision-apply"
              disabled={@applying?}
              phx-click="apply_rules"
              phx-target={@myself}
              data-confirm={
                gettext(
                  "Decide the items of every rule that is on, each with its choice? It holds for every later dry run and import."
                )
              }
              class="inline-flex h-[30px] items-center rounded-[9px] bg-[#5b57d6] px-3 text-[12px] font-bold text-white hover:bg-[#4f4bcc]"
            >
              {gettext("Apply the rules")}
            </button>
          </div>
        </form>

        <p class="m-0 mt-3 text-[11.5px] font-medium text-[#8a877f]">
          {gettext(
            "The next import writes what you decide, parents before their children: on the Migration page press Run again, then Import. For a few items, pick them here and press Import the picked items."
          )}
        </p>
      </section>
    </div>
    """
  end

  defp read(%{assigns: %{applying?: true}} = socket), do: assign(socket, :stale?, true)
  defp read(%{assigns: %{reading?: true}} = socket), do: assign(socket, :stale?, true)

  defp read(socket) do
    %{run: run, current_user: user} = socket.assigns

    socket
    |> assign(reading?: true, stale?: false)
    |> start_async(:groups, fn -> MigrationItem.waiting_groups(run, user) end)
  end

  defp first_read(%{assigns: %{groups: nil}} = socket, true), do: read(socket)
  defp first_read(socket, _read_or_static), do: socket

  defp previewed({:ok, groups}, socket),
    do: assign(socket, :preview, Map.new(groups, &{key(&1), &1.count}))

  defp previewed({:error, error}, socket), do: refused(socket, error)

  defp read_again(%{assigns: %{stale?: true}} = socket), do: read(socket)
  defp read_again(socket), do: socket

  defp apply_rules(socket, [], _search) do
    send(self(), {:put_flash, :error, gettext("Turn on a rule first.")})
    socket
  end

  defp apply_rules(socket, rules, search) do
    %{run: run, current_user: user} = socket.assigns

    socket
    |> assign(:applying?, true)
    |> start_async(:apply, fn -> decided(rules, run, user, search) end)
  end

  defp decided(rules, run, user, search) do
    Enum.reduce_while(rules, {:ok, 0}, fn {conflict, choice, kinds}, {:ok, count} ->
      run
      |> MigrationItem.decide_waiting(user, conflict, choice, kinds: kinds, search: search)
      |> summed(count)
    end)
  end

  defp summed({:ok, decided}, count), do: {:cont, {:ok, count + decided}}
  defp summed({:error, error}, count), do: {:halt, {:error, error, count}}

  defp conflicts(nil), do: []

  defp conflicts(groups),
    do:
      groups
      |> Enum.group_by(& &1.conflict)
      |> Enum.map(fn {conflict, kinds} ->
        %{conflict: conflict, count: Enum.sum(Enum.map(kinds, & &1.count)), kinds: kinds}
      end)
      |> Enum.sort_by(&{-&1.count, &1.conflict})

  defp counted(kinds),
    do: kinds |> Enum.map(&kind_count(&1.kind, &1.count)) |> Languages.join()

  defp kind_count(kind, 1), do: "1 " <> MigrationRun.kind_one(kind)
  defp kind_count(kind, count), do: "#{count} " <> MigrationRun.kind_nouns([kind])

  defp counted_now(nil, group), do: kind_count(group.kind, group.count)
  defp counted_now(preview, group), do: kind_count(group.kind, Map.get(preview, key(group), 0))

  defp previewed(preview, groups, rules),
    do:
      groups
      |> Enum.filter(&rule(rules, &1).on)
      |> Enum.map(&Map.get(preview, key(&1), 0))
      |> Enum.sum()

  defp key(group), do: group.kind <> ":" <> group.conflict

  defp rule(rules, group) do
    [{_word, recommended} | _choices] = MigrationItem.choice_options(group.conflict)
    Map.get(rules, key(group), %{on: true, choice: recommended})
  end

  defp ruled(params),
    do:
      for(
        {key, %{"choice" => choice} = rule} <- params["rules"] || %{},
        into: %{},
        do: {key, %{on: rule["on"] == "true", choice: choice}}
      )

  defp shown(list_path, [%{kind: kind}]),
    do:
      list_path <>
        "?" <>
        URI.encode_query(%{
          "items_filter_plan" => "undecided",
          "items_filter_source_kind" => kind
        })

  defp shown(list_path, _kinds),
    do: list_path <> "?" <> URI.encode_query(%{"items_filter_plan" => "undecided"})

  defp confirm_words(count, word),
    do:
      ngettext(
        "Answer %{count} item with “%{choice}”? It holds for every later dry run and import, and nothing is imported until you import.",
        "Answer %{count} items with “%{choice}”? It holds for every later dry run and import, and nothing is imported until you import.",
        count,
        choice: word
      )

  defp flash_kind({:ok, _count}), do: :info
  defp flash_kind(_error), do: :error

  defp applied_words({:ok, count}),
    do: ngettext("%{count} item decided.", "%{count} items decided.", count)

  defp applied_words({:error, error, count}),
    do: applied_words({:ok, count}) <> " " <> error_words(error)

  defp error_words(error),
    do:
      Errors.format_flash_message(
        Errors.Action.Failed.exception(
          resource: MigrationItem,
          label: gettext("Decide"),
          reason: error
        )
      )

  defp refused(socket, error) do
    send(self(), {:put_flash, :error, error_words(error)})
    socket
  end

  defp choice_class(true),
    do:
      "inline-flex h-[30px] items-center gap-1.5 rounded-[9px] bg-[#5b57d6] px-3 text-[12px] font-bold text-white transition-colors hover:bg-[#4f4bcc] disabled:opacity-50"

  defp choice_class(false),
    do:
      "inline-flex h-[30px] items-center gap-1.5 rounded-[9px] border border-[#ecebe6] bg-white px-3 text-[12px] font-bold text-[#3a382f] transition-colors hover:bg-[#f7f6f3] disabled:opacity-50"
end
