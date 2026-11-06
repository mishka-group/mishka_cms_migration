#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# Builds the trial WordPress on http://localhost:8090 (compose project mishka-wordpress-trial, its own volumes),
# filled like a comprehensive site with Polylang active, for testing the migration by hand. The 8089 site is
# never touched. Credentials go to .env.trial. seed_bulk takes several minutes.
set -euo pipefail
cd "$(dirname "$0")"

export COMPOSE_FILE=docker-compose.yml:docker-compose.trial.yml

./seed.sh
./seed.sh # the second run fixes the links the first one wrote before every post existed
./seed_elementor.sh
./seed_polylang.sh
./seed_e2e.sh
./seed_bulk.sh
