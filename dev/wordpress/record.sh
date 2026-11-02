#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# Records what the seeded WordPress really answers, as test fixtures:
#   test/fixtures/wordpress/rest/*.json + *.headers.txt   REST responses, body and headers as WordPress sent them
#   test/fixtures/wordpress/wxr/*.xml                     the Tools > Export file, made with `wp export`
#   test/fixtures/wordpress/VERSIONS.txt                  what produced them
# Only secrets are replaced (application password, admin password, nonces, password hashes, the admin email);
# everything else stays byte for byte. Record from the curated seed only: run seed.sh first, record.sh before
# adding any bulk content, and re-record on a clean volume (`docker compose down -v`, `./seed.sh`).
set -euo pipefail

cd "$(dirname "$0")"
here=$(pwd)
out=$(cd ../.. && pwd)/test/fixtures/wordpress

[ -f .env.local ] || { echo "No .env.local: run ./seed.sh first." >&2; exit 1; }
set -a
. ./.env.local
set +a
base=$WORDPRESS_URL
auth="$WORDPRESS_USER:$WORDPRESS_APPLICATION_PASSWORD"
placeholder_email=admin@example.test

curl -fsS -o /dev/null "$base/wp-json/" || { echo "WordPress is not answering at $base (docker compose up -d --wait)." >&2; exit 1; }

rm -rf "$out/rest" "$out/wxr" "$out/VERSIONS.txt"
mkdir -p "$out/rest" "$out/wxr"
index=$out/rest/INDEX.txt
printf 'file\tmethod\trequest\tstatus\n' > "$index"

# fetch NAME PATH [app|none|wrong|baduser]: writes rest/NAME.json (the body) and rest/NAME.headers.txt
fetch() {
  local name=$1 path=$2 mode=${3:-app} status
  local creds=()
  case $mode in
    app) creds=(-u "$auth") ;;
    wrong) creds=(-u "$WORDPRESS_USER:wrong-wrong-wrong-wrong") ;;
    baduser) creds=(-u "nobody:$WORDPRESS_APPLICATION_PASSWORD") ;;
  esac
  status=$(curl -sS -g ${creds[@]+"${creds[@]}"} -D "$out/rest/$name.headers.txt" -o "$out/rest/$name.json" \
    -w '%{http_code}' "$base$path")
  printf '%s.json\tGET\t%s [%s]\t%s\n' "$name" "$path" "$mode" "$status" >> "$index"
  printf '  %-34s %s  %s\n' "$name" "$status" "$path"
}

v=/wp-json/wp/v2
all="context=edit&per_page=100"

echo "REST responses"
fetch index /wp-json/ none
fetch posts "$v/posts?$all&status=any"
fetch posts-page-2 "$v/posts?context=edit&per_page=10&page=2&status=any&_fields=id,date,modified,slug,status,type,link,title"
fetch posts-page-out-of-range "$v/posts?$all&page=99&status=any"
fetch posts-trash "$v/posts?$all&status=trash"
fetch posts-embed "$v/posts?context=edit&per_page=3&status=any&_embed=1"
fetch posts-public "$v/posts?per_page=5" none
fetch pages "$v/pages?$all&status=any"
fetch media "$v/media?$all"
fetch users "$v/users?$all"
fetch users-me "$v/users/me?context=edit"
fetch categories "$v/categories?$all"
fetch tags "$v/tags?$all"
fetch comments "$v/comments?$all&status=all"
fetch comments-default "$v/comments?$all"
fetch comments-pingback "$v/comments?$all&status=all&type=pingback"
fetch comments-spam "$v/comments?$all&status=spam"
fetch menus "$v/menus?$all"
fetch menu-items "$v/menu-items?$all"
fetch navigation "$v/navigation?$all&status=any"
fetch blocks "$v/blocks?$all&status=any"
fetch settings "$v/settings"
fetch types "$v/types?context=edit"
fetch taxonomies "$v/taxonomies?context=edit"
fetch statuses "$v/statuses?context=edit"
fetch plugins "$v/plugins"
fetch themes-active "$v/themes?status=active"
fetch post-not-found "$v/posts/999999?context=edit"

# One post and one media item by id, found in the lists just recorded.
post_id=$(jq -r '.[] | select(.slug == "gutenberg-all-core-blocks") | .id' "$out/rest/posts.json")
media_id=$(jq -r '.[] | select(.slug == "hero") | .id' "$out/rest/media.json")
fetch post-single "$v/posts/$post_id?context=edit"
fetch media-single "$v/media/$media_id?context=edit"

# What a client sees when the credentials are missing or wrong, or a host strips the Authorization header
# (that looks exactly like no credentials).
fetch unauthorized-no-credentials "$v/posts?$all" none
fetch unauthorized-wrong-password "$v/posts?$all" wrong
fetch unauthorized-unknown-user "$v/posts?$all" baduser
fetch unauthorized-status-any "$v/posts?$all&status=any" none
fetch unauthorized-settings "$v/settings" none
fetch unauthorized-users-me "$v/users/me?context=edit" none
fetch unauthorized-users-me-wrong-password "$v/users/me?context=edit" wrong
fetch unauthorized-users-me-unknown-user "$v/users/me?context=edit" baduser

# WordPress refuses an SVG upload by default; the answer is what an importer sees from a host that cannot take it.
status=$(curl -sS -u "$auth" -X POST -H 'Content-Type: image/svg+xml' \
  -H 'Content-Disposition: attachment; filename="upload-refused.svg"' --data-binary @media/logo.svg \
  -D "$out/rest/media-upload-svg-refused.headers.txt" -o "$out/rest/media-upload-svg-refused.json" \
  -w '%{http_code}' "$base$v/media")
printf 'media-upload-svg-refused.json\tPOST\t%s/media (an SVG upload) [app]\t%s\n' "$v" "$status" >> "$index"
printf '  %-34s %s  POST %s/media\n' media-upload-svg-refused "$status" "$v"

echo "WXR export (wp export, as Tools > Export makes it)"
wpcli() { docker compose run --rm -T wp-cli wp --user=admin "$@" 2>/dev/null; }
wpcli export --stdout > "$out/wxr/all-content.xml"
wpcli export --stdout --post_type=post > "$out/wxr/posts-only.xml"
ls -l "$out"/wxr | tail -n +2 | awk '{ printf "  %-22s %s bytes\n", $9, $5 }'

echo "Versions"
{
  echo "Recorded: $(date -u +%Y-%m-%dT%H:%M:%SZ) from $base"
  echo "WordPress: $(wpcli core version)  (image wordpress:7.1.4-php8.4-apache)"
  echo "PHP: $(wpcli eval 'echo PHP_VERSION;')"
  echo "Database: $(wpcli eval 'global $wpdb; echo $wpdb->db_version();')  (image mariadb:11.8.9)"
  echo "WP-CLI: $(docker compose run --rm -T wp-cli wp --version 2>/dev/null | sed 's/WP-CLI //')  (image wordpress:cli-2.12.0-php8.4)"
  echo "Theme: $(wpcli theme list --status=active --fields=name,version --format=csv | tail -n +2 | tr ',' ' ')"
  echo "Plugins:"
  wpcli plugin list --fields=name,status,version --format=csv | tail -n +2 | tr ',' ' ' | sed 's/^/  /'
  echo "Site: timezone $(wpcli option get timezone_string), permalinks $(wpcli option get permalink_structure)"
  echo "Application passwords need WP_ENVIRONMENT_TYPE=local on plain HTTP; in production they need HTTPS."
} > "$out/VERSIONS.txt"
cat "$out/VERSIONS.txt" | sed 's/^/  /'

echo "Replacing secrets"
admin_email=$(jq -r '.email' "$out/rest/users-me.json")
secrets=$(mktemp)
trap 'rm -f "$secrets"' EXIT
printf '%s\n%s\n' "$WORDPRESS_APPLICATION_PASSWORD" "$WORDPRESS_ADMIN_PASSWORD" > "$secrets"
hits=$( (grep -rlF -f "$secrets" "$out" 2>/dev/null || true) | wc -l | tr -d ' ')
for f in "$out"/rest/* "$out"/wxr/* "$out"/VERSIONS.txt; do
  WPPW=$WORDPRESS_APPLICATION_PASSWORD WPADM=$WORDPRESS_ADMIN_PASSWORD WPMAIL=$admin_email WPHOLD=$placeholder_email \
  perl -pi -e '
    BEGIN { ($pw, $adm, $mail, $hold) = @ENV{qw(WPPW WPADM WPMAIL WPHOLD)}; }
    s/\Q$pw\E/REDACTED-APPLICATION-PASSWORD/g if length $pw;
    s/\Q$adm\E/REDACTED-ADMIN-PASSWORD/g if length $adm;
    s/\Q$mail\E/$hold/g if length $mail && $mail ne $hold;
    s/(_wpnonce=)[0-9a-f]{10}/${1}REDACTED-NONCE/g;
    s/("(?:nonce|_wpnonce|rest_nonce|wp_rest_nonce)":\s*")[^"]*(")/${1}REDACTED-NONCE${2}/g;
    s/(X-WP-Nonce:\s*)\S+/${1}REDACTED-NONCE/gi;
    s/\$(?:P|wp)\$[.\/A-Za-z0-9\$]{20,}/REDACTED-PASSWORD-HASH/g;
  ' "$f"
done
if grep -rlF -f "$secrets" "$out" >/dev/null 2>&1; then
  echo "A secret is still in the fixtures." >&2
  exit 1
fi
echo "  files that held a secret: $hits; admin email in the files: $placeholder_email"

echo
"$here/counts.sh"
