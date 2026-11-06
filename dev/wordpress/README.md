<!--
SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>

SPDX-License-Identifier: Apache-2.0
-->

# A real WordPress for the migration tests

WordPress 7.1.4 and MariaDB in Docker, bound to this machine only, filled with realistic content and
with Yoast SEO active. The extension's tests will replay (the WordPress source, #4) what this site really
answers, so nothing in them is hand-written mock JSON.

```sh
cd dev/wordpress
docker compose up -d --wait   # http://localhost:8089
./seed.sh                     # installs and fills the site; safe to run again; writes .env.local
./record.sh                   # records the REST responses and the WXR export as test fixtures
./seed_elementor.sh           # adds Elementor and the entries laid out with it (below)
./record_elementor.sh         # records those entries beside the other fixtures
./seed_polylang.sh            # adds Polylang, English and Persian, and entries and terms in both (below)
./record_polylang.sh          # records those entries and terms beside the other fixtures
docker compose down -v        # stops it and deletes the site (named volumes included)
```

- **Site:** http://localhost:8089, admin at `/wp-admin` (user `admin`).
- **Secrets:** `seed.sh` writes `.env.local` (git-ignored): `WORDPRESS_APPLICATION_PASSWORD` for the REST
  API (HTTP Basic, user `admin`; it works over plain HTTP because `WP_ENVIRONMENT_TYPE` is `local`) and
  `WORDPRESS_ADMIN_PASSWORD` for the login form.
- **WP-CLI:** `docker compose run --rm wp-cli wp --user=admin post list`. Pass `--user=admin`, or WordPress
  strips the HTML a CLI-made post may hold.

```sh
curl -u "admin:$WORDPRESS_APPLICATION_PASSWORD" \
  'http://localhost:8089/wp-json/wp/v2/posts?context=edit&per_page=100&status=any'
```

## What is seeded

| Kind | What |
| --- | --- |
| Users | admin, an editor whose email (`shahryar@mishka.tools`) matches a Mishka CMS user, two authors (one with a Persian name), a contributor; all with bios |
| Terms | nested categories (News > Releases, Tutorials > WordPress > Migration, a Persian one), tags |
| Posts | every core block, a classic post with `[caption]` `[gallery]` `[embed]` `[video]` and a Vimeo address alone on its line, YouTube and Vimeo embed blocks and a YouTube `<iframe>`, internal links of every shape, featured images, sticky, scheduled (2099), draft, pending, private, password-protected, trashed, Persian slug, a 128 KB post, an `aside` format post, an unknown plugin block |
| Pages | home and blog (static front page), about > team > leadership, docs > getting-started, contact, a draft, a private page, and the core Privacy Policy draft |
| Media | jpg, png, webp, gif, pdf, mp4 and svg, each with alt text, caption and description (`media/`, drawn by `make-media.py`); two PNGs are the site's logo and icon (`site_logo`, `site_icon`) |
| Comments | threaded three levels, pending, spam, a pingback, on posts and a page |
| Menus | a nested Primary menu, a Footer menu, a block-theme navigation |
| SEO | Yoast SEO titles (one with Yoast's variables), descriptions, noindex/nofollow, social titles and images, a canonical on the site and one elsewhere; Rank Math's title, description, robots, image and canonical on one post, stored as Rank Math stores them (Rank Math itself is not installed: it adds nothing to the REST API, so only the export carries its fields) |

What WordPress refuses is recorded as it is: it rejects an SVG upload (`rest_upload_sideload_error`, kept
in `rest/media-upload-svg-refused.*`), so `seed.sh` imports the SVG once with the type allowed, the way a
site with an SVG plugin has it. WordPress has no avatar upload, so an author's picture is only the
Gravatar address in `avatar_urls`; the four avatar images sit in the media library.

## Recording

`record.sh` writes `test/fixtures/wordpress/`:

- `rest/NAME.json` is the body and `rest/NAME.headers.txt` the headers (`X-WP-Total`, `X-WP-TotalPages`, `Link`) of
  one request; `rest/INDEX.txt` lists every request and its status. Collections use `context=edit` and
  `per_page=100`, plus a second page, an out-of-range page, 401 responses (no credentials, wrong password,
  unknown user) and the refused SVG upload.
- `wxr/all-content.xml` and `wxr/posts-only.xml` come from `wp export`, the same code as Tools > Export.
- `VERSIONS.txt` names the WordPress, PHP, MariaDB, WP-CLI, theme and plugin versions.

Only secrets are replaced, with fixed placeholders (`REDACTED-APPLICATION-PASSWORD`, `REDACTED-NONCE`, ...);
the admin email is already the placeholder `admin@example.test`. `counts.sh` compares the REST totals with the
WXR item counts from the recorded files alone.

Record on a clean site (`down -v`, `./seed.sh` twice, `./record.sh`) and only from this curated seed, never after
adding bulk content, so the fixtures stay small and the same. The second seed run changes nothing but the links
the first one wrote before every post existed: a file's attachment page then sits under the post it is attached
to, and the export's `<link>` is the site's home.

## Elementor

`seed_elementor.sh` runs after `seed.sh` and adds Elementor (the free plugin), the global colours and fonts of its
active kit (Site Settings, `seed/elementor-kit.json`: the four system colours and fonts changed, two custom colours and a
custom font in a system family), and the entries laid out with it, `seed/elementor/*.json` (each one's fields and its
elements in the shape Elementor saves them): a page of sections, columns and an inner section with every common
widget, some of them coloured and set in the kit's colours and fonts, others in their own, with a column's padding, a
widget's margin, an image's alignment and width and named column gaps, a page of containers with widgets the CMS has
no equivalent for (Elementor Pro's form and slides, an image carousel, a map), and a post of containers. The kit and
each entry are saved through Elementor's own document API, so `_elementor_page_settings`, `_elementor_data`, its edit
mode and the HTML fallback in `post_content` are what Elementor writes; the Pro widgets, which Elementor drops on a
site without Pro, are put back where they were. It touches nothing else, the passwords and `.env.local` included, so
it runs on a site already in use, and a second run changes nothing but the kit and those entries.

`record_elementor.sh` records only these entries, beside what `record.sh` made: `rest/elementor-index.*` (the
REST index's site fields and namespaces, which list Elementor's `elementor/v1`), `rest/elementor-globals.*` (the
kit's colours and fonts, Elementor's own `/elementor/v1/globals`), `rest/elementor-pages.*`, `rest/elementor-posts.*`
and `wxr/elementor.xml` (an export of those entries and the active kit alone), with its rows in `rest/INDEX.txt` and
the Elementor version in `VERSIONS.txt`, and `../google_fonts/elementor-globals.css`, what Google Fonts answers a
browser for the `@import` the kit's fonts make, asked with the same `user-agent` the stylesheet target sends. On a clean site record the curated seed first, then these:

```sh
docker compose down -v && ./seed.sh && ./seed.sh && ./record.sh
./seed_elementor.sh && ./record_elementor.sh
```

## Polylang

`seed_polylang.sh` runs after `seed.sh` and adds Polylang (the free plugin) with two languages, English (the default)
and Persian, and a few entries and terms in them: the category Travel and the tag Coffee in both languages, the post
A Weekend in Isfahan in both, Packing Light in English alone and یادداشت سفر in Persian alone, and the page Our Story
with Our Crew under it, in both. Each translation is linked to its original through Polylang's own API. It gives no
language to anything `seed.sh` made, adds no default category for a language, and touches nothing else, the
passwords and `.env.local` included; a second run changes nothing.

`record_polylang.sh` records only these, beside what `record.sh` made: `rest/polylang-index.*` (the REST index,
which lists Polylang's `pll/v1`), `rest/polylang-posts.*`, `rest/polylang-pages.*`, `rest/polylang-categories.*`,
`rest/polylang-tags.*` and `wxr/polylang.xml` (an export of those entries alone), with its rows in `rest/INDEX.txt`
and the Polylang version in `VERSIONS.txt`. The free plugin adds no field to an entry or a term over REST: its `lang`
and `translations` are Polylang Pro's. The export carries both, as Polylang's own taxonomies: an entry's `language`
and `post_translations` terms, and the `term_translations` terms, each describing its group as a serialized map of
language to id.

```sh
./seed_polylang.sh && ./record_polylang.sh
```

## E2E data

`seed_e2e.sh` runs after `seed.sh` and adds what the browser e2e of the migration needs and the curated seed lacks.
It finds each entry by slug (a user by login, the menu by name, a comment by author and text), creates only what is
missing and writes an existing one only when it differs, so a second run changes nothing. It never touches the
passwords or `.env.local`, and its entries carry the slug prefix `e2e-` and the post meta `_e2e_seed`.

| Entry | For |
| --- | --- |
| `e2e-youtube-embed` | a YouTube embed block and an `[embed]` shortcode (the "Big Buck Bunny" video) |
| `e2e-scripts-and-handlers` | a `<script>` in a Custom HTML block and an `onclick` on a link: "Contains scripts or inline event handlers"; also in the category `blog` |
| `e2e-duplicate-a`, `e2e-duplicate-b`, `e2e-same-name-other-bytes` | media: A and B are the same bytes under different titles, C has the same file name and other bytes; `e2e-duplicate-media` uses A |
| page `privacy` (title "E2E Privacy"), category `blog` | addresses a fresh Mishka CMS site already has (`/privacy`, the `/blog` front page); `about` and `contact` already come from `seed.sh`: the "Connect / Import as new" decision |
| site title, tagline, logo, icon | the script only checks they are set (they are), so a CMS site with its own values gets "Keep / Use WordPress" |
| users `e2e-author1`, `e2e-author2` and the posts `e2e-by-author-1`, `e2e-by-author-2` | users no CMS has: user creation and the "Forgot password" warning |
| menu "E2E Header" | a classic menu with no location, only published pages and posts, for Header links without draft conflicts |
| `e2e-guest-comments` | two approved guest comments (one with a website) and a guest reply |

Polylang stays off for these runs. Switch it on for the language tests and off after them:

```sh
docker compose run --rm -T wp-cli wp --user=admin plugin activate polylang
docker compose run --rm -T wp-cli wp --user=admin plugin deactivate polylang
```

## Bulk content

`seed_bulk.sh` runs after `seed.sh` and fills the site the way a company blog looks after years of use: 8 more
users, 25 categories (some nested), about 80 tags, 40 pages in a hierarchy, 350 posts in every status with
block and classic bodies, featured images, excerpts, internal links and a few password-protected and sticky
posts, about 600 comments with replies, and an extra menu. The text comes from the banks in `bulk/`, and the
plan (`bulk/plan-*.sh`) uses a fixed seed. It is safe to run again: a second run creates nothing.

```sh
cd dev/wordpress
./seed.sh && ./seed_bulk.sh   # the bulk run takes several minutes
```

Fixtures are never recorded from bulk data. Record only from the curated seed, on a clean site:
`docker compose down -v && ./seed.sh && ./seed.sh && ./record.sh`.

## Trial site

A second, comprehensive WordPress for testing the migration by hand, on http://localhost:8090 (admin at `/wp-admin`,
user `admin`), beside the 8089 one and never touching it: its own compose project `mishka-wordpress-trial`, its own
volumes (`docker-compose.trial.yml`, `wp-cli.trial.yml`). `./trial.sh` seeds it with everything above (curated seed
twice, Elementor, Polylang, the e2e data, the bulk content; several minutes) and leaves Polylang active. The
application password and the admin login are in `.env.trial` (git-ignored).

```sh
./trial.sh                                              # builds and fills http://localhost:8090
export COMPOSE_FILE=docker-compose.yml:docker-compose.trial.yml
docker compose stop                                     # stops it, keeps the site
docker compose down -v                                  # deletes the trial site and only it
docker compose run --rm -T wp-cli wp --user=admin plugin deactivate polylang   # Polylang off
docker compose run --rm -T wp-cli wp --user=admin plugin activate polylang     # Polylang on
```

Run those in a shell where `COMPOSE_FILE` is set as above; without it, `docker compose` talks to the 8089 project.

## Testing approach

- **Unit tests** replay the recorded responses from `test/fixtures/wordpress/` (REST bodies and headers, WXR files).
  They need no network and no Docker.
- **Integration tests** are tagged `:wordpress`, excluded by default (`ExUnit.configure(exclude: [:wordpress])`), and
  run against this container with `mix test --include wordpress` to confirm the recordings still match what
  WordPress answers. They read the URL and application password from `dev/wordpress/.env.local`.
