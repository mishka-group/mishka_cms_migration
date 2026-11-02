# Changelog for MishkaCmsMigration 0.0.1

- Initial version: [mishka.tools/cms](https://mishka.tools/cms)
- The project is set up like `mishka_blog` and `mishka_document`: the Mix package, an OTP application with no plugin yet, an Ash domain with no resource yet, the standalone test harness and a smoke test. It runs on `mishka_cms_core` 0.0.4, `mishka_gervaz` 0.0.3 and `mishka_installer` 0.1.15 from Hex, on Erlang 29.1.2 and Elixir 1.20.5
- CI runs the build, format check, `deps.audit` and the tests against PostgreSQL 18; `hex.audit` reports to code scanning every day; a `v*` tag builds the Hex package and the compiled ebin for a GitHub release
