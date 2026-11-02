# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Registry do
  @moduledoc """
  The sources and targets installed now, read from mishka_installer's own registry
  (`MishkaInstaller.Event.Event.get/2`): the plugins registered on an event that are running
  (`:started` or `:restarted`), by priority, that are loaded and implement every required callback
  of the behaviour, the first of each id. A plugin an operator stopped, or one held because
  something it depends on is not running, is not installed. Nothing is fired to find them and
  nothing is cached: each call reads the registry.
  """

  alias MishkaInstaller.Event.Event

  @running [:started, :restarted]

  @doc """
  What a screen offers and a run may use: the plugins of `event` an operator has not stopped, that
  implement `behaviour`, in priority order, the first of each id.
  """
  @spec plugins(String.t(), module()) :: [module()]
  def plugins(event, behaviour) do
    :event
    |> Event.get(event)
    |> Enum.filter(&(&1.status in @running))
    |> Enum.sort_by(&{&1.priority, inspect(&1.name)})
    |> Enum.map(& &1.name)
    |> Enum.filter(&implements?(&1, behaviour))
    |> Enum.uniq_by(& &1.id())
  end

  @doc """
  The one plugin a run of `id` uses, among `plugins/2`; `{:error, :not_installed}` when none
  answers to it, so the run is refused or fails with that reason.
  """
  @spec fetch(String.t(), module(), String.t() | nil) ::
          {:ok, module()} | {:error, :not_installed}
  def fetch(event, behaviour, id) when is_binary(id) do
    case Enum.find(plugins(event, behaviour), &(&1.id() == id)) do
      nil -> {:error, :not_installed}
      plugin -> {:ok, plugin}
    end
  end

  def fetch(_event, _behaviour, _id), do: {:error, :not_installed}

  defp implements?(module, behaviour) do
    Code.ensure_loaded?(module) and behaviour in behaviours(module) and
      Enum.all?(
        behaviour.behaviour_info(:callbacks) -- behaviour.behaviour_info(:optional_callbacks),
        fn {name, arity} -> function_exported?(module, name, arity) end
      )
  end

  defp behaviours(module),
    do: module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
end
