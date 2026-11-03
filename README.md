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

The CMS adds `MishkaCmsMigration` to its `ash_domains`, runs `mix ash.codegen` for the runs and items tables, and gives Oban a `migration` queue (`queues: [migration: 1]`); it starts Oban with `AshOban.config/2` over its `ash_domains`, as Mishka CMS does, since the jobs are AshOban triggers on the run. Installing the extension on a site from the CMS's installer creates the `admin:dashboard:migration` and `admin:api:migration` permissions, which a site's admin is then granted. Sources and targets are Mishka Installer plugins, each supervised by the extension that ships it. This extension ships the WordPress source, read over its REST API or from the file its Tools ▸ Export makes, and, where [Mishka Blog: Open-Source Blog Engine](https://mishka.tools/cms/extensions/blog) runs beside it, the targets that write a site's authors (as bloggers of the site's users, matched by email, or of new users when the admin chooses), categories (with their parents), tags and posts (their content converted to HTML, each with its author) into the Blog; on a CMS without the Blog those kinds are skipped.

## 🔁 How a migration runs

An admin creates a run (the source, the host it reads from, how to connect, their choices), then asks for a dry run: a job walks the source and reports what an import would create, update and skip, writing nothing in the CMS: it records each item's plan, which the run's Items page shows. Once it has reported, the admin asks for the import, which writes each item through the CMS's own actions as that admin and saves the report. A run ends `done`, `failed` (with the reason, after the job's last attempt) or `cancelled` (the admin stopped it; a running job stops at its next page). Running again is a new run, which updates what the source changed and keeps what an admin changed in the CMS.

The dry run and the import are AshOban jobs on the `migration` queue, three attempts of an hour each. A site has one run dry running or importing at a time; the database refuses a second. [`MishkaCmsMigration.MigrationRun`](lib/mishka_cms_migration/resources/migration_run.ex) has the whole life of a run.

## 🔀 Several sources into one site

A site can take content from more than one source: a run names the host it reads from, and what the migration remembers of each item is kept per site, host, kind and source id. Two WordPress blogs moved into one site keep separate items and CMS records, the same id on both hosts is two items, and re-running one host updates only what that host wrote. When two sources ask for the same thing in the CMS, such as the same address, the CMS action refuses the second, and the run reports that item as failed with the CMS's reason; nothing is overwritten. Each run shows the host it reads from, and its Items page lists everything the migration keeps of that host on the site: each item's kind, title, source id, what the last dry run would do with it and what the last import did, and why, filtered by kind, plan, last import, title and the run that imported it last, with links to its CMS record in the admin and on the site, and the item's kept WordPress fields as JSON. Before an import, the Items page decides what it brings: an item can be left out, alone or with every row the filters pick, and what sits under it goes with it; a category or a tag can be mapped to one the site already has, and is linked to it instead of written. Its Map view draws the categories as WordPress nests them.

## 🗂️ Layout

```
lib/
├── mishka_cms_migration.ex           the Ash domain and its code interfaces
└── mishka_cms_migration/
    ├── application.ex                the plugins the extension supervises
    ├── repo.ex                       the Postgres repo when the extension runs on its own (the CMS's repo inside the CMS)
    ├── source.ex                     the source behaviour, the item every source hands over, the installed plugins
    ├── sources/                      the sources it ships: WordPress and its export file, how a post's content becomes HTML, how an export is streamed
    ├── target.ex                     the target behaviour: a kind of item written by an existing CMS action
    ├── targets/                      the targets it ships: pages into the CMS's pages, and authors, categories, tags and posts into Mishka Blog, where it runs
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
├── playground.exs                    `mix playground`: a run walked through by hand over the fake source
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

To work on it, clone it next to `mishka_cms_core`, `mishka_gervaz`, `mishka_installer` and `guarded_struct`. `mix.exs` takes a sibling checkout over the Hex release when there is one. Then:

```sh
mix deps.get
MIX_ENV=test mix ash.codegen setup
mix test
```

There is no screen yet and no real source. The only source is the suite's fake one (`test/support/plugins/fake_source.ex`): the tests create, dry-run and import runs over it, and `mix playground` (below) does the same by hand.

`mix ci` runs every check: `hex.audit`, compile with warnings as errors, format, credo, sobelow, `deps.audit`, dialyzer, ExDNA and the tests. The tests need PostgreSQL on `localhost` (user and password `postgres`, or `POSTGRES_USER`, `POSTGRES_PASSWORD` and `POSTGRES_HOST`).

**Try it by hand.** `mix playground` walks through a run over the fake source and checks each step in plain words, then rolls everything back. `iex -S mix playground` does the same and stays in IEx with a `Playground` module to try your own rows. It needs the same PostgreSQL as the tests:

```sh
mix playground
iex -S mix playground
```

## 💬 Community and support

- Report a bug or ask a question in [GitHub issues](https://github.com/mishka-group/mishka_cms_migration/issues).
- Read about new releases on the [Mishka blog](https://mishka.tools/blog).
- For a custom migration or priority support, [hire the Mishka team](https://mishka.tools/hire-us).

## 💖 Support the project

Mishka CMS and its extensions are free and open source. You can support their development through [GitHub Sponsors](https://github.com/sponsors/mishka-group) or [Buy Me a Coffee](https://www.buymeacoffee.com/mishkagroup).

## 📜 License

Apache License 2.0. See [LICENSE](LICENSE).
