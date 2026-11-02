#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# Block markup for the bulk content. Each emitter prints one block (the same markup seed.sh uses) to
# stdout. Bodies are written with `{ ...; } > file`, which runs in the current shell, so the random
# generator and LEAD (the lead paragraph, used as the excerpt) carry on across calls.

# A paragraph from the current topic and language, sometimes with a link to another published post.
block_para() {
  para_text
  local txt j
  txt=$(esc "$PARA")
  ri 100
  if (( RI < 25 )); then
    choose "$PUB"; j=$PICK
    local ra="Read also:"
    case $CUR_LANG in fa) ra="مطالعه بیشتر:" ;; ar) ra="اقرأ أيضاً:" ;; de) ra="Lesen Sie auch:" ;; esac
    txt+=" $ra <a href=\"${P_URL[j]}\">$(esc "${P_TITLE[j]}")</a>."
  fi
  printf '<!-- wp:paragraph -->\n<p>%s</p>\n<!-- /wp:paragraph -->\n\n' "$txt"
}

# The first paragraph of a post: plain, no link. Its text is the post's excerpt when it has one.
lead_block() {
  para_text
  LEAD=$PARA
  printf '<!-- wp:paragraph -->\n<p>%s</p>\n<!-- /wp:paragraph -->\n\n' "$(esc "$LEAD")"
}

block_heading() {
  frag h "$CUR_LANG"
  local t=$FRAG
  ri 3
  if (( RI == 0 )); then
    printf '<!-- wp:heading {"level":3} -->\n<h3 class="wp-block-heading">%s</h3>\n<!-- /wp:heading -->\n\n' "$(esc "$t")"
  else
    printf '<!-- wp:heading -->\n<h2 class="wp-block-heading">%s</h2>\n<!-- /wp:heading -->\n\n' "$(esc "$t")"
  fi
}

block_list() {
  local ordered n q
  ri 2; ordered=$RI
  ri 3; n=$(( RI + 3 ))
  if (( ordered )); then printf '<!-- wp:list {"ordered":true} -->\n<ol class="wp-block-list">'
  else printf '<!-- wp:list -->\n<ul class="wp-block-list">'; fi
  for ((q = 0; q < n; q++)); do
    frag_li
    if (( q > 0 )); then printf '\n\n'; fi
    printf '<!-- wp:list-item -->\n<li>%s</li>\n<!-- /wp:list-item -->' "$(esc "$FRAG")"
  done
  if (( ordered )); then printf '</ol>\n<!-- /wp:list -->\n\n'
  else printf '</ul>\n<!-- /wp:list -->\n\n'; fi
}

block_quote() {
  frag q "$CUR_LANG"
  local text=${FRAG%%|*} cite=${FRAG#*|}
  printf '<!-- wp:quote -->\n<blockquote class="wp-block-quote"><!-- wp:paragraph -->\n<p>%s</p>\n<!-- /wp:paragraph --><cite>%s</cite></blockquote>\n<!-- /wp:quote -->\n\n' "$(esc "$text")" "$(esc "$cite")"
}

# A single image from the media library (key from IMG_KEYS) with a caption.
block_image() {
  local k=$1 id=${MID[$1]} url=${MURL[$1]} cap
  frag cap "$CUR_LANG"
  cap=$(esc "$FRAG")
  printf '<!-- wp:image {"id":%s,"sizeSlug":"large","linkDestination":"none"} -->\n<figure class="wp-block-image size-large"><img src="%s" alt="%s" class="wp-image-%s"/><figcaption class="wp-element-caption">%s</figcaption></figure>\n<!-- /wp:image -->\n\n' "$id" "$url" "${MALT[$k]}" "$id" "$cap"
}

block_gallery() {
  local k
  printf '<!-- wp:gallery {"linkTo":"none"} -->\n<figure class="wp-block-gallery has-nested-images columns-default is-cropped">'
  for k in gallery-1 gallery-2 gallery-3; do
    printf '<!-- wp:image {"id":%s,"sizeSlug":"large","linkDestination":"none"} -->\n<figure class="wp-block-image size-large"><img src="%s" alt="%s" class="wp-image-%s"/></figure>\n<!-- /wp:image -->\n' "${MID[$k]}" "${MURL[$k]}" "${MALT[$k]}" "${MID[$k]}"
  done
  printf '</figure>\n<!-- /wp:gallery -->\n\n'
}

block_table() {
  local m v s
  printf '<!-- wp:table -->\n<figure class="wp-block-table"><table class="has-fixed-layout"><thead><tr><th>Month</th><th>Visits</th><th>Signups</th></tr></thead><tbody>'
  for m in January February March April; do
    ri 9000; v=$(( RI + 800 ))
    ri 400; s=$(( RI + 40 ))
    printf '<tr><td>%s</td><td>%d</td><td>%d</td></tr>' "$m" "$v" "$s"
  done
  frag cap "$CUR_LANG"
  printf '</tbody></table><figcaption class="wp-element-caption">%s</figcaption></figure>\n<!-- /wp:table -->\n\n' "$(esc "$FRAG")"
}

# A code block from the topic's snippets; a paragraph for topics without code.
block_code() {
  local keys code
  case $CUR_TOPIC in
    elixir) keys=elixir ;;
    wordpress) keys="php shell sql" ;;
    webdev) keys="js css nginx shell sql" ;;
    design) keys="css js" ;;
    *) block_para; return 0 ;;
  esac
  choose "$keys"
  frag code "$PICK"
  code=$(printf '%b' "$FRAG")
  printf '<!-- wp:code -->\n<pre class="wp-block-code"><code>%s</code></pre>\n<!-- /wp:code -->\n\n' "$(esc "$code")"
}

block_separator() {
  printf '<!-- wp:separator -->\n<hr class="wp-block-separator has-alpha-channel-opacity"/>\n<!-- /wp:separator -->\n\n'
}

# A button to the contact page or to a published post.
block_buttons() {
  local url label
  ri 2
  if (( RI == 0 )); then
    url="$SITE_URL/contact/"
    case $CUR_LANG in fa) label="تماس با ما" ;; ar) label="تواصل معنا" ;; de) label="Kontakt aufnehmen" ;; *) label="Contact us" ;; esac
  else
    choose "$PUB"; url=${P_URL[$PICK]}
    case $CUR_LANG in fa) label="خواندن مطلب" ;; ar) label="اقرأ المقال" ;; de) label="Zum Artikel" ;; *) label="Read the article" ;; esac
  fi
  printf '<!-- wp:buttons -->\n<div class="wp-block-buttons"><!-- wp:button -->\n<div class="wp-block-button"><a class="wp-block-button__link wp-element-button" href="%s">%s</a></div>\n<!-- /wp:button --></div>\n<!-- /wp:buttons -->\n\n' "$url" "$label"
}

block_columns() {
  local a b
  para_text; a=$(esc "$PARA")
  para_text; b=$(esc "$PARA")
  printf '<!-- wp:columns -->\n<div class="wp-block-columns"><!-- wp:column -->\n<div class="wp-block-column"><!-- wp:paragraph -->\n<p>%s</p>\n<!-- /wp:paragraph --></div>\n<!-- /wp:column -->\n\n<!-- wp:column -->\n<div class="wp-block-column"><!-- wp:paragraph -->\n<p>%s</p>\n<!-- /wp:paragraph --></div>\n<!-- /wp:column --></div>\n<!-- /wp:columns -->\n\n' "$a" "$b"
}

block_embed() {
  printf '%s\n' '<!-- wp:embed {"url":"https://www.youtube.com/watch?v=jNQXAC9IVRw","type":"video","providerNameSlug":"youtube","responsive":true,"className":"wp-embed-aspect-16-9 wp-has-aspect-ratio"} -->' \
    '<figure class="wp-block-embed is-type-video is-provider-youtube wp-block-embed-youtube wp-embed-aspect-16-9 wp-has-aspect-ratio"><div class="wp-block-embed__wrapper">' \
    'https://www.youtube.com/watch?v=jNQXAC9IVRw' \
    '</div></figure>' \
    '<!-- /wp:embed -->' ''
}

# One random block, weighted towards paragraphs.
block_random() {
  ri 100
  local r=$RI
  if (( r < 50 )); then block_para
  elif (( r < 58 )); then block_heading
  elif (( r < 65 )); then block_list
  elif (( r < 70 )); then block_quote
  elif (( r < 76 )); then ri "${#IMG_KEYS[@]}"; block_image "${IMG_KEYS[$RI]}"
  elif (( r < 80 )); then block_gallery
  elif (( r < 84 )); then block_table
  elif (( r < 88 )); then block_code
  elif (( r < 91 )); then block_separator
  elif (( r < 94 )); then block_buttons
  elif (( r < 97 )); then block_columns
  elif (( r < 98 )); then block_embed
  else block_para; fi
}

# A block-editor body: a lead, then blocks. Lengths run from one short note to a long article.
body_blocks() {
  local n k
  ri 100
  if (( RI < 15 )); then n=1
  elif (( RI < 70 )); then ri 5; n=$(( RI + 4 ))
  elif (( RI < 97 )); then ri 9; n=$(( RI + 12 ))
  else n=45; fi
  lead_block
  for ((k = 0; k < n; k++)); do block_random; done
}

# A classic-editor body: plain paragraphs, a heading, a list and shortcodes.
body_classic() {
  local k
  para_text; LEAD=$PARA
  printf '%s\n\n' "$(esc "$LEAD")"
  for ((k = 0; k < 2; k++)); do para_text; printf '%s\n\n' "$(esc "$PARA")"; done
  frag h "$CUR_LANG"; printf '<h2>%s</h2>\n\n' "$(esc "$FRAG")"
  printf '<ul>\n'
  for ((k = 0; k < 3; k++)); do frag_li; printf '<li>%s</li>\n' "$(esc "$FRAG")"; done
  printf '</ul>\n\n<!--more-->\n\n'
  printf '[gallery ids="%s,%s,%s" columns="3" link="file"]\n\n' "${MID[gallery-1]}" "${MID[gallery-2]}" "${MID[gallery-3]}"
  frag cap "$CUR_LANG"
  printf '[caption id="attachment_%s" align="aligncenter" width="600"]<img class="size-large wp-image-%s" src="%s" alt="%s" width="600" height="338" /> %s[/caption]\n\n' \
    "${MID[hero]}" "${MID[hero]}" "${MURL[hero]}" "${MALT[hero]}" "$(esc "$FRAG")"
  para_text; printf '%s\n' "$(esc "$PARA")"
}

# Static text of the legal pages (the extra field of the page row holds the slug).
legal_text() {
  case $1 in
    terms-of-service)
      ptext "These terms describe how you may use the services of this company. By creating an account or placing an order, you agree to them."
      ptext "We may change these terms when the law or our services change. Active customers hear about a change by email at least thirty days before it takes effect."
      ptext "Questions about these terms can be sent through the contact page." ;;
    cookie-policy)
      ptext "We use cookies to keep you signed in, to remember your language and to measure how the site is used. Some cookies are needed for the site to work at all."
      ptext "You choose which optional cookies to accept from the banner at the bottom of the page. Your choice is stored for twelve months." ;;
    refund-policy)
      ptext "A project that has not started can be cancelled with a full refund within fourteen days of signing the contract."
      ptext "Work already delivered is charged according to the agreed phases. Retainers can be paused at the end of any calendar month." ;;
    accessibility-statement)
      ptext "We aim to meet the Web Content Accessibility Guidelines at level AA on every page we build."
      ptext "If you find a barrier, tell us the page address and what stopped you. We answer within two working days." ;;
    legal-notice)
      ptext "Angaben gemäß Paragraf 5 des Telemediengesetzes."
      ptext "Verantwortlich für den Inhalt dieser Website ist die Geschäftsführung. Die vollständige Anschrift steht auf der Kontaktseite."
      ptext "Alle Inhalte unterliegen dem Urheberrecht. Eine Verwendung ist nur nach vorheriger Zustimmung erlaubt." ;;
    data-processing-agreement)
      ptext "This agreement applies when we process personal data on behalf of a customer."
      ptext "We process only the data the customer sends us, for the purpose agreed in the contract. We delete it when the contract ends, unless the law requires us to keep it." ;;
  esac
}

# The body of a page row: kind lang extra.
page_content() {
  local kind=$1 lang=$2 extra=$3
  CUR_TOPIC=business; CUR_LANG=$lang
  case $kind in
    services) lead_block; block_heading; block_list; block_para; block_buttons ;;
    locations) ptext "Our offices work as one team. Every office keeps the same hours and the same support queue."; block_list ;;
    office)
      ptext "The $extra office is on the ground floor of a converted workshop, with a small kitchen and two meeting rooms."
      ptext "Visitors are welcome on weekdays from nine to five. A short call before the visit helps us make time for you."
      block_buttons ;;
    legal) legal_text "$extra" ;;
    member) ptext "${U_BIO[$extra]}"; block_para; block_heading; block_list ;;
    case-index) block_para; block_list ;;
    case) block_heading; block_para; block_heading; block_para; block_quote; block_heading; block_para ;;
    career) block_para; block_heading; block_list; block_buttons ;;
    careers) block_para; block_list ;;
    faq) block_heading; block_para; block_heading; block_para; block_heading; block_para ;;
    resources) block_para; block_list ;;
    glossary) block_heading; block_list; block_heading; block_list ;;
    webinars) block_para; block_table ;;
    press) block_para; block_list; block_para ;;
  esac
}
