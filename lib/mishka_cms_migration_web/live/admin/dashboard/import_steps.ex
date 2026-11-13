# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigrationWeb.Live.Admin.Dashboard.ImportSteps do
  @moduledoc """
  The steps of the New import window (`MishkaCmsMigration.MigrationRun`'s form), for an admin who
  wants few choices. The form is Gervaz's `:wizard` layout: every step is in the form and only the
  current one shows, so an answer stays while the admin moves between them; Next checks the step
  before it moves on, Enter in a field is Next, and only the review starts the run:

    1. Where from: the source and its connection (group `:connection`);
    2. What to bring: a switch for each kind (group `:bring`);
    3. Languages: one language for everything, or the source's own (field `:language`);
    4. Review: what the run will do in plain words (`review/1`), and the Advanced options (group
       `:options`, collapsed), then Start the dry run.

  It is the form's step handler (`MishkaGervaz.Form.Web.Events.StepHandler`). Leaving Where from
  checks more than the fields' own errors: a connection key the source requires that is blank is
  refused as "Enter the application password." (the key's label), and a filled connection is tried
  (`MishkaCmsMigration.Source.connect/4`): one the source refuses stays on the step with the reason
  in the words the save uses (`MishkaCmsMigration.Resources.Changes.CheckConnection.message/2`). A
  source that reads a file asks for the file instead, and reads it only when the run starts. A save
  refused on an earlier step, such as a connection that stopped answering, goes back to it with
  the error and an error flash naming the step (Gervaz's `goto_errors/2`).

  `start_over/1` draws Start over, which empties the window and returns it to the first step: the
  answers are otherwise kept while the window is closed and opened again, until a run starts.
  """

  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext
  use MishkaGervaz.Form.Web.Events.StepHandler

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsMigration.MigrationRun
  alias MishkaCmsMigration.MigrationRun.Options
  alias MishkaCmsMigration.Resources.Changes.CheckConnection
  alias MishkaCmsMigration.Source
  alias MishkaGervaz.Form.Web.UploadHelpers

  @settings ~w(site_title site_logo site_icon)a

  @doc """
  Moves on from Where from only once the connection is filled and the source answers it (see the
  module doc); every other step moves on as Gervaz's step handler moves it. A refused Where from
  shows every error it has at once: a blank site beside a blank connection key. The connection is
  tried only once nothing else on the step is refused.
  """
  @spec advance(map(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def advance(%{current_step: :from} = state, socket) do
    case refusal(state, socket, can_advance?(state, :from)) do
      nil ->
        super(state, socket)

      {field, messages} ->
        state = StepHandler.refused(state, :from)
        state = State.update(state, errors: Map.put(state.errors, field, messages))
        Phoenix.Component.assign(socket, :form_state, state)
    end
  end

  def advance(state, socket), do: super(state, socket)

  defp refusal(%{defaults: %{source: id}} = state, socket, fields_fine?) when is_binary(id) do
    case Source.fetch(id) do
      {:ok, source} -> refusal(source, source.file?(), state, socket, fields_fine?)
      {:error, :not_installed} -> nil
    end
  end

  defp refusal(_state, _socket, _fields_fine?), do: nil

  defp refusal(source, true = _file?, state, socket, _fields_fine?) do
    upload = UploadHelpers.namespaced_upload_name(:file, state.static.id)

    case socket.assigns[:uploads] do
      %{^upload => %{entries: [_ | _]}} -> nil
      _none -> {:file, [CheckConnection.message(source, :no_file)]}
    end
  end

  defp refusal(source, false, state, _socket, fields_fine?) do
    connection = state |> params() |> Map.get("connection") |> map()

    case {blank_keys(source, connection), fields_fine?} do
      {[], true} -> connected(source, connection, state)
      {[], false} -> nil
      {blank, _fields_fine?} -> {:connection, Enum.map(blank, &enter/1)}
    end
  end

  defp blank_keys(source, connection) do
    for key <- source.form_fields(),
        key[:required] == true,
        connection |> Map.get(to_string(key[:name])) |> blank?(),
        do: key
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(value), do: is_nil(value)

  defp enter(key) do
    label = Gettext.dgettext(MishkaCmsCore.Gettext, "mishka_gervaz", key[:label])
    gettext("Enter the %{key}.", key: lower_first(label))
  end

  defp lower_first(<<first::utf8, second::utf8, _rest::binary>> = label)
       when second in ?a..?z,
       do: String.downcase(<<first::utf8>>) <> String.slice(label, 1..-1//1)

  defp lower_first(label), do: label

  defp connected(source, connection, state) do
    {secret, connection} = Map.pop(connection, "secret")

    case Source.connect(source, connection, secret, %{site_id: site_id(state), source_host: nil}) do
      {:ok, _conn} -> nil
      {:error, reason} -> {:connection, [CheckConnection.message(source, reason)]}
    end
  end

  defp site_id(%{current_user: %{site_id: site_id}}) when is_binary(site_id), do: site_id
  defp site_id(state), do: state |> params() |> Map.get("site_id")

  attr :state, :map, required: true

  @doc """
  The review step: its heading, "4 of 4: Review", and `summary/1` in lines. It is part of the form,
  so it follows each answer as the admin changes it.
  """
  def review(%{state: state} = assigns) do
    assigns = assign(assigns, :lines, summary(state))

    ~H"""
    <div data-role="import-review" class="mb-4 grid gap-2 text-[13px] text-[#3a382f]">
      <h3 class="m-0 text-[13px] font-bold text-[#17161a]">{gettext("4 of 4: Review")}</h3>
      <p :for={{role, line} <- @lines} data-role={"review-#{role}"} class="m-0">{line}</p>
    </div>
    """
  end

  attr :id, :string, required: true

  @doc """
  Start over, a quiet button that empties the window with the form component `id` and returns it
  to its first step (`MishkaGervaz.Form.Web.Live.reset/2`).
  """
  def start_over(assigns) do
    ~H"""
    <div class="mb-3 flex justify-end">
      <button
        type="button"
        data-role="import-start-over"
        phx-click={MishkaGervaz.Form.Web.Live.reset(@id)}
        class="cursor-pointer text-[12px] font-semibold text-[#8a877f] underline hover:text-[#3a382f]"
      >
        {gettext("Start over")}
      </button>
    </div>
    """
  end

  @doc """
  The review's lines as `{role, words}` pairs for the form `state`: `:from`, `:bring`, `:left_out`
  (omitted when nothing is switched off), `:choices` (omitted when every Advanced choice is at its
  default), `:settings` (omitted when none is left out), `:language` and `:dry_run`. An answer the
  form does not hold yet is the run's default.
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
        {:choices, choices_words(state, options)},
        {:settings, settings_words(state, options)},
        {:language, language_words(params)},
        {:dry_run,
         gettext(
           "Start the dry run: a test run that changes nothing on your site. You check what it would do in the list, then import."
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
      {:error, _errors} -> defaults()
    end
  end

  defp defaults, do: Options.builder(%{}) |> elem(1)

  defp map(%{} = map), do: map
  defp map(_none), do: %{}

  defp on?(options, choice), do: Map.get(options, choice[:name]) == true

  defp label(text), do: Gettext.dgettext(MishkaCmsCore.Gettext, "mishka_gervaz", text)

  defp listed(lead, choices),
    do: lead <> " " <> Enum.map_join(choices, ", ", &label(&1[:label])) <> "."

  defp from_words(%{"connection" => %{"url" => url}}) when is_binary(url) and url != "",
    do: gettext("From: %{address}.", address: url)

  defp from_words(%{"file" => _upload}), do: gettext("From: the export file you chose.")
  defp from_words(_params), do: gettext("From: the source you connected.")

  # An Advanced choice other than a site setting, said only when it is not its default: a select
  # by the label of the option chosen, a number as itself, a switch as on or off.
  defp choices_words(state, options) do
    default = defaults()

    said =
      for choice <- MigrationRun.run_choices(state),
          choice = Map.new(choice),
          choice.name not in @settings,
          Map.get(options, choice.name) != Map.get(default, choice.name),
          do: label(choice.label) <> ": " <> chosen(choice, Map.get(options, choice.name))

    if said != [], do: Enum.join(said, ". ") <> "."
  end

  defp chosen(%{type: :select, options: offered}, value) do
    case List.keyfind(offered, value, 1) do
      {text, _value} -> label(text)
      nil -> to_string(value)
    end
  end

  defp chosen(%{type: :number}, value), do: to_string(value)
  defp chosen(_switch, false), do: gettext("off")
  defp chosen(_switch, _on), do: gettext("on")

  defp settings_words(state, options) do
    left =
      for choice <- MigrationRun.run_choices(state),
          choice[:name] in @settings,
          Map.get(options, choice[:name]) == false,
          do: label(choice[:label])

    if left != [],
      do: gettext("Left out of the site's own settings: %{names}.", names: Enum.join(left, ", "))
  end

  defp language_words(params) do
    case params["language"] do
      code when is_binary(code) and code != "" ->
        gettext(
          "Languages: everything the source gives without a language of your site goes in %{language}.",
          language: Languages.name(code) || code
        )

      _keep ->
        gettext("Languages: kept as the source gives them.")
    end
  end
end
