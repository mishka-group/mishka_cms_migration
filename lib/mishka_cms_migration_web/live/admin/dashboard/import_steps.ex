# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Live.Admin.Dashboard.ImportSteps do
  @moduledoc """
  The steps of the New import window (`MishkaCmsMigration.MigrationRun`'s form), for an admin who
  wants few choices. The form stays one Gervaz form; its groups are the steps, and
  `Phoenix.LiveView.JS` shows one at a time, so every answer stays in the page while the admin moves
  between them and nothing is sent to the server by a Next or Back:

    1. Where from: the source and its connection (group `:connection`);
    2. What to bring: a switch for each kind (group `:bring`);
    3. Languages: one language for everything, or the source's own (group `:language`);
    4. Review: what the run will do in plain words (`review/1`), then Start the dry run.

  Advanced options (group `:options`: authors, page and post addresses, the site's own settings)
  stay hidden until Show advanced options is pressed in the review.

  `nav/1` draws the Back and Next buttons of a step and `review/1` the review, both as Gervaz
  notices with a `render` function, which the form places after the step's group. The group of a
  step carries the class `migration-step-<step>` and every step but the first starts `hidden`; the
  advanced group is `migration-step-advanced`.

  Gervaz's own `:wizard` layout is not used: its Next and Back buttons are drawn without the form's
  `phx-target`, so a click reaches the page instead of the form, and it draws only the current
  step's fields, which would drop the answers of the others from what is sent.
  """

  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [button: 1, icon: 1]

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsMigration.MigrationRun
  alias MishkaCmsMigration.MigrationRun.Options
  alias Phoenix.LiveView.JS

  @modal "#migration-run-form-modal"
  @order [:from, :bring, :language, :review]

  @doc "The steps in the order the admin meets them."
  @spec steps() :: [atom()]
  def steps, do: @order

  @doc """
  The JS that leaves step `from` and shows step `to`. Leaving the review also hides the advanced
  options, so the next visit starts closed.
  """
  @spec go(atom(), atom()) :: JS.t()
  def go(from, to) do
    from
    |> hide()
    |> JS.remove_class("hidden", to: shown(to))
    |> JS.focus_first(to: shown(to))
  end

  @doc "The JS that shows the first step again, for a form that was refused."
  @spec restart() :: JS.t()
  def restart do
    @order
    |> Enum.reject(&(&1 == :from))
    |> Enum.reduce(
      JS.remove_class("hidden", to: shown(:from)),
      &JS.add_class(&2, "hidden", to: shown(&1))
    )
    |> JS.add_class("hidden", to: shown(:advanced))
  end

  @doc "The JS that opens or closes the advanced options of the review."
  @spec toggle_advanced() :: JS.t()
  def toggle_advanced, do: JS.toggle_class("hidden", to: shown(:advanced))

  defp hide(:review), do: JS.add_class("hidden", to: shown(:review) <> ", " <> shown(:advanced))
  defp hide(step), do: JS.add_class("hidden", to: shown(step))

  defp shown(step), do: "#{@modal} .migration-step-#{step}"

  attr :step, :atom, required: true, values: @order
  attr :class, :string, default: nil

  @doc """
  The Back and Next buttons of `step` (the first has no Back, the review no Next: the form's own
  submit, labelled Start the dry run, ends it).
  """
  def nav(%{step: step} = assigns) do
    assigns =
      assigns
      |> assign(:back, neighbour(step, -1))
      |> assign(:next, neighbour(step, 1))
      |> assign(:hidden, step != :from)

    ~H"""
    <div
      data-role="import-step-nav"
      data-step={@step}
      class={[
        "migration-step mt-4 flex items-center justify-between gap-2",
        "migration-step-#{@step}",
        @hidden && "hidden"
      ]}
    >
      <.button :if={@back} type="button" variant="soft" phx-click={go(@step, @back)}>
        <.icon name="hero-arrow-left" class="size-4 rtl:rotate-180" />
        {gettext("Back")}
      </.button>
      <span :if={!@back}></span>
      <.button :if={@next} type="button" variant="primary" phx-click={go(@step, @next)}>
        {gettext("Next")}
        <.icon name="hero-arrow-right" class="size-4 rtl:rotate-180" />
      </.button>
    </div>
    """
  end

  defp neighbour(step, by) do
    index = Enum.find_index(@order, &(&1 == step)) + by
    if index >= 0, do: Enum.at(@order, index)
  end

  @doc """
  The review step: `summary/1` in lines and the Show advanced options link, which opens the
  advanced group. It is part of the form, so it follows each answer as the admin changes it.
  """
  def review(%{state: state} = assigns) do
    assigns = assign(assigns, :lines, summary(state))

    ~H"""
    <div
      data-role="import-review"
      class="migration-step migration-step-review hidden mb-4 grid gap-2 text-[13px] text-[#3a382f]"
    >
      <p :for={{role, line} <- @lines} data-role={"review-#{role}"} class="m-0">{line}</p>
      <button
        type="button"
        data-role="show-advanced"
        phx-click={toggle_advanced()}
        class="w-fit cursor-pointer text-start text-[12.5px] font-bold text-[#4f4bcc] underline"
      >
        {gettext("Show advanced options")}
      </button>
    </div>
    """
  end

  @doc """
  The review's lines as `{role, words}` pairs for the form `state`: `:from`, `:bring`, `:left_out`
  (omitted when nothing is switched off), `:settings` (omitted when none is left out), `:language`
  and `:dry_run`. An answer the form does not hold yet is the run's default.
  """
  @spec summary(map()) :: [{atom(), String.t()}]
  def summary(state) do
    params = params(state)
    options = options(params)
    {brought, left} = state |> MigrationRun.bring_choices() |> Enum.split_with(&on?(options, &1))

    Enum.reject(
      [
        {:from, from_words(params)},
        {:bring, listed(gettext("Bringing:"), brought)},
        {:left_out, left != [] && listed(gettext("Not bringing:"), left)},
        {:settings, settings_words(options)},
        {:language, language_words(params)},
        {:dry_run,
         gettext(
           "Start the dry run to see what would happen. It writes nothing to your site: you check the list, then import."
         )}
      ],
      fn {_role, words} -> words in [nil, false] end
    )
  end

  defp params(%{form: %{params: %{} = params}}), do: params
  defp params(_state), do: %{}

  defp options(params) do
    asked = Map.merge(map(params["options"]), map(params["bring"]))

    case Options.builder(asked) do
      {:ok, options} -> options
      {:error, _errors} -> Options.builder(%{}) |> elem(1)
    end
  end

  defp map(%{} = map), do: map
  defp map(_none), do: %{}

  defp on?(options, choice), do: Map.get(options, choice[:name]) == true

  defp listed(lead, choices),
    do:
      lead <>
        " " <>
        Enum.map_join(
          choices,
          ", ",
          &Gettext.dgettext(MishkaCmsCore.Gettext, "mishka_gervaz", &1[:label])
        ) <> "."

  defp from_words(%{"connection" => %{"url" => url}}) when is_binary(url) and url != "",
    do: gettext("From: %{address}.", address: url)

  defp from_words(%{"file" => _upload}), do: gettext("From: the export file you chose.")
  defp from_words(_params), do: gettext("From: the source you connected.")

  defp settings_words(options) do
    left =
      for {key, label} <- [
            site_title: gettext("site title"),
            site_logo: gettext("site logo"),
            site_icon: gettext("site icon")
          ],
          Map.get(options, key) == false,
          do: label

    case left do
      [] ->
        nil

      left ->
        gettext("Left out of the site's own settings: %{names}.", names: Enum.join(left, ", "))
    end
  end

  defp language_words(params) do
    case params |> Map.get("language") |> map() |> Map.get("one_language") do
      code when is_binary(code) and code != "" ->
        name = Languages.name(code) || code

        gettext(
          "Languages: everything the source gives without a language of your site goes in %{language}.",
          language: name
        )

      _keep ->
        gettext("Languages: kept as the source gives them.")
    end
  end
end
