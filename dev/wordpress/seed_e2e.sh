#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# Adds the entries the browser e2e of the migration needs and seed.sh does not hold: a YouTube embed, a post
# with a script and an inline handler, three media files (two with the same bytes, one with the same name and
# other bytes), a page and a category whose address a fresh Mishka CMS site already has, two new users who
# each wrote a post, a header menu of published entries only, and guest comments with a reply. WP-CLI only.
# Entries are found by slug (media by their slug, users by login, the menu by name, a comment by author and
# text) and created only when missing, and an existing one is written only when something differs, so a second
# run changes nothing. It never touches the passwords or .env.local and runs on a site someone is testing.
# The entries carry the `e2e-` slug prefix (or the title prefix "E2E" where the address is the point) and the
# post meta `_e2e_seed`.
set -euo pipefail

if [ -z "${IN_WP_CLI:-}" ]; then
  cd "$(dirname "$0")"
  docker compose up -d --wait
  exec docker compose run --rm -T -e IN_WP_CLI=1 wp-cli bash /seed/seed_e2e.sh "$@"
fi

say() { printf '\n==> %s\n' "$*"; }
wpu() { wp --user=admin "$@"; }

say "Site title, tagline, logo and icon (checked, not changed)"
for option in blogname blogdescription site_logo site_icon; do
  value=$(wpu option get "$option")
  [ -n "$value" ] && [ "$value" != "0" ] || { echo "  $option is empty: run seed.sh first" >&2; exit 1; }
  echo "  $option = $value"
done

say "E2E entries"
cat > /tmp/seed-e2e.php <<'PHP'
<?php
require_once ABSPATH . 'wp-admin/includes/image.php';
wp_set_current_user( 1 );

// Creates the entry with this slug, or brings an existing one to these fields; writes only on a difference.
function e2e_entry( $type, $slug, $fields, $terms = array() ) {
	$found  = get_posts( array( 'post_type' => $type, 'name' => $slug, 'post_status' => 'any', 'numberposts' => 1 ) );
	$fields = $fields + array( 'post_status' => 'publish', 'post_author' => 1, 'post_excerpt' => '' );
	if ( $found ) {
		$id   = $found[0]->ID;
		$diff = array();
		foreach ( $fields as $key => $value ) {
			if ( (string) $found[0]->$key !== (string) $value ) {
				$diff[ $key ] = $value;
			}
		}
		if ( $diff ) {
			$updated = wp_update_post( array( 'ID' => $id ) + $diff, true );
			if ( is_wp_error( $updated ) ) {
				WP_CLI::error( "$slug: " . $updated->get_error_message() );
			}
		}
	} else {
		$id = wp_insert_post( $fields + array( 'post_type' => $type, 'post_name' => $slug ), true );
		if ( is_wp_error( $id ) ) {
			WP_CLI::error( "$slug: " . $id->get_error_message() );
		}
	}
	foreach ( $terms as $taxonomy => $ids ) {
		wp_set_object_terms( $id, $ids, $taxonomy );
	}
	update_post_meta( $id, '_e2e_seed', '1' );
	echo "  $type $slug (#$id)\n";
	return $id;
}

function e2e_block( $name, $html, $attrs = '' ) {
	return "<!-- wp:$name$attrs -->\n$html\n<!-- /wp:$name -->";
}
function e2e_p( $html ) {
	return e2e_block( 'paragraph', "<p>$html</p>" );
}

// Terms whose address a fresh Mishka CMS site already uses.
$blog = get_term_by( 'slug', 'blog', 'category' );
$blog = $blog ? $blog->term_id : wp_insert_term( 'E2E Blog', 'category', array( 'slug' => 'blog', 'description' => 'E2E: the slug of the Mishka blog front page.' ) )['term_id'];
echo "  category blog (#$blog)\n";

// 1. YouTube embed: an embed block and the [embed] shortcode.
$video = 'https://www.youtube.com/watch?v=aqz-KE-bpKQ';
e2e_entry( 'post', 'e2e-youtube-embed', array(
	'post_title'   => 'E2E YouTube embed',
	'post_date'    => '2026-04-01 09:00:00',
	'post_content' => e2e_p( 'A YouTube embed block, then the embed shortcode.' ) . "\n\n" .
		e2e_block( 'embed',
			'<figure class="wp-block-embed is-type-video is-provider-youtube wp-block-embed-youtube wp-embed-aspect-16-9 wp-has-aspect-ratio"><div class="wp-block-embed__wrapper">' . "\n$video\n" . '</div></figure>',
			' {"url":"' . $video . '","type":"video","providerNameSlug":"youtube","responsive":true,"className":"wp-embed-aspect-16-9 wp-has-aspect-ratio"}' ) . "\n\n" .
		e2e_block( 'shortcode', "[embed]{$video}[/embed]" ),
) );

// 2. A script in a Custom HTML block and an inline handler on a link.
e2e_entry( 'post', 'e2e-scripts-and-handlers', array(
	'post_title'   => 'E2E scripts and inline handlers',
	'post_date'    => '2026-04-02 09:00:00',
	'post_content' => e2e_block( 'html', '<script>window.e2eScript = true;</script><div id="e2e-html">Custom HTML block</div>' ) . "\n\n" .
		e2e_p( 'A link with a handler: <a href="https://example.test/" onclick="window.e2eClicked = true; return false;">click me</a>.' ),
), array( 'category' => array( $blog ) ) );

// 3. Media: A and B have the same bytes and different titles; C has the same file name and other bytes.
// Each lands in a different month folder so all three keep the file name e2e-duplicate.jpg.
function e2e_media( $slug, $title, $source, $month ) {
	$found = get_posts( array( 'post_type' => 'attachment', 'name' => $slug, 'post_status' => 'any', 'numberposts' => 1 ) );
	if ( $found ) {
		echo "  media $slug (#{$found[0]->ID})\n";
		return $found[0]->ID;
	}
	$dir = wp_upload_dir( $month );
	wp_mkdir_p( $dir['path'] );
	$file = $dir['path'] . '/e2e-duplicate.jpg';
	copy( $source, $file );
	$id = wp_insert_attachment( array(
		'post_title'     => $title,
		'post_name'      => $slug,
		'post_mime_type' => 'image/jpeg',
		'post_status'    => 'inherit',
		'post_date'      => str_replace( '/', '-', $month ) . '-05 09:00:00',
		'post_author'    => 1,
	), $file, 0, true );
	if ( is_wp_error( $id ) ) {
		WP_CLI::error( "$slug: " . $id->get_error_message() );
	}
	wp_update_attachment_metadata( $id, wp_generate_attachment_metadata( $id, $file ) );
	update_post_meta( $id, '_wp_attachment_image_alt', $title );
	update_post_meta( $id, '_e2e_seed', '1' );
	echo "  media $slug (#$id)\n";
	return $id;
}
$a = e2e_media( 'e2e-duplicate-a', 'E2E duplicate A', '/seed/media/hero.jpg', '2026/03' );
$b = e2e_media( 'e2e-duplicate-b', 'E2E duplicate B', '/seed/media/hero.jpg', '2026/04' );
$c = e2e_media( 'e2e-same-name-other-bytes', 'E2E same name, other bytes', '/seed/media/cover.jpg', '2026/05' );
$url = wp_get_attachment_url( $a );
e2e_entry( 'post', 'e2e-duplicate-media', array(
	'post_title'   => 'E2E duplicate media',
	'post_date'    => '2026-04-03 09:00:00',
	'post_content' => e2e_p( 'The first of two files with the same bytes.' ) . "\n\n" .
		e2e_block( 'image', '<figure class="wp-block-image size-full"><img src="' . esc_url( $url ) . '" alt="E2E duplicate A" class="wp-image-' . $a . '"/></figure>', ' {"id":' . $a . ',"sizeSlug":"full","linkDestination":"none"}' ),
) );

// 4. Slug and path conflicts: a fresh Mishka CMS site has /about, /contact and /privacy (pages.ex),
// /blog and its sub-pages. seed.sh already holds the pages about and contact; this adds /privacy.
e2e_entry( 'page', 'privacy', array(
	'post_title'   => 'E2E Privacy',
	'post_date'    => '2026-04-04 09:00:00',
	'post_content' => e2e_p( 'A page at /privacy, which a fresh Mishka CMS site has too.' ),
) );

// 6. New users, each the author of a post.
foreach ( array( 1, 2 ) as $n ) {
	$login = "e2e-author$n";
	$user  = get_user_by( 'login', $login );
	$uid   = $user ? $user->ID : wp_insert_user( array(
		'user_login'   => $login,
		'user_email'   => "$login@example.test",
		'user_pass'    => wp_generate_password( 24 ),
		'role'         => 'author',
		'display_name' => "E2E Author $n",
		'first_name'   => 'E2E',
		'last_name'    => "Author $n",
	) );
	if ( is_wp_error( $uid ) ) {
		WP_CLI::error( "$login: " . $uid->get_error_message() );
	}
	echo "  user $login (#$uid)\n";
	e2e_entry( 'post', "e2e-by-author-$n", array(
		'post_title'   => "E2E post by author $n",
		'post_date'    => "2026-04-0" . ( 4 + $n ) . ' 09:00:00',
		'post_author'  => $uid,
		'post_content' => e2e_p( "Written by E2E Author $n, a user no Mishka CMS site has." ),
	) );
}

// 8. Guest comments on a post, one with a website, and a guest reply.
$guest = e2e_entry( 'post', 'e2e-guest-comments', array(
	'post_title'     => 'E2E guest comments',
	'post_date'      => '2026-04-07 09:00:00',
	'comment_status' => 'open',
	'post_content'   => e2e_p( 'Guests commented on this post.' ),
) );
function e2e_comment( $post, $parent, $name, $email, $url, $text ) {
	$found = get_comments( array( 'post_id' => $post, 'author_email' => $email, 'search' => $text, 'status' => 'all', 'number' => 1 ) );
	if ( $found ) {
		echo "  comment $email (#{$found[0]->comment_ID})\n";
		return (int) $found[0]->comment_ID;
	}
	$id = wp_insert_comment( array(
		'comment_post_ID'      => $post,
		'comment_parent'       => $parent,
		'comment_author'       => $name,
		'comment_author_email' => $email,
		'comment_author_url'   => $url,
		'comment_content'      => $text,
		'comment_approved'     => 1,
		'comment_date'         => '2026-04-08 10:00:00',
		'user_id'              => 0,
	) );
	echo "  comment $email (#$id)\n";
	return $id;
}
$first = e2e_comment( $guest, 0, 'Guest One', 'e2e-guest1@example.test', 'https://example.test/guest-one', 'E2E guest comment with a website.' );
e2e_comment( $guest, 0, 'Guest Two', 'e2e-guest2@example.test', '', 'E2E guest comment without a website.' );
e2e_comment( $guest, $first, 'Guest Three', 'e2e-guest3@example.test', '', 'E2E guest reply to the first comment.' );

// 7. A classic header menu with no location, linking published pages and posts only.
$menu = wp_get_nav_menu_object( 'E2E Header' );
$menu = $menu ? $menu->term_id : wp_create_nav_menu( 'E2E Header' );
if ( is_wp_error( $menu ) ) {
	WP_CLI::error( $menu->get_error_message() );
}
$have = wp_list_pluck( wp_get_nav_menu_items( $menu, array( 'post_status' => 'any' ) ) ?: array(), 'object_id' );
$pos  = 1;
foreach ( array( array( 'page', 'about' ), array( 'page', 'contact' ), array( 'post', 'e2e-youtube-embed' ), array( 'post', 'e2e-duplicate-media' ) ) as $item ) {
	$target = get_posts( array( 'post_type' => $item[0], 'name' => $item[1], 'post_status' => 'publish', 'numberposts' => 1 ) );
	if ( ! $target ) {
		WP_CLI::error( "menu target {$item[1]} is not published" );
	}
	if ( ! in_array( (string) $target[0]->ID, array_map( 'strval', $have ), true ) ) {
		wp_update_nav_menu_item( $menu, 0, array(
			'menu-item-title'     => $target[0]->post_title,
			'menu-item-object'    => $item[0],
			'menu-item-object-id' => $target[0]->ID,
			'menu-item-type'      => 'post_type',
			'menu-item-status'    => 'publish',
			'menu-item-position'  => $pos,
		) );
	}
	$pos++;
}
echo "  menu E2E Header (#$menu)\n";
PHP
wpu eval-file /tmp/seed-e2e.php

say "Created by this script"
wpu post list --post_type=post,page --post_status=any --fields=ID,post_type,post_name,post_status | grep -E 'ID|e2e-|\sprivacy\s'
wpu post list --post_type=attachment --fields=ID,post_name,post_title,guid | grep -E 'ID|e2e-'
wpu menu item list "E2E Header" --fields=db_id,title,object,object_id
