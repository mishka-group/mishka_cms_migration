# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.Helpers.Status do
  @moduledoc """
  The status of a source item as a target that publishes it reads it
  (`MishkaCmsMigration.Targets.BlogPost`, `MishkaCmsMigration.Targets.CmsPage`): the item's
  `"status"`, except that an item behind a password (a non-empty `"password"` in its `extra`) is
  `"password"` whatever its status says, since the CMS has no password-protected record to write it
  as.
  """

  alias MishkaCmsMigration.Source.Item

  @doc ~S|The status `item` is written by: "password" for one behind a password, else its own.|
  @spec call(Item.t()) :: String.t() | nil
  def call(%Item{extra: %{"password" => password}}) when is_binary(password) and password != "",
    do: "password"

  def call(%Item{attrs: attrs}), do: attrs["status"]
end
