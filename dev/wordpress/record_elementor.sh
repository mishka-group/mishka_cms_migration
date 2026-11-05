#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# Records what the seeded WordPress answers for the entries seed_elementor.sh laid out with Elementor and for
# its global colours and fonts, beside the fixtures record.sh made, and touches none of those:
#   test/fixtures/wordpress/rest/elementor-*.json + *.headers.txt   the REST index (its site fields and
#                                                                    namespaces), Elementor's globals, and
#                                                                    the Elementor pages and post over REST
#   test/fixtures/wordpress/wxr/elementor.xml                         an export of those entries and of the
#                                                                    active kit alone
# Its requests are listed in rest/INDEX.txt (its own rows replaced) and the Elementor version in VERSIONS.txt.
# Secrets are replaced as record.sh replaces them. Run it after record.sh and seed_elementor.sh.
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

rm -f "$out"/rest/elementor-* "$out/wxr/elementor.xml"
grep -v '^elementor-' "$index" > "$index.tmp" && mv "$index.tmp" "$index"

fetch() { # NAME PATH
  local status
  status=$(curl -sS -g -u "$auth" -D "$out/rest/$1.headers.txt" -o "$out/rest/$1.json" -w '%{http_code}' "$base$2")
  printf '%s.json\tGET\t%s [app]\t%s\n' "$1" "$2" "$status" >> "$index"
  printf '  %-34s %s  %s\n' "$1" "$status" "$2"
}

v=/wp-json/wp/v2
all="context=edit&per_page=100&status=any"

echo "REST responses"
fetch elementor-index "/wp-json/?_fields=name,description,url,home,gmt_offset,timezone_string,namespaces,site_logo,site_icon,site_icon_url"
fetch elementor-globals "/wp-json/elementor/v1/globals"
fetch elementor-pages "$v/pages?$all&slug=elementor-landing,elementor-contact"
fetch elementor-posts "$v/posts?$all&slug=elementor-release-notes"

echo "WXR export of the Elementor entries and the active kit"
wpcli() { docker compose run --rm --no-deps -T wp-cli wp --user=admin "$@" 2>/dev/null; }
kit=$(wpcli option get elementor_active_kit | sed -n 1p)
ids=$(jq -r '[.[].id] | join(",")' "$out"/rest/elementor-pages.json "$out"/rest/elementor-posts.json | paste -sd, -),$kit
wpcli export --stdout --post__in="$ids" > "$out/wxr/elementor.xml"
ls -l "$out/wxr/elementor.xml" | awk '{ printf "  %-22s %s bytes\n", "elementor.xml", $5 }'

echo "Versions"
elementor=$(wpcli plugin get elementor --field=version | sed -n 1p)
grep -v '^Elementor fixtures' "$out/VERSIONS.txt" > "$out/VERSIONS.txt.tmp" && mv "$out/VERSIONS.txt.tmp" "$out/VERSIONS.txt"
echo "Elementor fixtures (record_elementor.sh): $(date -u +%Y-%m-%dT%H:%M:%SZ), Elementor $elementor" >> "$out/VERSIONS.txt"
tail -n 1 "$out/VERSIONS.txt" | sed 's/^/  /'

echo "Replacing secrets"
admin_email=$(jq -r '.email' "$out/rest/users-me.json")
for f in "$out"/rest/elementor-* "$out/wxr/elementor.xml"; do
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
if grep -lF -e "$WORDPRESS_APPLICATION_PASSWORD" -e "$WORDPRESS_ADMIN_PASSWORD" "$out"/rest/elementor-* "$out/wxr/elementor.xml" >/dev/null 2>&1; then
  echo "A secret is still in the fixtures." >&2
  exit 1
fi
echo "  done"
