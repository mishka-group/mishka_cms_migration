<!--
SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>

SPDX-License-Identifier: Apache-2.0
-->

# A real WordPress for the migration tests

WordPress 7.1.4 and MariaDB in Docker, bound to this machine only, filled with realistic content and
with Yoast SEO active. The extension's tests replay what this site really answers, so nothing in them is
hand-written mock JSON.

```sh
cd dev/wordpress
docker compose up -d --wait   # http://localhost:8089
./seed.sh                     # installs and fills the site; safe to run again; writes .env.local
./record.sh                   # records the REST responses and the WXR export as test fixtures
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
| Posts | every core block, a classic post with `[caption]` `[gallery]` `[embed]` `[video]`, internal links of every shape, featured images, sticky, scheduled (2099), draft, pending, private, password-protected, trashed, Persian slug, a 128 KB post, an `aside` format post, an unknown plugin block |
| Pages | home and blog (static front page), about > team > leadership, docs > getting-started, contact, a draft, a private page, and the core Privacy Policy draft |
| Media | jpg, png, webp, gif, pdf, mp4 and svg, each with alt text, caption and description (`media/`, drawn by `make-media.py`) |
| Comments | threaded three levels, pending, spam, a pingback, on posts and a page |
| Menus | a nested Primary menu, a Footer menu, a block-theme navigation |
| SEO | Yoast SEO titles, descriptions, noindex/nofollow, social titles and images, a canonical |

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

Record on a clean site (`down -v`, `./seed.sh`, `./record.sh`) and only from this curated seed, never after
adding bulk content, so the fixtures stay small and the same.

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
`docker compose down -v && ./seed.sh && ./record.sh`.

## Testing approach

- **Unit tests** replay the recorded responses from `test/fixtures/wordpress/` (REST bodies and headers, WXR files).
  They need no network and no Docker.
- **Integration tests** are tagged `:wordpress`, excluded by default (`ExUnit.configure(exclude: [:wordpress])`), and
  run against this container with `mix test --include wordpress` to confirm the recordings still match what
  WordPress answers. They read the URL and application password from `dev/wordpress/.env.local`.
