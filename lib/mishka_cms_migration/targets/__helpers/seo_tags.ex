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
      is left out, and so is the target's `featured` file, which a Blog post already shows as its
      share image;
    * `"canonical"` — the `canonical` link. The source keeps only a canonical on another site.

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
    [
      tag("title", %{}, seo["title"]),
      tag("meta", %{"name" => "description"}, seo["description"]),
      tag("meta", %{"name" => "robots"}, seo["robots"]),
      tag("meta", %{"property" => "og:image"}, image(seo, featured, context)),
      tag("link", %{"rel" => "canonical"}, seo["canonical"])
    ]
    |> Enum.reject(&is_nil/1)
  end

  def call(_item, _context, _featured), do: []

  defp tag(_tag, _attrs, nil), do: nil
  defp tag(tag, attrs, value), do: Seo.stored_tag(tag, attrs, value)

  defp image(%{"image_id" => id}, id, _context), do: nil

  defp image(%{"image_id" => id}, _featured, context),
    do: [id] |> CmsMedia.addresses(context) |> Map.get(to_string(id))

  defp image(%{"image" => url}, _featured, context) when is_binary(url),
    do: elsewhere(url, Source.url_host(%{"url" => url}), context.source_host)

  defp image(_seo, _featured, _context), do: nil

  defp elsewhere(_url, nil, _source_host), do: nil
  defp elsewhere(_url, source_host, source_host), do: nil
  defp elsewhere(url, _host, _source_host), do: url
end
