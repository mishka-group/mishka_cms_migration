#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# Adds Elementor (the free plugin) to the test WordPress, on top of seed.sh, and the pages and the post laid
# out with it: seed/elementor/*.json, each the entry's fields and its elements in the shape Elementor saves
# them. WP-CLI only. It changes nothing seed.sh made, and never the passwords or .env.local, so it runs on a
# site someone is already testing against.
#
# Each entry is saved through Elementor's own document API, which writes `_elementor_data`, its edit mode,
# version and template type, and the HTML fallback it keeps in `post_content`. Elementor drops a widget of a
# plugin the site does not run, such as Elementor Pro's form and slides, so those are written back where they
# were, the way a site keeps them once Pro is gone. Safe to run again: an entry is found by its slug.
set -euo pipefail

if [ -z "${IN_WP_CLI:-}" ]; then
  cd "$(dirname "$0")"
  docker compose up -d --wait
  exec docker compose run --rm -T -e IN_WP_CLI=1 wp-cli bash /seed/seed_elementor.sh "$@"
fi

say() { printf '\n==> %s\n' "$*"; }
wpu() { wp --user=admin "$@"; }

say "Elementor"
wpu plugin is-installed elementor || wpu plugin install elementor
wpu plugin is-active elementor || wpu plugin activate elementor
wpu eval 'echo "Elementor " . ELEMENTOR_VERSION . "\n";'

say "Elementor pages and post"
cat > /tmp/seed-elementor.php <<'PHP'
<?php
use Elementor\Plugin;

// `{{url:KEY}}`, `{{medium:KEY}}` and `"{{id:KEY}}"` name a file of the media library by its slug, and
// `{{link:SLUG}}` the address of a page or post.
$tokens = array();
foreach ( get_posts( array( 'post_type' => 'attachment', 'post_status' => 'inherit', 'numberposts' => -1 ) ) as $file ) {
	$tokens[ '{{url:' . $file->post_name . '}}' ]    = wp_get_attachment_url( $file->ID );
	$tokens[ '{{medium:' . $file->post_name . '}}' ] = wp_get_attachment_image_url( $file->ID, 'medium' );
	$tokens[ '"{{id:' . $file->post_name . '}}"' ]   = (string) $file->ID;
	$tokens[ '{{id:' . $file->post_name . '}}' ]     = (string) $file->ID;
}
$entries = get_posts( array( 'post_type' => array( 'page', 'post' ), 'post_status' => array( 'publish', 'future', 'draft', 'pending', 'private' ), 'numberposts' => -1 ) );
foreach ( $entries as $entry ) {
	$tokens[ '{{link:' . urldecode( $entry->post_name ) . '}}' ] = get_permalink( $entry );
}

// Elementor's saved elements, with each element it dropped put back where the seed has it.
function mishka_kept( $given, $saved ) {
	$by_id = array();
	foreach ( $saved as $element ) {
		$by_id[ $element['id'] ] = $element;
	}
	$kept = array();
	foreach ( $given as $element ) {
		if ( isset( $by_id[ $element['id'] ] ) ) {
			$element = array_merge( $by_id[ $element['id'] ], array( 'elements' => mishka_kept( $element['elements'], $by_id[ $element['id'] ]['elements'] ) ) );
		}
		$kept[] = $element;
	}
	return $kept;
}

foreach ( glob( '/seed/seed/elementor/*.json' ) as $path ) {
	$seed = json_decode( strtr( file_get_contents( $path ), $tokens ), true );
	$found = get_posts( array( 'post_type' => $seed['type'], 'name' => $seed['slug'], 'post_status' => 'any', 'numberposts' => 1 ) );
	$id = $found ? $found[0]->ID : wp_insert_post( array(
		'post_type'     => $seed['type'],
		'post_name'     => $seed['slug'],
		'post_title'    => $seed['title'],
		'post_status'   => $seed['status'],
		'post_date'     => $seed['date'],
		'post_author'   => get_user_by( 'login', $seed['author'] )->ID,
		'post_category' => isset( $seed['categories'] ) ? array( get_category_by_slug( $seed['categories'] )->term_id ) : array(),
	), true );
	if ( is_wp_error( $id ) ) {
		WP_CLI::error( $seed['slug'] . ': ' . $id->get_error_message() );
	}

	$document = Plugin::$instance->documents->get( $id, false );
	$document->set_is_built_with_elementor( true );
	$document->save( array( 'settings' => $seed['settings'], 'elements' => $seed['elements'] ) );

	$saved = Plugin::$instance->documents->get( $id, false )->get_elements_data();
	$kept  = mishka_kept( $seed['elements'], $saved );
	if ( $kept !== $saved ) {
		update_metadata( 'post', $id, '_elementor_data', wp_slash( wp_json_encode( $kept ) ) );
	}
	echo "  {$seed['type']} {$seed['status']} {$seed['slug']} (#{$id})\n";
}
PHP
wpu eval-file /tmp/seed-elementor.php

say "Seeded"
echo "Built with Elementor: $(wpu post list --post_type=page,post --meta_key=_elementor_edit_mode --meta_value=builder --format=count)"
