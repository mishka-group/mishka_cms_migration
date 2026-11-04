# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Targets.Helpers.SeoTags do
  @moduledoc """
  An item's `"seo"` (`MishkaCmsMigration.Sources.WordPress` reads it from Yoast SEO and Rank Math)
  as the `seo_tags` a CMS page or a Blog post stores, for the targets that write them
  (`MishkaCmsMigration.Targets.CmsPage`, `MishkaCmsMigration.Targets.BlogPost`). Each tag is
  written as the core's head reads a stored tag (`MishkaCmsCore.Runtime.Seo.stored_tag/3`), and
  replaces the default the head would draw for it:

    * `"title"` — the `title`; a `{{page.title}}` or `{{site.name}}` in it is the core's own
      variable;
    * `"description"` — the `description` meta;
    * `"robots"` — the `robots` meta, such as `noindex, nofollow`;
    * `"image"` — the `og:image` meta: the Media address of the file the same run, or an earlier
      one, wrote for its `"image_id"` (`MishkaCmsMigration.Targets.CmsMedia.addresses/2`). An image
      on another site than the source keeps its address; one on the source that was not imported
      is left out, and so is the target's `featured` file: a page with no stored `og:image` gets the
      core's share card (`MishkaCmsCore.Runtime.ShareCard`), which draws a Blog post's featured
      image, and a stored one would replace that card;
    * `"canonical"` — the `canonical` link. The source keeps only a canonical on another site;
    * `"og_title"` and `"og_description"` — the `og:title` and `og:description` metas, the social
      title and description when they say something else than the title and the description;
    * `"twitter_title"` and `"twitter_description"` — the `twitter:title` and
      `twitter:description` metas;
    * `"twitter_image"` — the `twitter:image` meta, kept and left out by the same rules as `"image"`
      (its `"twitter_image_id"`), and left out too when it is the `og:image` the page stores,
      which the head already repeats for Twitter;
    * `"twitter_card"` — the `twitter:card` meta, only `summary`: the head draws
      `summary_large_image` for a page with an image by itself.

  The core's head stacks these over the layout's and a plugin's, a tag by its name and attributes,
  so each one replaces the default for that tag, and none is drawn twice.

  An item without `"seo"` has no tags.
  """

  alias MishkaCmsCore.Runtime.Seo
  alias MishkaCmsMigration.Source
  alias MishkaCmsMigration.Source.Item
  alias MishkaCmsMigration.Target
  alias MishkaCmsMigration.Targets.CmsMedia

  @doc """
  The `seo_tags` of `item`, leaving out an image that is the source's `featured` file (`nil` for
  none).
  """
  @spec call(Item.t(), Target.context(), term()) :: [map()]
  def call(%Item{attrs: %{"seo" => %{} = seo}}, context, featured) do
    og_image = image(seo, "image", featured, context)
    twitter_image = image(seo, "twitter_image", featured, context)

    [
      tag("title", %{}, seo["title"]),
      tag("meta", %{"name" => "description"}, seo["description"]),
      tag("meta", %{"name" => "robots"}, seo["robots"]),
      tag("meta", %{"property" => "og:image"}, og_image),
      tag("link", %{"rel" => "canonical"}, seo["canonical"]),
      tag("meta", %{"property" => "og:title"}, seo["og_title"]),
      tag("meta", %{"property" => "og:description"}, seo["og_description"]),
      tag("meta", %{"name" => "twitter:title"}, seo["twitter_title"]),
      tag("meta", %{"name" => "twitter:description"}, seo["twitter_description"]),
      tag("meta", %{"name" => "twitter:image"}, differing(twitter_image, og_image)),
      tag("meta", %{"name" => "twitter:card"}, seo["twitter_card"])
    ]
    |> Enum.reject(&is_nil/1)
  end

  def call(_item, _context, _featured), do: []

  defp tag(_tag, _attrs, nil), do: nil
  defp tag(tag, attrs, value), do: Seo.stored_tag(tag, attrs, value)

  defp differing(value, value), do: nil
  defp differing(value, _other), do: value

  defp image(seo, field, featured, context),
    do: located(seo[field], seo[field <> "_id"], featured, context)

  defp located(_url, id, id, _context) when not is_nil(id), do: nil

  defp located(_url, id, _featured, context) when not is_nil(id),
    do: [id] |> CmsMedia.addresses(context) |> Map.get(to_string(id))

  defp located(url, nil, _featured, context) when is_binary(url),
    do: elsewhere(url, Source.url_host(%{"url" => url}), context.source_host)

  defp located(_url, _id, _featured, _context), do: nil

  defp elsewhere(_url, nil, _source_host), do: nil
  defp elsewhere(_url, source_host, source_host), do: nil
  defp elsewhere(url, _host, _source_host), do: url
end
