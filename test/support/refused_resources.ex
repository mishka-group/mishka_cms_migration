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

defmodule MishkaCmsMigration.Test.PlainTimestampResource do
  @moduledoc """
  A resource for the suite whose `updated_at` is a plain attribute rather than an
  `update_timestamp`, kept in ETS and in no domain: a migration target over it is refused when it
  compiles (`MishkaCmsMigration.Target`).
  """

  use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, create: :*, update: :*]
  end

  attributes do
    uuid_primary_key :id
    attribute :updated_at, :utc_datetime_usec, public?: true
  end
end

defmodule MishkaCmsMigration.Test.WritableTimestampResource do
  @moduledoc """
  A resource for the suite whose `updated_at` Ash fills on every write, as an `update_timestamp`
  does, but which an action may also be handed (`writable?: true`), kept in ETS and in no domain: a
  migration target over it is refused when it compiles (`MishkaCmsMigration.Target`).
  """

  use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, create: :*, update: :*]
  end

  attributes do
    uuid_primary_key :id

    attribute :updated_at, :utc_datetime_usec do
      public? true
      writable? true
      default &DateTime.utc_now/0
      update_default &DateTime.utc_now/0
    end
  end
end
