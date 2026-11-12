# Changelog for MishkaCmsMigration 0.0.4

### Features:
- A run's new "WordPress breaks comments into pages" choice, with "Comments a page" (50, WordPress's default): on, each post's `/comment-page-N/` address is redirected to the post with a 301, one for each page its approved top-level comments fill ([mishka_blog#56](https://github.com/mishka-group/mishka_blog/issues/56))
- The WordPress tagline is imported into the site's `site.tagline`, and the site icon fills `site.app_icon` as well as `site.favicon` ([mishka_cms_core#115](https://github.com/mishka-group/mishka_cms_core/issues/115))

- Needs mishka_cms_core 0.0.5-alpha.13 (a page's event, info and state handlers keep their code signature with `CODE_SIGNING_KEY` set), mishka_gervaz 0.0.8 and guarded_struct 0.1.7. Every dependency is at its latest release, including ash 3.37.4 and spark 2.7.10

# Changelog for MishkaCmsMigration 0.0.3

### Features:
- A run keeps the WordPress addresses: posts, terms and pages are served at their WordPress
  addresses (Persian paths included, the post permalink shape, term bases and front page kept on
  the run) and only what moved is redirected [#58](https://github.com/mishka-group/mishka_cms_migration/pull/58)
- Every address a WordPress visitor knows (feeds, sitemaps, list pages, day archives, paged posts,
  old slugs, author archives) is a redirect item, written only to an address the site serves, and
  a dry run plans what the import does [#58](https://github.com/mishka-group/mishka_cms_migration/pull/58)
- A run's new Blog pages choice: "use" (the default) moves the site's Blog pages and creates the
  missing ones where the run serves posts, and "create" creates the missing ones at Blog's default
  `/blog` paths and moves none. The dry run plans them without writing, and the run details show
  the plan [#59](https://github.com/mishka-group/mishka_cms_migration/pull/59)

### Bug fixes:
- A redirect is written only to an address the site serves, nested categories are served at their
  full chain, and an author with no blogger is sent to the posts list [#58](https://github.com/mishka-group/mishka_cms_migration/pull/58)
- A dry run plans an item under a parent that waits, a file known to be another's, a kept address,
  a draft page's redirect, and a term in a prefixed language whose WordPress address has no
  prefix, as the import leaves them [#58](https://github.com/mishka-group/mishka_cms_migration/pull/58)
- An export pages its posts page's list and each author's archive, and keeps a file's attachment
  page under each earlier slug [#58](https://github.com/mishka-group/mishka_cms_migration/pull/58)
- The run details count what needs a decision as the Decisions panel does, and the source facts
  stay inside a narrow card [#58](https://github.com/mishka-group/mishka_cms_migration/pull/58)
- The Items page keeps the run's status from its status moves, so a branch's buttons stay enabled
  after an import finishes [#59](https://github.com/mishka-group/mishka_cms_migration/pull/59)
- A redirect an earlier run wrote follows where the site serves its record now: a rule that sends
  elsewhere is written again to that address, and one whose old address is the record's own again
  (a `/blog` run, then one that keeps the WordPress addresses) is archived, so it no longer sends a
  live post to a 404 (`Target.outdated/2`). A rule an admin changed that no longer sends to its post,
  or hides the post's address, waits for their decision (`"redirect_edited"`): let the import fix
  it, or keep it as edited

### Refactors:
- The source's facts are read only in a job of the whole run [#58](https://github.com/mishka-group/mishka_cms_migration/pull/58)
- CI pins Tailwind 4.3.5 and caches its binary across test runs [#58](https://github.com/mishka-group/mishka_cms_migration/pull/58)

### Dependencies:
- `mishka_cms_core` 0.0.5-alpha.8 [#58](https://github.com/mishka-group/mishka_cms_migration/pull/58) and `mishka_blog` 0.0.3-alpha.5 [#59](https://github.com/mishka-group/mishka_cms_migration/pull/59)

# Changelog for MishkaCmsMigration 0.0.2

### Features:
- Slugs and names are made by `mishka_slug`, the way Mishka CMS stores them. A Persian or Arabic WordPress post, tag or category slug is imported unchanged on a site that publishes in that language, and Latin accents are removed (`café` is `cafe`) [#57](https://github.com/mishka-group/mishka_cms_migration/pull/57)
- A slug or page path segment the site's languages keep nothing of becomes a stable generated ASCII one (`tag-1a2b3c4d`, the same for the same text), so a later run and a post's link to it find it, and the report says so [#57](https://github.com/mishka-group/mishka_cms_migration/pull/57)
- Slug conflicts are found by the slug the Blog stores, so a tag or category the site already holds is matched and asked about exactly [#57](https://github.com/mishka-group/mishka_cms_migration/pull/57)
- Media files, folders and menu components are named as the core names them [#57](https://github.com/mishka-group/mishka_cms_migration/pull/57)

### Dependencies:
- `mishka_cms_core` 0.0.5-alpha.7, `mishka_blog` 0.0.3-alpha.3, `mishka_gervaz` 0.0.7 and the new `mishka_slug` 0.0.1 [#57](https://github.com/mishka-group/mishka_cms_migration/pull/57)

# Changelog for MishkaCmsMigration 0.0.1

- Initial version: [mishka.tools/cms](https://mishka.tools/cms)
