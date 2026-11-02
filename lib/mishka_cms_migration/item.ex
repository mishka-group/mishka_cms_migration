# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Item do
  @moduledoc """
  One item of a source, as every source hands it over: the normalized model the dry run decides on
  and a target writes from. A source's `c:MishkaCmsMigration.Source.normalize/3` returns the map
  `build/1` turns into this struct; the pipeline puts `:kind` in, so a source never names it.

    * `:kind` — what the item is, such as `"post"`, `"page"` or `"user"`. A target is chosen by it
      (`MishkaCmsMigration.Target`).
    * `:source_id` — the item's id on the source, kept as a string (an integer is turned into one).
      Together with the run's `source_host` and `:kind` it is how a re-run finds what an earlier run
      wrote.
    * `:title` — what the report calls the item.
    * `:modified_at` — when the source last changed it: a `DateTime`, a `NaiveDateTime` taken as
      UTC, or an ISO 8601 string.
    * `:attrs` — everything else the target needs, as the source names it. Its keys are never
      turned into atoms.
    * `:content` — the item's body as a list of pieces, in order. A piece the source converted
      itself carries `:html`; a block or shortcode it could not convert carries `:name`, `:attrs`
      and `:raw` instead, and is offered to the `migration:content:convert` event
      (`MishkaCmsMigration.Events`) when the item is imported. `html/1` joins the pieces.

  `hash/1` is what a re-run compares to tell whether the source changed the item: it covers every
  field but `:modified_at`, so a source that touches an item without changing it is not an update.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :kind, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(string, not_empty, max_len=64)"

    field :source_id, String.t(),
      enforce: true,
      validator: {MishkaCmsMigration.Item, :identifier},
      derives: "sanitize(trim) validate(string, not_empty, max_len=255)"

    field :title, String.t(),
      derives: "sanitize(trim, no_control) validate(optional=[string, max_len=1000])"

    field :modified_at, DateTime.t(), validator: {MishkaCmsMigration.Item, :datetime}

    dynamic_field :attrs

    sub_field :content, list(), structs: true, authorized_fields: true do
      field :html, String.t(), derives: "validate(optional=[string])"
      field :name, String.t(), derives: "sanitize(trim) validate(optional=[string, max_len=255])"
      dynamic_field :attrs
      field :raw, String.t(), derives: "validate(optional=[string])"
    end
  end

  @doc """
  The item `attrs` describe, checked and cleaned: `{:ok, item}`, or `{:error, errors}` with
  guarded_struct's error maps.
  """
  @spec build(map()) :: {:ok, t()} | {:error, [map()]}
  def build(attrs), do: builder(attrs)

  @doc """
  A digest of what the source says the item is: every field but `:modified_at`, as hex.
  """
  @spec hash(t()) :: String.t()
  def hash(%__MODULE__{} = item) do
    {item.kind, item.source_id, item.title, item.attrs, Enum.map(item.content || [], &piece/1)}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  The item's content as one string: the `:html` of each piece, in order. A piece with no `:html`
  adds nothing, so convert the pieces first.
  """
  @spec html(t()) :: String.t()
  def html(%__MODULE__{content: content}), do: Enum.map_join(content || [], &(&1.html || ""))

  @doc false
  def identifier(field, value) when is_integer(value), do: {:ok, field, Integer.to_string(value)}
  def identifier(field, value) when is_binary(value), do: {:ok, field, value}
  def identifier(field, _value), do: {:error, field, "must be a string or an integer"}

  @doc false
  def datetime(field, nil), do: {:ok, field, nil}
  def datetime(field, %DateTime{} = value), do: {:ok, field, value}

  def datetime(field, %NaiveDateTime{} = value),
    do: {:ok, field, DateTime.from_naive!(value, "Etc/UTC")}

  def datetime(field, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, field, datetime}
      {:error, _reason} -> naive(field, value)
    end
  end

  def datetime(field, _value), do: {:error, field, "must be a date and time"}

  defp naive(field, value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> {:ok, field, DateTime.from_naive!(naive, "Etc/UTC")}
      {:error, _reason} -> {:error, field, "must be an ISO 8601 date and time"}
    end
  end

  defp piece(piece), do: {piece.html, piece.name, piece.attrs, piece.raw}
end
