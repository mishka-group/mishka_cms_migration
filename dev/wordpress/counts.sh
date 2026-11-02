#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# Prints how many things of each type the recorded REST responses and the recorded WXR export hold, side by
# side, from the fixtures alone (no Docker). The two sources should agree except where WordPress itself differs:
# WXR carries trashed items, the menu items and the reusable blocks as <item>s, and leaves spam comments out.
set -euo pipefail

fx=$(cd "$(dirname "$0")/../.." && pwd)/test/fixtures/wordpress
wxr=$fx/wxr/all-content.xml

rest_total() { grep -i '^X-WP-Total:' "$fx/rest/$1.headers.txt" | tr -d '\r' | awk '{ print $2 }'; }
rest_count() { jq 'length' "$fx/rest/$1.json"; }
items() { # post_type [status]
  xmllint --xpath "count(//item[*[local-name()='post_type' and text()='$1']${2:+ and *[local-name()='status' and text()='$2']}])" "$wxr"
}
count() { xmllint --xpath "count($1)" "$wxr"; }
row() { printf '  %-22s %6s %6s   %s\n' "$1" "$2" "$3" "${4:-}"; }

echo "Counts: REST (X-WP-Total) against WXR (<item> and term elements)"
row type REST WXR note
rest_posts=$(rest_total posts)
wxr_posts=0
for s in publish future draft pending private; do wxr_posts=$((wxr_posts + $(items post "$s"))); done
row "posts (not trash)" "$rest_posts" "$wxr_posts" "REST status=any"
row "posts in trash" "$(rest_total posts-trash)" "$(items post trash)" "REST status=trash"
for s in publish future draft pending private; do row "  post $s" "$(jq "[.[] | select(.status == \"$s\")] | length" "$fx/rest/posts.json")" "$(items post "$s")"; done
pages_rest=$(rest_total pages)
pages_wxr=0
for s in publish future draft pending private; do pages_wxr=$((pages_wxr + $(items page "$s"))); done
row "pages" "$pages_rest" "$pages_wxr"
row "media (attachments)" "$(rest_total media)" "$(items attachment)"
row "reusable blocks" "$(rest_total blocks)" "$(items wp_block)"
row "navigation (block)" "$(rest_total navigation)" "$(items wp_navigation)"
row "menu items" "$(rest_total menu-items)" "$(items nav_menu_item)"
menus_wxr=$(xmllint --xpath "//*[local-name()='term'][*[local-name()='term_taxonomy' and text()='nav_menu']]/*[local-name()='term_id']" "$wxr" | grep -o '<wp:term_id>[0-9]*' | sort -u | wc -l | tr -d ' ')
row "menus" "$(rest_total menus)" "$menus_wxr" "WXR lists each menu term twice"
row "categories" "$(rest_total categories)" "$(count "//*[local-name()='category' and *[local-name()='category_nicename']]")" "wp:category"
row "tags" "$(rest_total tags)" "$(count "//*[local-name()='tag' and *[local-name()='tag_slug']]")" "wp:tag"
row "authors/users" "$(rest_total users)" "$(count "//*[local-name()='author' and *[local-name()='author_login']]")" "WXR lists authors of exported items"
rest_comments=$(( $(rest_total comments) + $(rest_total comments-pingback) ))
wxr_comments=$(count "//*[local-name()='comment']")
row "comments (no spam)" "$rest_comments" "$wxr_comments" "REST: status=all, type comment + pingback"
row "  approved" "$(( $(jq '[.[] | select(.status == "approved")] | length' "$fx/rest/comments.json") + $(rest_total comments-pingback) ))" "$(count "//*[local-name()='comment'][*[local-name()='comment_approved' and text()='1']]")" "REST: comment + pingback"
row "  pending (hold)" "$(jq '[.[] | select(.status == "hold")] | length' "$fx/rest/comments.json")" "$(count "//*[local-name()='comment'][*[local-name()='comment_approved' and text()='0']]")"
row "  pingback" "$(rest_total comments-pingback)" "$(count "//*[local-name()='comment'][*[local-name()='comment_type' and text()='pingback']]")"
row "  spam" "$(rest_total comments-spam)" "$(count "//*[local-name()='comment'][*[local-name()='comment_approved' and text()='spam']]")" "WXR leaves spam out"
