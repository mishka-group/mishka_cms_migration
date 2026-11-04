#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# Records what the seeded WordPress answers for the entries and terms seed_polylang.sh made in English and
# Persian, beside the fixtures record.sh made, and touches none of those:
#   test/fixtures/wordpress/rest/polylang-*.json + *.headers.txt   the REST index and those entries and terms
#   test/fixtures/wordpress/wxr/polylang.xml                         an export of those entries alone
# Polylang's free plugin adds no field to them over REST (its `lang` and `translations` are Polylang Pro's);
# the export carries their languages and translations as Polylang's own taxonomies. Its requests are listed
# in rest/INDEX.txt (its own rows replaced) and the Polylang version in VERSIONS.txt. Secrets are replaced as
# record.sh replaces them. Run it after record.sh and seed_polylang.sh.
set -euo pipefail

cd "$(dirname "$0")"
out=$(cd ../.. && pwd)/test/fixtures/wordpress

[ -f .env.local ] || { echo "No .env.local: run ./seed.sh first." >&2; exit 1; }
[ -f "$out/rest/INDEX.txt" ] || { echo "No fixtures yet: run ./record.sh first." >&2; exit 1; }
set -a
. ./.env.local
set +a
base=$WORDPRESS_URL
auth="$WORDPRESS_USER:$WORDPRESS_APPLICATION_PASSWORD"
index=$out/rest/INDEX.txt

curl -fsS -o /dev/null "$base/wp-json/" || { echo "WordPress is not answering at $base (docker compose up -d --wait)." >&2; exit 1; }

rm -f "$out"/rest/polylang-* "$out/wxr/polylang.xml"
grep -v '^polylang-' "$index" > "$index.tmp" && mv "$index.tmp" "$index"

fetch() { # NAME PATH [none]
  local status mode=app
  if [ "${3:-}" = none ]; then
    mode=none
    status=$(curl -sS -g -D "$out/rest/$1.headers.txt" -o "$out/rest/$1.json" -w '%{http_code}' "$base$2")
  else
    status=$(curl -sS -g -u "$auth" -D "$out/rest/$1.headers.txt" -o "$out/rest/$1.json" -w '%{http_code}' "$base$2")
  fi
  printf '%s.json\tGET\t%s [%s]\t%s\n' "$1" "$2" "$mode" "$status" >> "$index"
  printf '  %-34s %s  %s\n' "$1" "$status" "$2"
}

# A slug as WordPress keeps it: percent-encoded, lower case.
slugs() { local s out=(); for s in "$@"; do out+=("$(jq -rn --arg s "$s" '$s | @uri' | tr 'A-F' 'a-f')"); done; (IFS=,; echo "${out[*]}"); }

v=/wp-json/wp/v2
all="context=edit&per_page=100&status=any"
terms="context=edit&per_page=100"

echo "REST responses"
fetch polylang-index "/wp-json/" none
fetch polylang-posts "$v/posts?$all&slug=$(slugs a-weekend-in-isfahan آخر-هفته-در-اصفهان packing-light یادداشت-سفر)"
fetch polylang-pages "$v/pages?$all&slug=$(slugs our-story داستان-ما our-crew همسفران-ما)"
fetch polylang-categories "$v/categories?$terms&slug=$(slugs travel سفر)"
fetch polylang-tags "$v/tags?$terms&slug=$(slugs coffee قهوه)"

echo "WXR export of the Polylang entries"
wpcli() { docker compose run --rm --no-deps -T wp-cli wp --user=admin "$@" 2>/dev/null; }
ids=$(jq -r '[.[].id] | join(",")' "$out"/rest/polylang-posts.json "$out"/rest/polylang-pages.json | paste -sd, -)
wpcli export --stdout --post__in="$ids" > "$out/wxr/polylang.xml"
ls -l "$out/wxr/polylang.xml" | awk '{ printf "  %-22s %s bytes\n", "polylang.xml", $5 }'

echo "Versions"
polylang=$(wpcli plugin get polylang --field=version | sed -n 1p)
grep -v '^Polylang fixtures' "$out/VERSIONS.txt" > "$out/VERSIONS.txt.tmp" && mv "$out/VERSIONS.txt.tmp" "$out/VERSIONS.txt"
echo "Polylang fixtures (record_polylang.sh): $(date -u +%Y-%m-%dT%H:%M:%SZ), Polylang $polylang" >> "$out/VERSIONS.txt"
tail -n 1 "$out/VERSIONS.txt" | sed 's/^/  /'

echo "Replacing secrets"
admin_email=$(jq -r '.email' "$out/rest/users-me.json")
for f in "$out"/rest/polylang-* "$out/wxr/polylang.xml"; do
  WPPW=$WORDPRESS_APPLICATION_PASSWORD WPADM=$WORDPRESS_ADMIN_PASSWORD WPMAIL=$admin_email \
  perl -pi -e '
    BEGIN { ($pw, $adm, $mail) = @ENV{qw(WPPW WPADM WPMAIL)}; }
    s/\Q$pw\E/REDACTED-APPLICATION-PASSWORD/g if length $pw;
    s/\Q$adm\E/REDACTED-ADMIN-PASSWORD/g if length $adm;
    s/(_wpnonce=)[0-9a-f]{10}/${1}REDACTED-NONCE/g;
    s/("(?:nonce|_wpnonce|rest_nonce|wp_rest_nonce)":\s*")[^"]*(")/${1}REDACTED-NONCE${2}/g;
    s/(X-WP-Nonce:\s*)\S+/${1}REDACTED-NONCE/gi;
    s/\$(?:P|wp)\$[.\/A-Za-z0-9\$]{20,}/REDACTED-PASSWORD-HASH/g;
  ' "$f"
done
if grep -lF -e "$WORDPRESS_APPLICATION_PASSWORD" -e "$WORDPRESS_ADMIN_PASSWORD" "$out"/rest/polylang-* "$out/wxr/polylang.xml" >/dev/null 2>&1; then
  echo "A secret is still in the fixtures." >&2
  exit 1
fi
echo "  done"
