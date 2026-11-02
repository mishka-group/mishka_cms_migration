# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Test.IntegerResource do
  @moduledoc """
  A resource for the suite whose primary key is an integer, kept in ETS and in no domain: a
  migration target over it is refused when it compiles (`MishkaCmsMigration.Target`).
  """

  use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, create: :*, update: :*]
  end

  attributes do
    integer_primary_key :id
    update_timestamp :updated_at
  end
end
