# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.SeoTagsTest do
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Seo
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Targets.Helpers.SeoTags

  @context %{source_host: "old.example"}

  defp tags(seo, featured \\ nil) do
    {:ok, item} =
      Item.build(%{kind: "post", source_id: "1", title: "T", attrs: %{"seo" => seo}})

    item
    |> SeoTags.call(@context, featured)
    |> Jason.encode!()
    |> Jason.decode!()
    |> Seo.stored_tags()
  end

  test "the social and Twitter fields become the tags the core's head knows, each once" do
    seo = %{
      "og_title" => "Social",
      "og_description" => "Social text",
      "twitter_title" => "Tweet",
      "twitter_description" => "Tweet text",
      "twitter_card" => "summary"
    }

    stored = tags(seo)

    for {id, value} <- [
          {"og:title", "Social"},
          {"og:description", "Social text"},
          {"twitter:title", "Tweet"},
          {"twitter:description", "Tweet text"},
          {"twitter:card", "summary"}
        ] do
      assert Seo.tag_value(stored, id) == value
      assert id in Enum.map(Seo.catalog(), & &1.id), "#{id} is a tag the core's head offers"
    end

    assert length(stored) == 5
  end

  test "a Twitter image on another site is kept, and one that is the share image is not repeated" do
    other = "https://cdn.example.test/t.jpg"

    assert Seo.tag_value(tags(%{"twitter_image" => other}), "twitter:image") == other

    seo = %{"image" => other, "twitter_image" => other}
    stored = tags(seo)

    assert Seo.tag_value(stored, "og:image") == other
    refute Seo.tag_value(stored, "twitter:image")
  end

  test "a Twitter image on the source that was not imported, and the featured one, are left out" do
    seo = %{"twitter_image" => "http://old.example/a.jpg", "twitter_image_id" => 5}

    refute Seo.tag_value(tags(Map.delete(seo, "twitter_image_id")), "twitter:image")
    refute Seo.tag_value(tags(seo, 5), "twitter:image")
  end
end
