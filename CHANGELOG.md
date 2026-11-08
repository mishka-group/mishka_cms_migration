# Changelog for MishkaCmsMigration 0.0.2

### Features:
- Slugs and names are made by `mishka_slug`, the way Mishka CMS stores them. A Persian or Arabic WordPress post, tag or category slug is imported unchanged on a site that publishes in that language, and Latin accents are removed (`café` is `cafe`)
- A slug or page path segment the site's languages keep nothing of becomes a stable generated ASCII one (`tag-1a2b3c4d`, the same for the same text), so a later run and a post's link to it find it, and the report says so
- Slug conflicts are found by the slug the Blog stores, so a tag or category the site already holds is matched and asked about exactly
- Media files, folders and menu components are named as the core names them
- A run keeps the WordPress addresses: posts, terms and pages are served at their WordPress addresses (Persian paths included, the post permalink shape, term bases and front page kept on the run) and only what moved is redirected
- Every address a WordPress visitor knows (feeds, sitemaps, list pages, day archives, paged posts, old slugs, author archives) is a redirect item, written only to an address the site serves, and a dry run plans what the import does

### Dependencies:
- `mishka_cms_core` 0.0.5-alpha.7, `mishka_blog` 0.0.3-alpha.3, `mishka_gervaz` 0.0.7 and the new `mishka_slug` 0.0.1

# Changelog for MishkaCmsMigration 0.0.1

- Initial version: [mishka.tools/cms](https://mishka.tools/cms)
