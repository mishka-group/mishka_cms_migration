# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Test.Plugins.PageTarget do
  @moduledoc """
  A target for the suite: the `"page"` items of `MishkaCmsMigration.Test.Plugins.FakeSource` written
  as the CMS's own pages, through `MishkaCmsCore.Runtime.Page`'s `:create` and `:update`. A page
  keeps an `extra` map of its own, so the target copies the item's `extra` — the source's fields
  the CMS has no home for — there under a key of its own, `"migration"`, beside what the CMS keeps
  in it.
  """

  use MishkaCmsMigration.Target,
    kind: "page",
    resource: MishkaCmsCore.Runtime.Page,
    create: :create,
    update: :update

  alias MishkaCmsMigration.Source.Item

  @impl MishkaCmsMigration.Target
  def attrs(item, _context) do
    %{
      name: item.title,
      title: item.title,
      path: item.attrs["path"],
      template: "<div>#{Item.html(item)}</div>",
      extra: %{"migration" => item.extra}
    }
  end
end
