# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Test.Plugins.RedirectTarget do
  @moduledoc """
  A target for the suite: the `"redirect"` items of `MishkaCmsMigration.Test.Plugins.FakeSource`
  written as the CMS's own redirect rules, through `MishkaCmsCore.Runtime.Redirect`'s `:create` and
  `:update`. So a test writes a real CMS row the way a real target will, held to that resource's
  policies (`admin:dashboard:runtime:redirect`) and validations, with no write path of its own.

  The item's `"from"` and `"to"` are the rule's addresses and its content, joined, is the rule's
  description. An item whose `"explode"` is `"attrs"` makes `attrs/2` raise.
  """

  use MishkaCmsMigration.Target,
    kind: "redirect",
    resource: MishkaCmsCore.Runtime.Redirect,
    create: :create,
    update: :update

  alias MishkaCmsMigration.Source.Item

  @impl MishkaCmsMigration.Target
  def attrs(%{attrs: %{"explode" => "attrs"}}, _context), do: raise(ArgumentError, "no redirect")

  def attrs(item, _context) do
    %{
      from_path: item.attrs["from"],
      to: item.attrs["to"],
      description: description(Item.html(item))
    }
  end

  defp description(""), do: nil
  defp description(html), do: html
end
