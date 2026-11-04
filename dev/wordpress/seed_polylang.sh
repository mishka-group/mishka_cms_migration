#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# Adds Polylang (the free plugin) to the test WordPress, on top of seed.sh, with two languages, English (the
# default) and Persian, and a few entries and terms in them: a category and a tag in both languages, a post
# in both, a post in English alone and one in Persian alone, and a page with a page under it in both. Each
# translation is linked to its original through Polylang's own API (`pll_save_post_translations`,
# `pll_save_term_translations`). WP-CLI only. It gives no language to anything seed.sh made, adds no default
# category for a language, and never touches the passwords or .env.local, so it runs on a site someone is
# already testing against. Safe to run again: a language is found by its code, an entry or a term by its
# slug, and a second run changes nothing.
set -euo pipefail

if [ -z "${IN_WP_CLI:-}" ]; then
  cd "$(dirname "$0")"
  docker compose up -d --wait
  exec docker compose run --rm -T -e IN_WP_CLI=1 wp-cli bash /seed/seed_polylang.sh "$@"
fi

say() { printf '\n==> %s\n' "$*"; }
wpu() { wp --user=admin "$@"; }

say "Polylang"
wpu plugin is-installed polylang || wpu plugin install polylang
wpu plugin is-active polylang || wpu plugin activate polylang
wpu eval 'echo "Polylang " . POLYLANG_VERSION . "\n";'

say "Languages, terms, posts and pages"
cat > /tmp/seed-polylang.php <<'PHP'
<?php
$languages = PLL()->model->languages;
foreach ( array(
	array( 'name' => 'English', 'slug' => 'en', 'locale' => 'en_US', 'rtl' => false, 'term_group' => 0, 'flag' => 'us' ),
	array( 'name' => 'فارسی', 'slug' => 'fa', 'locale' => 'fa_IR', 'rtl' => true, 'term_group' => 1, 'flag' => 'ir' ),
) as $language ) {
	if ( ! $languages->get( $language['slug'] ) ) {
		$added = $languages->add( $language + array( 'no_default_cat' => true ) );
		if ( is_wp_error( $added ) ) {
			WP_CLI::error( $language['slug'] . ': ' . $added->get_error_message() );
		}
	}
	echo "  language {$language['slug']}\n";
}

function mishka_term( $taxonomy, $name, $slug, $description, $lang ) {
	$found = get_term_by( 'slug', $slug, $taxonomy );
	$id    = $found ? $found->term_id : wp_insert_term( $name, $taxonomy, array( 'slug' => $slug, 'description' => $description ) )['term_id'];
	pll_set_term_language( $id, $lang );
	echo "  $taxonomy $lang " . urldecode( $slug ) . " (#$id)\n";
	return $id;
}

function mishka_entry( $entry, $lang ) {
	$found = get_posts( array( 'post_type' => $entry['type'], 'name' => $entry['slug'], 'post_status' => 'any', 'numberposts' => 1 ) );
	$id    = $found ? $found[0]->ID : wp_insert_post( array(
		'post_type'     => $entry['type'],
		'post_name'     => $entry['slug'],
		'post_title'    => $entry['title'],
		'post_content'  => $entry['content'],
		'post_excerpt'  => $entry['excerpt'] ?? '',
		'post_status'   => 'publish',
		'post_date'     => $entry['date'],
		'post_parent'   => $entry['parent'] ?? 0,
		'post_author'   => 1,
		'post_category' => $entry['categories'] ?? array(),
		'tags_input'    => $entry['tags'] ?? array(),
	), true );
	if ( is_wp_error( $id ) ) {
		WP_CLI::error( $entry['slug'] . ': ' . $id->get_error_message() );
	}
	pll_set_post_language( $id, $lang );
	echo "  {$entry['type']} $lang " . urldecode( $entry['slug'] ) . " (#$id)\n";
	return $id;
}

$travel    = mishka_term( 'category', 'Travel', 'travel', 'Trips, routes and the places on the way.', 'en' );
$travel_fa = mishka_term( 'category', 'سفر', 'سفر', 'سفرها، مسیرها و جاهای سر راه.', 'fa' );
pll_save_term_translations( array( 'en' => $travel, 'fa' => $travel_fa ) );

$coffee    = mishka_term( 'post_tag', 'Coffee', 'coffee', '', 'en' );
$coffee_fa = mishka_term( 'post_tag', 'قهوه', 'قهوه', '', 'fa' );
pll_save_term_translations( array( 'en' => $coffee, 'fa' => $coffee_fa ) );

$weekend = mishka_entry( array(
	'type'       => 'post',
	'slug'       => 'a-weekend-in-isfahan',
	'title'      => 'A Weekend in Isfahan',
	'date'       => '2026-03-01 09:00:00',
	'categories' => array( $travel ),
	'tags'       => array( $coffee ),
	'excerpt'    => 'Two days of bridges, tiles and slow coffee.',
	'content'    => "<!-- wp:paragraph -->\n<p>Two days are enough to walk the old bridges at sunset and drink coffee in the bazaar.</p>\n<!-- /wp:paragraph -->",
), 'en' );
$weekend_fa = mishka_entry( array(
	'type'       => 'post',
	'slug'       => 'آخر-هفته-در-اصفهان',
	'title'      => 'آخر هفته‌ای در اصفهان',
	'date'       => '2026-03-02 09:00:00',
	'categories' => array( $travel_fa ),
	'tags'       => array( $coffee_fa ),
	'excerpt'    => 'دو روز پل، کاشی و قهوهٔ آرام.',
	'content'    => "<!-- wp:paragraph -->\n<p>دو روز کافی است تا هنگام غروب روی پل‌های قدیمی قدم بزنید و در بازار قهوه بنوشید.</p>\n<!-- /wp:paragraph -->",
), 'fa' );
pll_save_post_translations( array( 'en' => $weekend, 'fa' => $weekend_fa ) );

mishka_entry( array(
	'type'       => 'post',
	'slug'       => 'packing-light',
	'title'      => 'Packing Light',
	'date'       => '2026-03-03 09:00:00',
	'categories' => array( $travel ),
	'content'    => "<!-- wp:paragraph -->\n<p>One bag, three shirts and a notebook.</p>\n<!-- /wp:paragraph -->",
), 'en' );
mishka_entry( array(
	'type'       => 'post',
	'slug'       => 'یادداشت-سفر',
	'title'      => 'یادداشت سفر',
	'date'       => '2026-03-04 09:00:00',
	'categories' => array( $travel_fa ),
	'content'    => "<!-- wp:paragraph -->\n<p>این یادداشت فقط به فارسی نوشته شده است.</p>\n<!-- /wp:paragraph -->",
), 'fa' );

$story = mishka_entry( array(
	'type'    => 'page',
	'slug'    => 'our-story',
	'title'   => 'Our Story',
	'date'    => '2026-03-05 09:00:00',
	'content' => "<!-- wp:paragraph -->\n<p>We started as two friends with one camera.</p>\n<!-- /wp:paragraph -->",
), 'en' );
$story_fa = mishka_entry( array(
	'type'    => 'page',
	'slug'    => 'داستان-ما',
	'title'   => 'داستان ما',
	'date'    => '2026-03-06 09:00:00',
	'content' => "<!-- wp:paragraph -->\n<p>ما با دو دوست و یک دوربین شروع کردیم.</p>\n<!-- /wp:paragraph -->",
), 'fa' );
pll_save_post_translations( array( 'en' => $story, 'fa' => $story_fa ) );

$crew = mishka_entry( array(
	'type'    => 'page',
	'slug'    => 'our-crew',
	'title'   => 'Our Crew',
	'date'    => '2026-03-07 09:00:00',
	'parent'  => $story,
	'content' => "<!-- wp:paragraph -->\n<p>The people behind every trip.</p>\n<!-- /wp:paragraph -->",
), 'en' );
$crew_fa = mishka_entry( array(
	'type'    => 'page',
	'slug'    => 'همسفران-ما',
	'title'   => 'همسفران ما',
	'date'    => '2026-03-08 09:00:00',
	'parent'  => $story_fa,
	'content' => "<!-- wp:paragraph -->\n<p>آدم‌هایی که پشت هر سفر هستند.</p>\n<!-- /wp:paragraph -->",
), 'fa' );
pll_save_post_translations( array( 'en' => $crew, 'fa' => $crew_fa ) );
PHP
wpu eval-file /tmp/seed-polylang.php

say "Seeded"
wpu eval 'foreach ( pll_languages_list() as $lang ) { echo "  $lang: " . pll_count_posts( $lang, array( "post_type" => array( "post", "page" ) ) ) . " entries\n"; }'
