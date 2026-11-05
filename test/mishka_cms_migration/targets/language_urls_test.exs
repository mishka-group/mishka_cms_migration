# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.LanguageUrlsTest do
  @moduledoc """
  The hash an item is recorded with and compared by (`LanguageUrls.hash/2`): an item that writes
  links changes with the site's language address mode, so a Run again writes its links again, and
  an item with no links never does.
  """
  use MishkaCmsMigration.DataCase, async: false

  alias MishkaCmsCore.Settings
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Targets.Helpers.LanguageUrls

  defp item!(kind, source_id, attrs) do
    assert {:ok, item} =
             Item.build(%{kind: kind, source_id: source_id, title: "T", attrs: attrs})

    item
  end

  defp mode!(site, mode),
    do: Settings.put("site.language_urls", mode, site_id: site.id, category: "general")

  test "follows the site's language address mode for a menu, and a page or post that links" do
    site = create_site!()
    linked = [item!("menu", "1", %{}), item!("page", "2", %{"pages" => %{"http://a/" => "a"}})]

    before = Map.new(linked, &{&1.source_id, LanguageUrls.hash(&1, site.id)})
    mode!(site, "prefix_all")

    for item <- linked do
      assert LanguageUrls.hash(item, site.id) != before[item.source_id]
    end

    mode!(site, "prefix_others")
    for item <- linked, do: assert(LanguageUrls.hash(item, site.id) == before[item.source_id])
  end

  test "is the item's own hash when it writes no links" do
    site = create_site!()

    for item <- [item!("tag", "3", %{}), item!("page", "4", %{"pages" => %{}})] do
      before = LanguageUrls.hash(item, site.id)
      assert before == Item.hash(item)
      mode!(site, "prefix_all")
      assert LanguageUrls.hash(item, site.id) == before
    end
  end
end
