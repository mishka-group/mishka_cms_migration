#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# Fills the test WordPress with a long-running company blog, on top of seed.sh: 8 more users, 25 categories,
# about 80 tags, 40 pages in a hierarchy, 350 posts in every status (block and classic bodies, featured
# images, excerpts, internal links, a few password-protected and sticky), about 600 comments with replies,
# and an extra menu. WP-CLI only: no REST calls and no SQL. Run it after seed.sh.
#
# Safe to run again: pages and posts are looked up by slug, users by login, terms by slug or name, and every
# comment carries the comment agent `mishka-bulk-seed`, so a second run creates nothing. The plan (bulk/plan-*.sh)
# uses a fixed random seed, so the same site is planned on every run. Fixtures are never recorded from this data.
set -euo pipefail

if [ -z "${IN_WP_CLI:-}" ]; then
  cd "$(dirname "$0")"
  docker compose up -d --wait
  exec docker compose run --rm -T -e IN_WP_CLI=1 wp-cli bash /seed/seed_bulk.sh "$@"
fi

shopt -u patsub_replacement 2>/dev/null || true
SITE_URL=http://localhost:8089
BULK=/seed/bulk
COMMENT_AGENT=mishka-bulk-seed
export SITE_URL BULK

say() { printf '\n==> %s\n' "$*"; }
wpu() { wp --user=admin "$@"; }

declare -A EXIST=() CATID=() UID_OF=() TAGHAS=() MID=() MURL=() NEW=() OLD=() CM_EXIST=()
declare -a P_ID=() CMID=()

# Media from seed.sh: keys and URLs. The plan needs them to write image blocks.
read_media() {
  local id key guid k
  while IFS=, read -r id key guid; do
    MID[$key]=$id; MURL[$key]=$guid
  done < <(wpu post list --post_type=attachment --post_status=inherit --posts_per_page=-1 --fields=ID,post_name,guid --format=csv | tail -n +2)
  for k in hero cover gallery-1 gallery-2 gallery-3 og-image diagram photo animated; do
    if [ -z "${MID[$k]:-}" ]; then echo "The media item $k is missing: run ./seed.sh first." >&2; exit 1; fi
  done
}

# What already exists, by slug, login, name and marker.
read_state() {
  local id x pid agent
  while IFS=, read -r id x; do UID_OF[$x]=$id; done < <(wpu user list --fields=ID,user_login --format=csv | tail -n +2)
  while IFS=, read -r id x; do CATID[$x]=$id; done < <(wpu term list category --fields=term_id,slug --format=csv | tail -n +2)
  # WP-CLI quotes CSV fields that hold a space ("Background jobs"), so the quotes go before the lookup.
  while IFS=, read -r id x; do x=${x#\"}; x=${x%\"}; TAGHAS[$x]=$id; done < <(wpu term list post_tag --fields=term_id,name --format=csv | tail -n +2)
  while IFS=, read -r id x; do EXIST[post|$x]=$id; done < <(wpu post list --post_type=post --post_status=any --posts_per_page=-1 --fields=ID,post_name --format=csv | tail -n +2)
  while IFS=, read -r id x; do EXIST[page|$x]=$id; done < <(wpu post list --post_type=page --post_status=any --posts_per_page=-1 --fields=ID,post_name --format=csv | tail -n +2)
  # Bulk comments keyed by post, date and the md5 of the text: the same key a planned comment has. Spam
  # and held comments are included (status=all leaves spam out), trash is not.
  local cdate hash key_id
  while IFS=$'\t' read -r pid cdate hash key_id; do
    CM_EXIST["$pid|$cdate|$hash"]+="$key_id "
  done < <(wpu eval 'foreach (array("approve", "hold", "spam") as $s) { foreach (get_comments(array("status" => $s, "number" => 0)) as $c) { if ($c->comment_agent === "mishka-bulk-seed") { echo $c->comment_post_ID, "\t", $c->comment_date, "\t", md5($c->comment_content), "\t", $c->comment_ID, "\n"; } } }')
}

make_users() {
  say "Users"
  local login name pw
  for login in "${USER_ORDER[@]}"; do
    if [ -n "${UID_OF[$login]:-}" ]; then OLD[users]=$(( ${OLD[users]:-0} + 1 )); continue; fi
    name=${U_NAME[$login]}
    pw=$(head -c 400 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)
    UID_OF[$login]=$(wpu user create "$login" "${U_EMAIL[$login]}" --role="${U_ROLE[$login]}" \
      --display_name="$name" --first_name="${name%% *}" --last_name="${name#* }" \
      --user_url="https://$login.example.test" --description="${U_BIO[$login]}" --user_pass="$pw" --porcelain)
    NEW[users]=$(( ${NEW[users]:-0} + 1 ))
    echo "  user $login (${U_ROLE[$login]})"
  done
}

make_categories() {
  say "Categories"
  local row slug name parent desc id
  for row in "${CAT_ROWS[@]}"; do
    IFS='|' read -r slug name parent desc <<< "$row"
    if [ -n "${CATID[$slug]:-}" ]; then OLD[categories]=$(( ${OLD[categories]:-0} + 1 )); continue; fi
    local -a args=(term create category "$name" --slug="$slug" --description="$desc" --porcelain)
    if [ -n "$parent" ]; then args+=(--parent="${CATID[$parent]}"); fi
    id=$(wpu "${args[@]}")
    CATID[$slug]=$id
    NEW[categories]=$(( ${NEW[categories]:-0} + 1 ))
  done
}

make_tags() {
  say "Tags"
  local name
  for name in "${TAG_ALL[@]}"; do
    if [ -n "${TAGHAS[$name]:-}" ]; then OLD[tags]=$(( ${OLD[tags]:-0} + 1 )); continue; fi
    wpu term create post_tag "$name" --porcelain >/dev/null
    TAGHAS[$name]=1
    NEW[tags]=$(( ${NEW[tags]:-0} + 1 ))
  done
}

make_pages() {
  say "Pages"
  local i slug id
  local -a args
  for ((i = 0; i < ${#PG_SLUG[@]}; i++)); do
    slug=${PG_SLUG[i]}
    if [ -n "${EXIST[page|$slug]:-}" ]; then OLD[pages]=$(( ${OLD[pages]:-0} + 1 )); continue; fi
    args=(post create "${PG_FILE[i]}" --post_type=page --post_title="${PG_TITLE[i]}" --post_name="$slug"
      --post_status="${PG_STATUS[i]}" --post_author="${UID_OF[${PG_AUTHOR[i]}]}" --post_date="${PG_DATE[i]}" --porcelain)
    if [ -n "${PG_PARENT[i]}" ]; then args+=(--post_parent="${EXIST[page|${PG_PARENT[i]}]}"); fi
    id=$(wpu "${args[@]}")
    EXIST[page|$slug]=$id
    NEW[pages]=$(( ${NEW[pages]:-0} + 1 ))
  done
}

make_posts() {
  say "Posts"
  local i slug id catids c tid json joined
  local -a parts args
  for ((i = 0; i < NPOSTS; i++)); do
    slug=${P_SLUG[i]}
    if [ -n "${EXIST[post|$slug]:-}" ]; then
      P_ID[i]=${EXIST[post|$slug]}
      OLD[posts]=$(( ${OLD[posts]:-0} + 1 ))
      continue
    fi
    catids=""
    for c in ${P_CATS[i]}; do catids+="${CATID[$c]},"; done
    parts=()
    if [ -n "${P_THUMB[i]}" ]; then tid=${MID[${P_THUMB[i]}]}; parts+=("\"_thumbnail_id\":$tid"); fi
    if [ -n "${P_YOAST[i]}" ]; then parts+=("${P_YOAST[i]}"); fi
    json=""
    if (( ${#parts[@]} > 0 )); then joined=$(IFS=,; echo "${parts[*]}"); json="{$joined}"; fi
    args=(post create "${P_FILE[i]}" --post_type=post --post_title="${P_TITLE[i]}" --post_name="$slug"
      --post_status="${P_STATUS[i]}" --post_author="${UID_OF[${P_AUTHOR[i]}]}" --post_date="${P_DATE[i]}"
      --comment_status=open --ping_status=closed --post_category="${catids%,}" --tags_input="${P_TAGS[i]}" --porcelain)
    if [ -n "${P_EXCERPT[i]:-}" ]; then args+=(--post_excerpt="${P_EXCERPT[i]}"); fi
    if [ -n "${P_PASS[i]:-}" ]; then args+=(--post_password="${P_PASS[i]}"); fi
    if [ -n "$json" ]; then args+=(--meta_input="$json"); fi
    id=$(wpu "${args[@]}")
    P_ID[i]=$id
    EXIST[post|$slug]=$id
    NEW[posts]=$(( ${NEW[posts]:-0} + 1 ))
    if [ -n "${P_FORMAT[i]}" ]; then wpu post term set "$id" post_format "post-format-${P_FORMAT[i]}" >/dev/null; fi
  done
}

make_stickies() {
  local i ids=""
  for ((i = 0; i < NPOSTS; i++)); do
    if [ "${P_STICKY[i]}" = 1 ] && [ "${P_STATUS[i]}" = publish ]; then ids+="${P_ID[i]},"; fi
  done
  if [ -n "$ids" ]; then wpu eval "foreach (array(${ids%,}) as \$id) { stick_post(\$id); }"; fi
}

make_comments() {
  say "Comments"
  local k i pid parent id ip hash key n m
  local -a ex args
  declare -A seen=()
  for ((k = 0; k < NCM; k++)); do
    i=${CM_POST[k]}; pid=${P_ID[i]}
    hash=$(printf '%s' "${CM_TEXT[k]}" | md5sum); hash=${hash%% *}
    key="$pid|${CM_DATE[k]}|$hash"
    n=${seen[$key]:-0}; seen[$key]=$(( n + 1 ))
    ex=()
    if [ -n "${CM_EXIST[$key]:-}" ]; then mapfile -t ex < <(printf '%s\n' ${CM_EXIST[$key]} | sort -n); fi
    if (( n < ${#ex[@]} )); then
      CMID[k]=${ex[n]}
      OLD[comments]=$(( ${OLD[comments]:-0} + 1 ))
      continue
    fi
    parent=0
    if (( CM_PARENT[k] >= 0 )); then parent=${CMID[${CM_PARENT[k]}]}; fi
    ip="198.51.100.$(( k % 250 + 1 ))"
    args=(comment create --comment_post_ID="$pid" --comment_parent="$parent" --comment_approved="${CM_STATUS[k]}"
      --comment_date="${CM_DATE[k]}" --comment_content="${CM_TEXT[k]}" --comment_author="${CM_NAME[k]}"
      --comment_author_email="${CM_EMAIL[k]}" --comment_author_IP="$ip" --comment_agent="$COMMENT_AGENT" --porcelain)
    if [ -n "${CM_LOGIN[k]}" ]; then args+=(--user_id="${UID_OF[${CM_LOGIN[k]}]}"); fi
    id=$(wpu "${args[@]}")
    CMID[k]=$id
    NEW[comments]=$(( ${NEW[comments]:-0} + 1 ))
  done
  # Bulk comments that no planned comment claims (a repeat from an earlier run) go to the trash, which is
  # reversible. Trash is not read back, so the next run sees them as gone.
  for key in "${!CM_EXIST[@]}"; do
    mapfile -t ex < <(printf '%s\n' ${CM_EXIST[$key]} | sort -n)
    for ((m = ${seen[$key]:-0}; m < ${#ex[@]}; m++)); do
      wpu comment delete "${ex[m]}" >/dev/null
      NEW[trashed]=$(( ${NEW[trashed]:-0} + 1 ))
    done
  done
}

make_menu() {
  say "Menu"
  local M="Explore topics" names top
  names=$(wpu menu list --fields=name --format=csv | tail -n +2 | tr -d '"')
  case $'\n'"$names"$'\n' in
    *$'\n'"$M"$'\n'*) OLD[menus]=1; return 0 ;;
  esac
  wpu menu create "$M" >/dev/null
  top=$(wpu menu item add-term "$M" category "${CATID[business]}" --porcelain)
  wpu menu item add-term "$M" category "${CATID[remote-work]}" --parent-id="$top" >/dev/null
  wpu menu item add-term "$M" category "${CATID[pricing]}" --parent-id="$top" >/dev/null
  top=$(wpu menu item add-term "$M" category "${CATID[design]}" --porcelain)
  wpu menu item add-term "$M" category "${CATID[ui-design]}" --parent-id="$top" >/dev/null
  top=$(wpu menu item add-term "$M" category "${CATID[travel]}" --porcelain)
  wpu menu item add-term "$M" category "${CATID[travel-iran]}" --parent-id="$top" >/dev/null
  wpu menu item add-term "$M" category "${CATID[travel-turkey]}" --parent-id="$top" >/dev/null
  top=$(wpu menu item add-term "$M" category "${CATID[food]}" --porcelain)
  wpu menu item add-term "$M" category "${CATID[persian-cooking]}" --parent-id="$top" >/dev/null
  top=$(wpu menu item add-post "$M" "${EXIST[page|services]}" --porcelain)
  wpu menu item add-post "$M" "${EXIST[page|web-development]}" --parent-id="$top" >/dev/null
  wpu menu item add-post "$M" "${EXIST[page|wordpress-migration]}" --parent-id="$top" >/dev/null
  top=$(wpu menu item add-post "$M" "${EXIST[page|case-studies]}" --porcelain)
  wpu menu item add-post "$M" "${EXIST[page|bakery-online-orders]}" --parent-id="$top" >/dev/null
  wpu menu item add-post "$M" "${EXIST[page|news-site-migration]}" --parent-id="$top" >/dev/null
  top=$(wpu menu item add-post "$M" "${EXIST[page|locations]}" --porcelain)
  wpu menu item add-post "$M" "${EXIST[page|istanbul-office]}" --parent-id="$top" >/dev/null
  wpu menu item add-post "$M" "${EXIST[post|$ELIXIR_SLUG]}" >/dev/null
  NEW[menus]=1
}

summary() {
  say "Done"
  local k
  for k in users categories tags pages posts comments menus; do
    printf '  %-11s created %-5s existed %s\n' "$k" "${NEW[$k]:-0}" "${OLD[$k]:-0}"
  done
  printf '  %-11s %s\n' "repeats moved to trash" "${NEW[trashed]:-0}"
  if [ -n "${NEW[posts]:-}" ] || [ -n "${NEW[pages]:-}" ]; then
    wpu yoast index --skip-confirmation --interval=0 >/dev/null 2>&1 || true
  fi
}

read_media
source "$BULK/plan-core.sh"
source "$BULK/plan-bodies.sh"
source "$BULK/plan-items.sh"
plan_all
say "Plan: ${#P_TITLE[@]} posts, ${#PG_SLUG[@]} pages, $NCM comments, ${#TAG_ALL[@]} tags, ${#CAT_ROWS[@]} categories, ${#USER_ORDER[@]} users"
read_state
make_users
make_categories
make_tags
make_pages
make_posts
make_stickies
make_comments
make_menu
summary
