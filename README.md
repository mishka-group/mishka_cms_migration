<div align="center">

[![Buy Me a Coffee](https://img.shields.io/badge/Buy_Me_a_Coffee-mishkagroup-ffdd00?style=flat-square&logo=buy-me-a-coffee&logoColor=black)](https://www.buymeacoffee.com/mishkagroup)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub_Sponsors-mishka--group-ea4aaa?style=flat-square&logo=github)](https://github.com/sponsors/mishka-group)

# Mishka CMS Migration

**A migration extension for [Mishka CMS](https://mishka.tools/cms): move a WordPress site, and later Joomla and other CMSs, into it.**

[Mishka CMS](https://mishka.tools/cms) · [Hire us](https://mishka.tools/hire-us)

</div>

## 📖 What is Mishka CMS Migration?

`mishka_cms_migration` is the migration extension of Mishka CMS. It will move a site from another CMS into a Mishka CMS site: blog posts, categories, tags and authors, pages, media, redirects and site settings. Every record is written by the existing CMS actions as the admin who pressed Import, so the CMS's policies and validations decide, and the plugins that react to a change (sitemap, share cards, stylesheet) react as usual.

- [ ] WordPress
- [ ] Joomla
- [ ] Drupal
- [ ] Ghost

## 🔌 In a host

The CMS adds `MishkaCmsMigration` to its `ash_domains`, runs `mix ash.codegen` for the runs and items tables, and gives Oban a `migration` queue (`queues: [migration: 1]`); it starts Oban with `AshOban.config/2` over its `ash_domains`, as Mishka CMS does, since the jobs are AshOban triggers on the run. Installing the extension on a site from the CMS's installer creates the `admin:dashboard:migration` and `admin:api:migration` permissions, which a site's admin is then granted. Sources and targets are Mishka Installer plugins, each supervised by the extension that ships it; none ships yet.

## 🔀 Several sources into one site

A site can take content from more than one source: a run names the host it reads from, and what the migration remembers of each item is kept per site, host, kind and source id. Two WordPress blogs moved into one site keep separate items and CMS records, the same id on both hosts is two items, and re-running one host updates only what that host wrote. When two sources ask for the same thing in the CMS, such as the same address, the CMS action refuses the second, and the run reports that item as failed with the CMS's reason; nothing is overwritten. Each run shows the host it reads from.

## 🗂️ Layout

```
lib/
├── mishka_cms_migration.ex           the Ash domain and its code interfaces
└── mishka_cms_migration/
    ├── application.ex                the plugins the extension supervises
    ├── repo.ex                       the Postgres repo when the extension runs on its own (the CMS's repo inside the CMS)
    ├── source.ex                     the source behaviour, the item every source hands over, the installed plugins
    ├── target.ex                     the target behaviour: a kind of item written by an existing CMS action
    ├── events.ex                     migration:content:convert, migration:item:before_import, migration:import:finished
    ├── report.ex                     what a dry run or an import did with each item
    ├── provision.ex                  installing the extension on a site: its permission names
    ├── resources/                    MigrationRun and MigrationItem, with their __changes and __validations
    ├── workers.ex                    the AshOban jobs, and the handler that fails a run whose job Oban discarded
    └── workers/__helpers/            what a job does: the walk, the decision, the write, who it runs as, the discard handler
test/
├── mishka_cms_migration/             behaviour tests: runs, items, the walk, events, targets, provisioning
├── support/                          the case, the factory, and plugins for the suite: a fake source, two targets, event probes
└── fixtures/wordpress/               REST responses and WXR exports recorded from dev/wordpress
dev/
└── wordpress/                        a real WordPress in Docker, seeded with realistic content, and the script that records it
```

`dev/wordpress/` runs WordPress and MariaDB in Docker on this machine, fills the site with the content a migration meets (every block, shortcodes, nested terms, media, threaded comments, menus, Yoast SEO) and records what it answers into `test/fixtures/wordpress/` (its `README.md` says how). Nothing replays the fixtures yet: the WordPress source (#4) will, so its tests run against what a real site says rather than hand-written JSON.

## 🧩 Part of Mishka CMS

Mishka CMS Migration is an extension of [Mishka CMS: Open-Source Multi-Site CMS](https://mishka.tools/cms), built like [Mishka Blog: Open-Source Blog Engine](https://mishka.tools/cms/extensions/blog) and [Mishka Document: Versioned Docs Engine](https://mishka.tools/cms/extensions/documentation): Ash resources, Mishka Installer plugins, mishka_gervaz admin screens and Oban jobs.

## 🚀 Getting started

It is not on Hex yet. Until its first release, add it from GitHub:

```elixir
{:mishka_cms_migration, github: "mishka-group/mishka_cms_migration"}
```

To work on it, clone it next to `mishka_cms_core`, `mishka_gervaz` and `mishka_installer`. `mix.exs` takes a sibling checkout over the Hex release when there is one. Then:

```sh
mix deps.get
MIX_ENV=test mix ash.codegen setup
mix test
```

There is no screen yet and no real source: the only source is the suite's fake one (`test/support/plugins/fake_source.ex`), so a run is tried through the tests, which create, dry-run and import runs over it.

`mix ci` runs every check: `hex.audit`, compile with warnings as errors, format, credo, sobelow, `deps.audit`, dialyzer, ExDNA and the tests. The tests need PostgreSQL on `localhost` (user and password `postgres`, or `POSTGRES_USER`, `POSTGRES_PASSWORD` and `POSTGRES_HOST`).

## 💬 Community and support

- Report a bug or ask a question in [GitHub issues](https://github.com/mishka-group/mishka_cms_migration/issues).
- Read about new releases on the [Mishka blog](https://mishka.tools/blog).
- For a custom migration or priority support, [hire the Mishka team](https://mishka.tools/hire-us).

## 💖 Support the project

Mishka CMS and its extensions are free and open source. You can support their development through [GitHub Sponsors](https://github.com/sponsors/mishka-group) or [Buy Me a Coffee](https://www.buymeacoffee.com/mishkagroup).

## 📜 License

Apache License 2.0. See [LICENSE](LICENSE).
