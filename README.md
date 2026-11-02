<div align="center">

[![Buy Me a Coffee](https://img.shields.io/badge/Buy_Me_a_Coffee-mishkagroup-ffdd00?style=flat-square&logo=buy-me-a-coffee&logoColor=black)](https://www.buymeacoffee.com/mishkagroup)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub_Sponsors-mishka--group-ea4aaa?style=flat-square&logo=github)](https://github.com/sponsors/mishka-group)

# Mishka CMS Migration

**A migration extension for [Mishka CMS](https://mishka.tools/cms): move a WordPress site, and later Joomla and other CMSs, into it.**

[Mishka CMS](https://mishka.tools/cms) · [Plan](https://github.com/mishka-group/mishka_cms_migration/issues/1) · [Hire us](https://mishka.tools/hire-us)

</div>

## 📖 What is Mishka CMS Migration?

`mishka_cms_migration` is the migration extension of Mishka CMS. It will move a site from another CMS into a Mishka CMS site: blog posts, categories, tags and authors, pages, media, redirects and site settings. Every row is written by the existing CMS actions as the admin who pressed Import, so the CMS's policies and validations decide, and the plugins that react to a change (sitemap, share cards, stylesheet) react as usual.

WordPress is the first source. Joomla and others come later as plugins that reuse the same mapping, dry run, import job and report.

This release is the project setup: the package, its checks and its test harness. There is no import feature yet. The plan and its steps are in [issue #1](https://github.com/mishka-group/mishka_cms_migration/issues/1).

## 🧩 Part of Mishka CMS

Mishka CMS Migration is an extension of [Mishka CMS](https://mishka.tools/cms), an open source real-time CMS. It runs on [mishka_cms_core](https://github.com/mishka-group/mishka_cms_core), the engine, inside the [mishka_cms](https://github.com/mishka-group/mishka_cms) application, and it is built like [mishka_blog](https://github.com/mishka-group/mishka_blog) and [mishka_document](https://github.com/mishka-group/mishka_document): Ash resources, Mishka Installer plugins, mishka_gervaz admin screens and Oban jobs.

## 🚀 Getting started

Add it from Hex:

```elixir
{:mishka_cms_migration, "~> 0.0.1-alpha.1"}
```

To work on it, clone it next to `mishka_cms_core`, `mishka_gervaz` and `mishka_installer`. `mix.exs` takes a sibling checkout over the Hex release when there is one. Then:

```sh
mix deps.get
MIX_ENV=test mix ash.codegen setup
mix test
```

`mix ci` runs every check: `hex.audit`, compile with warnings as errors, format, credo, sobelow, `deps.audit`, dialyzer, ExDNA and the tests. The tests need PostgreSQL on `localhost` (user and password `postgres`, or `POSTGRES_USER`, `POSTGRES_PASSWORD` and `POSTGRES_HOST`).

## 💬 Community and support

- Report a bug or ask a question in [GitHub issues](https://github.com/mishka-group/mishka_cms_migration/issues).
- Read about new releases on the [Mishka blog](https://mishka.tools/blog).
- For a custom migration or priority support, [hire the Mishka team](https://mishka.tools/hire-us).

## 💖 Support the project

Mishka CMS and its extensions are free and open source. You can support their development through [GitHub Sponsors](https://github.com/sponsors/mishka-group) or [Buy Me a Coffee](https://www.buymeacoffee.com/mishkagroup).

## 📜 License

Apache License 2.0. See [LICENSE](LICENSE).
