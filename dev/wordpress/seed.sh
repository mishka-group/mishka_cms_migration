#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# Installs WordPress in the Docker site and fills it with realistic content, using WP-CLI only.
# Safe to run again: every step looks the thing up first (by slug, login or name) and only creates what
# is missing. It runs on the host and re-runs itself inside the wp-cli container; the content lives in
# seed/content/*/*.html (a small front matter block, then the post body) and media/ holds the uploads.
set -euo pipefail

if [ -z "${IN_WP_CLI:-}" ]; then
  cd "$(dirname "$0")"
  docker compose up -d --wait
  exec docker compose run --rm -T -e IN_WP_CLI=1 wp-cli bash /seed/seed.sh "$@"
fi

# `&` in a replacement string must stay a literal `&` (URLs have them).
shopt -u patsub_replacement 2>/dev/null || true

SITE_URL=${WP_SITE_URL:-http://localhost:8089}
SEED=/seed
ENV_FILE=$SEED/${WP_ENV_FILE:-.env.local}
APP_NAME="Mishka Migration"

say() { printf '\n==> %s\n' "$*"; }
wpu() { wp --user=admin "$@"; }
json() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }
first() { head -n 1; }

declare -A USERID CATID MID MURL MMED MPAGE PID PURL
USERID[admin]=1

# ---------------------------------------------------------------------------------------------------
say "WordPress core"

ADMIN_PASSWORD=""
APP_PASSWORD=""
if [ -f "$ENV_FILE" ]; then
  ADMIN_PASSWORD=$(sed -n 's/^WORDPRESS_ADMIN_PASSWORD=//p' "$ENV_FILE")
  APP_PASSWORD=$(sed -n 's/^WORDPRESS_APPLICATION_PASSWORD=//p' "$ENV_FILE")
fi
[ -n "$ADMIN_PASSWORD" ] || ADMIN_PASSWORD=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)

if ! wp core is-installed 2>/dev/null; then
  wp core install --url="$SITE_URL" --title="Mishka Test Blog" --admin_user=admin \
    --admin_password="$ADMIN_PASSWORD" --admin_email=admin@example.test --skip-email
fi
wpu user update admin --user_pass="$ADMIN_PASSWORD" --display_name="Site Admin" --first_name=Site \
  --last_name=Admin --user_url="$SITE_URL" >/dev/null

say "Site settings, permalinks, logo placeholders"
wpu option update blogname "Mishka Test Blog"
wpu option update blogdescription "A WordPress site filled with realistic content for testing the Mishka CMS migration"
wpu option update timezone_string "Asia/Tehran"
wpu option update date_format "F j, Y"
wpu option update time_format "g:i a"
wpu option update posts_per_page 10
wpu option update default_comment_status open
wpu option update thread_comments 1
wpu option update thread_comments_depth 5
wpu rewrite structure '/%year%/%monthnum%/%postname%/' --hard

say "Remove the sample content WordPress ships with"
for slug in hello-world; do
  id=$(wpu post list --post_type=post --name="$slug" --post_status=publish,draft,trash --field=ID | first || true)
  [ -z "$id" ] || wpu post delete "$id" --force
done
id=$(wpu post list --post_type=page --name=sample-page --post_status=publish,draft,trash --field=ID | first || true)
[ -z "$id" ] || wpu post delete "$id" --force
wpu plugin is-installed hello && wpu plugin delete hello || true

say "Yoast SEO"
wpu plugin is-installed wordpress-seo || wpu plugin install wordpress-seo
wpu plugin is-active wordpress-seo || wpu plugin activate wordpress-seo
wpu eval 'echo "Yoast SEO " . WPSEO_VERSION . "\n";'

# ---------------------------------------------------------------------------------------------------
say "Users"

ensure_user() { # login email role display first last url bio
  local login=$1 id
  id=$(wpu user get "$login" --field=ID 2>/dev/null || true)
  if [ -z "$id" ]; then
    id=$(wpu user create "$login" "$2" --role="$3" --display_name="$4" --first_name="$5" --last_name="$6" \
      --user_url="$7" --description="$8" --user_pass="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)" --porcelain)
  else
    wpu user update "$id" --display_name="$4" --first_name="$5" --last_name="$6" --user_url="$7" \
      --description="$8" >/dev/null
  fi
  USERID[$login]=$id
}

# shahryar@mishka.tools is the address of a user a Mishka CMS site already has, so the author mapping can match it.
ensure_user shahryar shahryar@mishka.tools editor "Shahryar Tavakkoli" Shahryar Tavakkoli https://mishka.tools \
  "Builds Mishka CMS and writes about Elixir, Phoenix LiveView and moving sites between CMSs."
ensure_user nadia nadia.karimi@example.test author "Nadia Karimi" Nadia Karimi https://nadia.example.test \
  "Technical writer. Covers WordPress internals, SEO and content migrations."
ensure_user omid omid.rahimi@example.test author "امید رحیمی" Omid Rahimi https://omid.example.test \
  "توسعه‌دهنده و نویسنده. درباره الیکسیر، فونیکس و عملکرد وب می‌نویسد."
ensure_user parisa parisa.salehi@example.test contributor "Parisa Salehi" Parisa Salehi "" \
  "Guest contributor. Her posts wait for an editor to publish them."

# ---------------------------------------------------------------------------------------------------
say "Media"

import_media() { # key file title alt caption description date
  local key=$1 id
  id=$(wpu post list --post_type=attachment --post_status=inherit --name="$key" --field=ID | first || true)
  if [ -z "$id" ]; then
    id=$(wpu media import "$SEED/media/$2" --title="$3" --alt="$4" --caption="$5" --desc="$6" --porcelain)
    wpu eval "wp_update_post(['ID'=>$id,'post_name'=>'$key','post_date'=>'$7','post_date_gmt'=>get_gmt_from_date('$7')]);"
  fi
  MID[$key]=$id
  MURL[$key]=$(wpu eval "echo wp_get_attachment_url($id);")
  MMED[$key]=$(wpu eval "echo wp_get_attachment_image_url($id, 'medium');")
  MPAGE[$key]=$(wpu eval "echo get_attachment_link($id);")
}

import_media hero hero.jpg "Hero image" "A blue gradient hero image with a white circle" \
  "The hero image of the welcome post" "A 1600 by 900 JPEG drawn by the seed." 2026-01-03
import_media cover cover.jpg "Cover image" "A purple to orange gradient used as a cover background" \
  "A wide cover image" "A 1920 by 600 JPEG used by the cover block." 2026-01-03
import_media gallery-1 gallery-1.jpg "Gallery one" "A green gradient with the text Gallery 1" \
  "First gallery picture" "Gallery picture one." 2026-01-04
import_media gallery-2 gallery-2.jpg "Gallery two" "A red and orange gradient with the text Gallery 2" \
  "Second gallery picture" "Gallery picture two." 2026-01-04
import_media gallery-3 gallery-3.jpg "Gallery three" "A blue and violet gradient with the text Gallery 3" \
  "Third gallery picture" "Gallery picture three." 2026-01-04
import_media og-image og-image.jpg "Open Graph image" "Dark violet banner with the text Open Graph" \
  "Share card image" "The image Yoast SEO uses for social cards." 2026-01-05
import_media diagram diagram.png "Migration diagram" "WordPress, Normalize and Mishka CMS boxes joined by arrows" \
  "How a WordPress site reaches Mishka CMS" "A transparent PNG diagram." 2026-01-05
import_media photo photo.webp "WebP photo" "A pink and peach gradient with the text WebP photo" \
  "A WebP image" "A 1200 by 800 WebP file." 2026-01-06
import_media animated animated.gif "Animated GIF" "Three frames of a colour-shifting gradient" \
  "An animated GIF" "A three-frame animated GIF." 2026-01-06
import_media guide guide.pdf "Migration guide (PDF)" "A one-page PDF titled Migration guide" \
  "A downloadable PDF" "A one-page PDF document." 2026-01-07
import_media sample sample.mp4 "Sample video" "Two seconds of a colour test pattern" \
  "A short MP4 video" "A two-second MP4 test pattern." 2026-01-07
import_media site-logo site-logo.png "Site logo" "Mishka Test logo" "" "The site logo." 2026-01-02
import_media site-icon site-icon.png "Site icon" "Blue square with the letter M" "" "The site icon." 2026-01-02
import_media avatar-shahryar avatar-shahryar.png "Avatar of Shahryar" "Portrait placeholder of Shahryar" "" "Author picture." 2026-01-02
import_media avatar-nadia avatar-nadia.png "Avatar of Nadia" "Portrait placeholder of Nadia" "" "Author picture." 2026-01-02
import_media avatar-omid avatar-omid.png "Avatar of Omid" "Portrait placeholder of Omid" "" "Author picture." 2026-01-02
import_media avatar-parisa avatar-parisa.png "Avatar of Parisa" "Portrait placeholder of Parisa" "" "Author picture." 2026-01-02

# WordPress refuses SVG uploads by default. Try it plainly (the refusal is part of what the importer must
# survive), then import it once with the type allowed, the way a site with an SVG plugin has it.
if [ -z "$(wpu post list --post_type=attachment --post_status=inherit --name=logo-svg --field=ID | first || true)" ]; then
  echo "Plain SVG import, WordPress says:"
  wpu media import "$SEED/media/logo.svg" --porcelain 2>&1 || true
  cat > /tmp/import-svg.php <<'PHP'
<?php
require_once ABSPATH . 'wp-admin/includes/file.php';
require_once ABSPATH . 'wp-admin/includes/media.php';
require_once ABSPATH . 'wp-admin/includes/image.php';
add_filter( 'upload_mimes', function ( $mimes ) { $mimes['svg'] = 'image/svg+xml'; return $mimes; } );
add_filter( 'wp_check_filetype_and_ext', function ( $data, $file, $name ) {
	return str_ends_with( $name, '.svg' ) ? array( 'ext' => 'svg', 'type' => 'image/svg+xml', 'proper_filename' => false ) : $data;
}, 10, 3 );
$tmp = wp_tempnam( 'logo.svg' );
copy( '/seed/media/logo.svg', $tmp );
$id = media_handle_sideload(
	array( 'name' => 'logo.svg', 'tmp_name' => $tmp ),
	0,
	'Mishka mark (SVG)',
	array( 'post_excerpt' => 'An SVG logo', 'post_content' => 'Imported with the SVG type allowed.' )
);
if ( is_wp_error( $id ) ) {
	WP_CLI::error( 'The SVG import failed: ' . $id->get_error_message() );
}
update_post_meta( $id, '_wp_attachment_image_alt', 'A white M on a blue rounded square' );
wp_update_post( array( 'ID' => $id, 'post_name' => 'logo-svg', 'post_date' => '2026-01-07 09:00:00', 'post_date_gmt' => get_gmt_from_date( '2026-01-07 09:00:00' ) ) );
echo "Imported the SVG as attachment $id\n";
PHP
  wpu eval-file /tmp/import-svg.php
fi
for key in logo-svg; do
  id=$(wpu post list --post_type=attachment --post_status=inherit --name="$key" --field=ID | first)
  MID[logo]=$id
  MURL[logo]=$(wpu eval "echo wp_get_attachment_url($id);")
  MMED[logo]=""
  MPAGE[logo]=$(wpu eval "echo get_attachment_link($id);")
done

wpu option update site_logo "${MID[site-logo]}"
wpu option update site_icon "${MID[site-icon]}"
wpu theme mod set custom_logo "${MID[site-logo]}"

# ---------------------------------------------------------------------------------------------------
say "Categories and tags"

ensure_cat() { # slug name parent_slug description
  local slug=$1 id
  id=$(wpu term get category "$slug" --by=slug --field=term_id 2>/dev/null || true)
  if [ -z "$id" ]; then
    if [ -n "${3:-}" ]; then
      id=$(wpu term create category "$2" --slug="$slug" --parent="${CATID[$3]}" --description="${4:-}" --porcelain)
    else
      id=$(wpu term create category "$2" --slug="$slug" --description="${4:-}" --porcelain)
    fi
  fi
  CATID[$slug]=$id
}
CATID[uncategorized]=$(wpu term get category uncategorized --by=slug --field=term_id)

ensure_cat news "News" "" "Project news."
ensure_cat releases "Releases" news "Release announcements and notes."
ensure_cat announcements "Announcements" news "General announcements."
ensure_cat tutorials "Tutorials" "" "Step by step guides."
ensure_cat elixir "Elixir" tutorials "Elixir and Phoenix guides."
ensure_cat wordpress "WordPress" tutorials "WordPress guides."
ensure_cat migration "Migration" wordpress "Moving a WordPress site elsewhere."
ensure_cat "آموزش" "آموزش‌ها" "" "راهنماهای گام به گام به زبان فارسی."

ensure_tag() { # name
  [ -n "$(wpu term list post_tag --name="$1" --field=term_id | first || true)" ] \
    || wpu term create post_tag "$1" --porcelain >/dev/null
}
for tag in Elixir Phoenix LiveView WordPress Migration SEO Performance "Release notes" Gutenberg Shortcodes "وردپرس"; do
  ensure_tag "$tag"
done

# ---------------------------------------------------------------------------------------------------
say "Content: pages, posts and the reusable block"

declare -A FM
BODY=""

parse_front() { # file -> FM[...] and BODY
  FM=()
  local line key val in=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in" -eq 0 ]; then in=1; continue; fi
    [ "$line" = "---" ] && break
    key=${line%%:*}
    val=${line#*:}
    FM[$key]=${val# }
  done < "$1"
  BODY=$(awk 'c >= 2 { print } /^---$/ { c++ }' "$1")
  if [ "${FM[generate]:-}" = long ]; then BODY=$(long_body); fi
}

# About 100 KB of block markup built from a word list, so the "very long post" is the same on every run.
long_body() {
  local words=(migration content editor block shortcode category media permalink redirect author comment
    revision template plugin theme database export import schema field query cache index route
    request response header token session cookie sitemap archive feed excerpt thumbnail gallery caption
    embed widget menu navigation sidebar footer taxonomy slug status draft publish schedule private)
  local n=${#words[@]} i j p
  for ((i = 1; i <= 170; i++)); do
    if (( (i - 1) % 10 == 0 )); then
      printf '<!-- wp:heading -->\n<h2 class="wp-block-heading">Part %d</h2>\n<!-- /wp:heading -->\n\n' $(( (i - 1) / 10 + 1 ))
    fi
    p=""
    for ((j = 0; j < 90; j++)); do p+="${words[$(( (i * 7 + j * 13 + j * j) % n ))]} "; done
    printf '<!-- wp:paragraph -->\n<p>Paragraph %d. %s</p>\n<!-- /wp:paragraph -->\n\n' "$i" "${p% }"
  done
}

render() { # replaces the {{...}} tokens a content file uses
  local s=$1 k
  [[ $s == *'{{'* ]] || { printf '%s' "$s"; return; }
  s=${s//'{{site}}'/$SITE_URL}
  for k in "${!MID[@]}"; do
    s=${s//"{{id:$k}}"/${MID[$k]}}
    s=${s//"{{url:$k}}"/${MURL[$k]}}
    s=${s//"{{medium:$k}}"/${MMED[$k]}}
    s=${s//"{{page:$k}}"/${MPAGE[$k]}}
  done
  for k in "${!PID[@]}"; do
    s=${s//"{{post:$k}}"/${PURL[$k]:-}}
    s=${s//"{{postid:$k}}"/${PID[$k]}}
  done
  for k in "${!CATID[@]}"; do
    s=${s//"{{catid:$k}}"/${CATID[$k]}}
  done
  printf '%s' "$s"
}

find_post() { # type slug (a trashed post is found by its renamed slug, <slug>__trashed)
  local id
  id=$(wpu post list --post_type="$1" --name="$2" --post_status=publish,future,draft,pending,private --field=ID | first || true)
  [ -n "$id" ] || id=$(wpu post list --post_type="$1" --name="${2}__trashed" --post_status=trash --field=ID | first || true)
  printf '%s' "$id"
}

# Pass 1 creates every post with its final status and date (so every permalink exists); pass 2 writes the
# bodies, which can link to each other and to the media.
FILES=$(ls "$SEED"/seed/content/*/*.html | sort)
STICKY=()
TRASH=()

create_item() { # uses FM
  local type=${FM[type]:-post} slug=${FM[slug]} id cats="" c args status=${FM[status]:-publish}
  # A trashed post is created published and moved to the trash afterwards, the way a real one gets there.
  [ "$status" != trash ] || status=publish
  FM[categories]=${FM[categories]:-}
  FM[categories]=${FM[categories]//,/ }
  id=$(find_post "$type" "$slug")
  if [ -z "$id" ]; then
    args=(--post_type="$type" --post_title="${FM[title]}" --post_name="$slug" --post_status="$status"
      --post_author="${USERID[${FM[author]:-admin}]}" --post_content="Seed placeholder" --porcelain)
    [ -z "${FM[date]:-}" ] || args+=(--post_date="${FM[date]}")
    [ -z "${FM[parent]:-}" ] || args+=(--post_parent="${PID[${FM[parent]}]}")
    [ -z "${FM[password]:-}" ] || args+=(--post_password="${FM[password]}")
    [ -z "${FM[excerpt]:-}" ] || args+=(--post_excerpt="${FM[excerpt]}")
    [ -z "${FM[comments]:-}" ] || args+=(--comment_status="${FM[comments]}")
    [ -z "${FM[pings]:-}" ] || args+=(--ping_status="${FM[pings]}")
    [ -z "${FM[menu_order]:-}" ] || args+=(--menu_order="${FM[menu_order]}")
    if [ "$type" = post ]; then
      for c in ${FM[categories]:-}; do cats+="${CATID[$c]},"; done
      [ -z "$cats" ] || args+=(--post_category="${cats%,}")
      [ -z "${FM[tags]:-}" ] || args+=(--tags_input="${FM[tags]}")
    fi
    id=$(wpu post create "${args[@]}")
  fi
  PID[$slug]=$id
  PURL[$slug]=$(wpu eval "echo get_permalink($id);")
}

for f in $FILES; do
  parse_front "$f"
  [ "${FM[type]:-post}" = wp_block ] && continue
  create_item
done

# The reusable block comes first in pass 2 because a post refers to it by id.
BLOCK_ID=""
for f in $FILES; do
  parse_front "$f"
  [ "${FM[type]:-post}" = wp_block ] || continue
  slug=${FM[slug]}
  id=$(find_post wp_block "$slug")
  if [ -z "$id" ]; then
    id=$(wpu post create --post_type=wp_block --post_title="${FM[title]}" --post_name="$slug" --post_status=publish \
      --post_content="Seed placeholder" --porcelain)
  fi
  render "$BODY" > /tmp/body.html
  wpu post update "$id" /tmp/body.html >/dev/null
  PID[$slug]=$id
done

meta=()
add_meta() { meta+=("\"$1\":\"$(json "$2")\""); }

for f in $FILES; do
  parse_front "$f"
  type=${FM[type]:-post}
  [ "$type" = wp_block ] && continue
  slug=${FM[slug]}
  id=${PID[$slug]}
  meta=()
  [ -z "${FM[thumb]:-}" ] || add_meta _thumbnail_id "${MID[${FM[thumb]}]}"
  [ -z "${FM[yoast_title]:-}" ] || add_meta _yoast_wpseo_title "${FM[yoast_title]}"
  [ -z "${FM[yoast_desc]:-}" ] || add_meta _yoast_wpseo_metadesc "${FM[yoast_desc]}"
  [ -z "${FM[yoast_focuskw]:-}" ] || add_meta _yoast_wpseo_focuskw "${FM[yoast_focuskw]}"
  [ -z "${FM[yoast_noindex]:-}" ] || add_meta _yoast_wpseo_meta-robots-noindex "${FM[yoast_noindex]}"
  [ -z "${FM[yoast_nofollow]:-}" ] || add_meta _yoast_wpseo_meta-robots-nofollow "${FM[yoast_nofollow]}"
  [ -z "${FM[yoast_canonical]:-}" ] || add_meta _yoast_wpseo_canonical "${FM[yoast_canonical]}"
  [ -z "${FM[yoast_og_title]:-}" ] || add_meta _yoast_wpseo_opengraph-title "${FM[yoast_og_title]}"
  [ -z "${FM[yoast_og_desc]:-}" ] || add_meta _yoast_wpseo_opengraph-description "${FM[yoast_og_desc]}"
  if [ -n "${FM[yoast_og_image]:-}" ]; then
    add_meta _yoast_wpseo_opengraph-image "${MURL[${FM[yoast_og_image]}]}"
    add_meta _yoast_wpseo_opengraph-image-id "${MID[${FM[yoast_og_image]}]}"
  fi
  [ -z "${FM[yoast_tw_title]:-}" ] || add_meta _yoast_wpseo_twitter-title "${FM[yoast_tw_title]}"
  [ -z "${FM[yoast_tw_desc]:-}" ] || add_meta _yoast_wpseo_twitter-description "${FM[yoast_tw_desc]}"
  [ -z "${FM[yoast_primary_cat]:-}" ] || add_meta _yoast_wpseo_primary_category "${CATID[${FM[yoast_primary_cat]}]}"
  # Rank Math's fields as Rank Math stores them; its robots are a list, which WordPress serializes.
  [ -z "${FM[rank_math_title]:-}" ] || add_meta rank_math_title "${FM[rank_math_title]}"
  [ -z "${FM[rank_math_desc]:-}" ] || add_meta rank_math_description "${FM[rank_math_desc]}"
  [ -z "${FM[rank_math_focuskw]:-}" ] || add_meta rank_math_focus_keyword "${FM[rank_math_focuskw]}"
  [ -z "${FM[rank_math_canonical]:-}" ] || add_meta rank_math_canonical_url "${FM[rank_math_canonical]}"
  [ -z "${FM[rank_math_robots]:-}" ] || meta+=("\"rank_math_robots\":[\"${FM[rank_math_robots]//,/\",\"}\"]")
  if [ -n "${FM[rank_math_image]:-}" ]; then
    add_meta rank_math_facebook_image "${MURL[${FM[rank_math_image]}]}"
    add_meta rank_math_facebook_image_id "${MID[${FM[rank_math_image]}]}"
  fi
  for key in "${!FM[@]}"; do
    case $key in meta.*) add_meta "${key#meta.}" "${FM[$key]}" ;; esac
  done
  args=()
  if [ "${#meta[@]}" -gt 0 ]; then args+=(--meta_input="{$(IFS=,; echo "${meta[*]}")}"); fi
  # A draft or pending post has no GMT date, and WordPress would reset its date to now on update.
  [ -z "${FM[date]:-}" ] || args+=(--edit_date=1 --post_date="${FM[date]}")
  render "$BODY" > /tmp/body.html
  wpu post update "$id" /tmp/body.html --post_title="${FM[title]}" "${args[@]}" >/dev/null
  for key in $(echo "${FM[thumb]:-},${FM[attach]:-}" | tr ',' ' '); do
    wpu post update "${MID[$key]}" --post_parent="$id" >/dev/null
  done
  [ -z "${FM[format]:-}" ] || wpu post term set "$id" post_format "post-format-${FM[format]}" >/dev/null
  [ "${FM[sticky]:-}" != yes ] || STICKY+=("$id")
  [ "${FM[status]:-}" != trash ] || TRASH+=("$id")
  echo "  $type ${FM[status]:-publish} $slug (#$id)"
done

if [ "${#STICKY[@]}" -gt 0 ]; then
  wpu option update sticky_posts "[$(IFS=,; echo "${STICKY[*]}")]" --format=json
fi
for id in "${TRASH[@]}"; do
  [ "$(wpu post get "$id" --field=post_status)" = trash ] || wpu post delete "$id"
done

# A static front page and a posts page, the way most business sites are set up.
wpu option update show_on_front page
wpu option update page_on_front "${PID[home]}"
wpu option update page_for_posts "${PID[blog]}"

# ---------------------------------------------------------------------------------------------------
say "Comments"

declare -A CID
COMMENT_N=0
add_comment() { # key post_slug parent_key status date user author email content [extra wp comment create args]
  local key=$1 post=${PID[$2]} parent=0 args
  COMMENT_N=$((COMMENT_N + 1))
  [ -z "${3:-}" ] || parent=${CID[$3]}
  args=(--comment_post_ID="$post" --comment_parent="$parent" --comment_approved="$4" --comment_date="$5"
    --comment_content="$9" --comment_author_IP="203.0.113.$((10 + COMMENT_N))" --porcelain "${@:10}")
  if [ -n "$6" ]; then
    args+=(--user_id="${USERID[$6]}" --comment_author="$(wpu user get "$6" --field=display_name)"
      --comment_author_email="$(wpu user get "$6" --field=user_email)")
  else
    args+=(--comment_author="$7" --comment_author_email="$8")
  fi
  CID[$key]=$(wpu comment create "${args[@]}")
}

# The option marks a finished run, so a second run adds no comments.
if ! wpu option get mishka_seed_comments_done >/dev/null 2>&1; then
  add_comment c1 comment-heavy-post "" 1 "2026-04-11 09:12:00" "" "Reza Ahmadi" reza@example.test "Great write-up. Does the importer keep comment threads?"
  add_comment c2 comment-heavy-post c1 1 "2026-04-11 10:30:00" shahryar "" "" "Yes: replies keep their parent, so the thread comes across as it was."
  add_comment c3 comment-heavy-post c2 1 "2026-04-11 11:05:00" "" "Reza Ahmadi" reza@example.test "Perfect, thank you."
  add_comment c4 comment-heavy-post c3 1 "2026-04-11 11:40:00" nadia "" "" "Third-level reply, to check the depth limit of five."
  add_comment c5 comment-heavy-post "" 1 "2026-04-12 08:00:00" "" "Mina Farhadi" mina@example.test "<strong>Bold</strong> and a <a href=\"https://example.test/\">link</a> in a comment."
  add_comment c6 comment-heavy-post c5 1 "2026-04-12 09:20:00" omid "" "" "Reply from an author."
  add_comment c7 comment-heavy-post "" 1 "2026-04-13 14:00:00" "" "سارا محمدی" sara@example.test "ممنون از مطلب خوبتان."
  add_comment c8 comment-heavy-post "" 0 "2026-04-14 16:45:00" "" "Pending Person" pending@example.test "This comment is waiting in the moderation queue."
  add_comment c9 comment-heavy-post "" spam "2026-04-14 17:10:00" "" "Cheap Pills" spam@example.test "Buy cheap pills now: http://spam.example.test/"
  add_comment c10 comment-heavy-post "" 1 "2026-04-15 07:30:00" "" "Other Blog" pingback@example.test "A pingback from another blog." \
    --comment_type=pingback --comment_author_url=https://other-blog.example.test/linking-here
  add_comment c11 welcome-to-the-mishka-test-blog "" 1 "2026-01-06 12:00:00" "" "Kaveh Nouri" kaveh@example.test "Welcome! Looking forward to the migration series."
  add_comment c12 welcome-to-the-mishka-test-blog c11 1 "2026-01-06 13:15:00" shahryar "" "" "Thank you, Kaveh."
  add_comment c13 gutenberg-all-core-blocks "" 1 "2026-01-13 10:00:00" "" "Leila Hosseini" leila@example.test "Which of these blocks are hardest to convert?"
  add_comment c14 about "" 1 "2026-02-01 10:00:00" "" "Page Visitor" visitor@example.test "A comment on a page."
  add_comment c15 phoenix-liveview-tips "" 0 "2025-12-05 10:00:00" "" "Another Pending" pending2@example.test "Held for moderation."
  wpu option add mishka_seed_comments_done 1
fi

# ---------------------------------------------------------------------------------------------------
say "Menus and block navigation"

menu_exists() { wpu menu list --fields=name --format=csv | tail -n +2 | grep -qx "$1"; }

if ! menu_exists Primary; then
  wpu menu create Primary >/dev/null
  home=$(wpu menu item add-custom Primary "Home" "$SITE_URL/" --porcelain)
  about=$(wpu menu item add-post Primary "${PID[about]}" --porcelain)
  team=$(wpu menu item add-post Primary "${PID[team]}" --parent-id="$about" --porcelain)
  wpu menu item add-post Primary "${PID[leadership]}" --parent-id="$team" >/dev/null
  wpu menu item add-post Primary "${PID[contact]}" --parent-id="$about" >/dev/null
  blog=$(wpu menu item add-post Primary "${PID[blog]}" --porcelain)
  news=$(wpu menu item add-term Primary category "${CATID[news]}" --parent-id="$blog" --porcelain)
  wpu menu item add-term Primary category "${CATID[releases]}" --parent-id="$news" >/dev/null
  wpu menu item add-term Primary category "${CATID[announcements]}" --parent-id="$news" >/dev/null
  wpu menu item add-term Primary category "${CATID[tutorials]}" --parent-id="$blog" >/dev/null
  docs=$(wpu menu item add-post Primary "${PID[docs]}" --porcelain)
  wpu menu item add-post Primary "${PID[getting-started]}" --parent-id="$docs" >/dev/null
  wpu menu item add-post Primary "${PID[welcome-to-the-mishka-test-blog]}" --title="Start here" --classes="start-here" >/dev/null
  wpu menu item add-custom Primary "Elixir" "https://elixir-lang.org/" --target=_blank --description="The language behind Mishka CMS" --classes="external" >/dev/null
fi
if ! menu_exists Footer; then
  wpu menu create Footer >/dev/null
  wpu menu item add-post Footer "${PID[contact]}" >/dev/null
  wpu menu item add-post Footer "${PID[docs]}" >/dev/null
  wpu menu item add-custom Footer "RSS feed" "$SITE_URL/feed/" >/dev/null
fi
wpu menu location assign Primary primary >/dev/null 2>&1 || true

if [ -z "$(find_post wp_navigation main-navigation)" ]; then
  nav_item() { printf '<!-- wp:navigation-link {"label":"%s","type":"%s","id":%s,"url":"%s","kind":"post-type"} /-->\n' "$1" "$2" "$3" "$4"; }
  {
    printf '<!-- wp:navigation-link {"label":"Home","url":"%s/","kind":"custom"} /-->\n' "$SITE_URL"
    printf '<!-- wp:navigation-submenu {"label":"About","type":"page","id":%s,"url":"%s","kind":"post-type"} -->\n' "${PID[about]}" "${PURL[about]}"
    nav_item "Team" page "${PID[team]}" "${PURL[team]}"
    nav_item "Contact" page "${PID[contact]}" "${PURL[contact]}"
    printf '<!-- /wp:navigation-submenu -->\n'
    nav_item "Blog" page "${PID[blog]}" "${PURL[blog]}"
  } > /tmp/nav.html
  wpu post create /tmp/nav.html --post_type=wp_navigation --post_title="Main navigation" --post_name=main-navigation \
    --post_status=publish >/dev/null
fi

# ---------------------------------------------------------------------------------------------------
say "Yoast SEO indexables"
wpu yoast index --skip-confirmation --interval=0 || true

# ---------------------------------------------------------------------------------------------------
say "Application password"

app_password_works() {
  [ -n "$APP_PASSWORD" ] && curl -fsS -o /dev/null -u "admin:$APP_PASSWORD" "http://wordpress/wp-json/wp/v2/users/me?context=edit"
}
if ! app_password_works; then
  # Drop an older password of the same name, then make a new one.
  wpu user application-password list admin --fields=uuid,name --format=csv | tail -n +2 | grep ",$APP_NAME\$" \
    | cut -d, -f1 | while read -r uuid; do wpu user application-password delete admin "$uuid" >/dev/null; done || true
  APP_PASSWORD=$(wpu user application-password create admin "$APP_NAME" --porcelain | tr -d ' ')
fi

umask 077
cat > "$ENV_FILE" <<ENV
# Written by seed.sh. Local only, never committed (see .gitignore).
WORDPRESS_URL=$SITE_URL
WORDPRESS_USER=admin
WORDPRESS_APPLICATION_PASSWORD=$APP_PASSWORD
WORDPRESS_ADMIN_PASSWORD=$ADMIN_PASSWORD
ENV
curl -fsS -o /dev/null -u "admin:$APP_PASSWORD" "http://wordpress/wp-json/wp/v2/users/me?context=edit" \
  && echo "The application password works over HTTP (WP_ENVIRONMENT_TYPE=local)."

# ---------------------------------------------------------------------------------------------------
say "Seeded"
for type in post page attachment wp_block wp_navigation nav_menu_item; do
  printf '  %-14s' "$type"
  for status in publish future draft pending private trash inherit; do
    n=$(wpu post list --post_type="$type" --post_status="$status" --format=count 2>/dev/null || echo 0)
    [ "$n" = 0 ] || printf ' %s=%s' "$status" "$n"
  done
  printf '\n'
done
printf '  users=%s categories=%s tags=%s comments(all)=%s\n' \
  "$(wpu user list --format=count)" "$(wpu term list category --format=count)" "$(wpu term list post_tag --format=count)" \
  "$(wpu comment list --status=all --format=count)"
echo "Site: $SITE_URL   Admin: admin (password in dev/wordpress/${WP_ENV_FILE:-.env.local})"
