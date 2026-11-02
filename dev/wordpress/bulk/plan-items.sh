#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# Plans the posts, their bodies, the comments and the pages. The plan is complete before any write, so
# the random draws never depend on what the database already holds.

# Pages: slug|parent slug|title|kind|status|lang|extra. Parents come before children. The extra field is
# the slug for a legal page, the city for an office, and the login for a team member.
PAGE_LIST=(
  "services||Services|services|publish|en|"
  "web-development|services|Web development|service|publish|en|"
  "wordpress-migration|services|WordPress migration|service|publish|en|"
  "elixir-consulting|services|Elixir consulting|service|publish|en|"
  "seo-audits|services|SEO audits|service|publish|en|"
  "maintenance-plans|services|Maintenance plans|service|publish|en|"
  "locations||Locations|locations|publish|en|"
  "tehran-office|locations|Tehran office|office|publish|en|Tehran"
  "istanbul-office|locations|Istanbul office|office|publish|en|Istanbul"
  "berlin-office|locations|Berlin office|office|publish|en|Berlin"
  "dubai-office|locations|Dubai office|office|publish|en|Dubai"
  "terms-of-service||Terms of service|legal|publish|en|terms-of-service"
  "cookie-policy||Cookie policy|legal|publish|en|cookie-policy"
  "refund-policy||Refund policy|legal|publish|en|refund-policy"
  "accessibility-statement||Accessibility statement|legal|publish|en|accessibility-statement"
  "legal-notice||Impressum|legal|publish|de|legal-notice"
  "data-processing-agreement||Data processing agreement|legal|private|en|data-processing-agreement"
  "lukas-brandt|team|Lukas Brandt|member|publish|en|lukas"
  "amira-haddad|team|أميرة حداد|member|publish|ar|amira"
  "yousef-almasri|team|Yousef Al-Masri|member|publish|en|yousef"
  "hannah-schulz|team|Hannah Schulz|member|publish|en|hannah"
  "mehdi-jafari|team|مهدی جعفری|member|publish|fa|mehdi"
  "sara-ahmadi|team|سارا احمدی|member|publish|fa|sara"
  "chris-morgan|team|Chris Morgan|member|publish|en|chris"
  "julia-lange|team|Julia Lange|member|publish|de|julia"
  "case-studies||Case studies|case-index|publish|en|"
  "bakery-online-orders|case-studies|Bakery online orders|case|publish|en|"
  "school-admissions|case-studies|School admissions online|case|publish|en|"
  "clinic-booking-flow|case-studies|Clinic booking flow|case|publish|en|"
  "agency-retainers|case-studies|Agency retainers|case|publish|en|"
  "news-site-migration|case-studies|News site migration|case|publish|en|"
  "careers||Careers|careers|publish|en|"
  "senior-elixir-developer|careers|Senior Elixir developer|career|publish|en|"
  "wordpress-support-specialist|careers|WordPress support specialist|career|publish|en|"
  "product-designer|careers|Product designer|career|publish|en|"
  "faq||Frequently asked questions|faq|publish|en|"
  "resources||Resources|resources|publish|en|"
  "glossary|resources|Glossary|glossary|publish|en|"
  "webinars|resources|Webinars|webinars|publish|en|"
  "press-kit||Press kit|press|draft|en|"
)

# Categories a post of each topic can take (one pick, plus Persian posts sometimes get آموزش).
categories_for() {
  case $1 in
    elixir) choose "elixir liveview" ;;
    wordpress) choose "wordpress wordpress migration" ;;
    webdev) choose "web-development frontend backend performance" ;;
    design) choose "design ui-design typography accessibility design-systems" ;;
    business) choose "business remote-work pricing case-studies hiring" ;;
    travel) choose "travel travel-iran travel-turkey city-guides berlin" ;;
    food) choose "food persian-cooking baking" ;;
    *) choose "news releases announcements events" ;;
  esac
  CATS=$PICK
  if [ "$2" = fa ]; then
    ri 4
    # The slug of the curated Persian category آموزش, as WordPress stores it (percent-encoded).
    if (( RI == 0 )); then CATS="$CATS %d8%a2%d9%85%d9%88%d8%b2%d8%b4"; fi
  fi
}

# Two to four tags of the topic, plus one Persian tag for Persian posts. Sets TAGS (comma separated).
tags_for() {
  local v="TAGS_$1" pool out="" j tag
  pool=${!v}
  local -a names=()
  local -A seen=()
  IFS=';' read -ra names <<< "$pool"
  ri 3
  local k=$(( RI + 2 ))
  for ((j = 0; j < k; j++)); do
    ri "${#names[@]}"
    tag=${names[$RI]}
    if [ -z "${seen[$tag]:-}" ]; then seen[$tag]=1; out+="$tag,"; fi
  done
  if [ "$2" = fa ]; then
    ri "${#FA_TAGS[@]}"
    out+="${FA_TAGS[$RI]},"
  fi
  TAGS=${out%,}
}

# Posts: metadata for every post (no bodies yet). Statuses come from a fixed pattern, so the mix is the
# same on every run.
plan_posts() {
  local -A title_uses=() used=()
  local i r lang ti topic base uses n title slug s status pass sticky ord author cats tags thumb fmt
  P_TITLE=(); P_SLUG=(); P_LANG=(); P_TOPIC=(); P_STATUS=(); P_DATE=(); P_ORD=(); P_AUTHOR=()
  P_CATS=(); P_TAGS=(); P_THUMB=(); P_FORMAT=(); P_PASS=(); P_STICKY=(); P_FILE=(); P_URL=()
  P_EXCERPT=(); P_YOAST=()
  for ((i = 0; i < NPOSTS; i++)); do
    ri 100; r=$RI
    if (( r < 78 )); then lang=en; elif (( r < 88 )); then lang=fa; elif (( r < 94 )); then lang=ar; else lang=de; fi
    [ -n "${TL_IDX[$lang]:-}" ] || lang=en
    choose "${TL_IDX[$lang]}"; ti=$PICK
    topic=${TT_TOPIC[ti]}; base=${TT_TEXT[ti]}
    uses=${title_uses[$ti]:-0}; title_uses[$ti]=$(( uses + 1 ))
    title=$base
    if (( uses > 0 )); then
      n=$(( uses + 1 ))
      case $lang in
        fa) title="$base (بخش ${FA_NUM[n]:-$n})" ;;
        ar) title="$base (الجزء ${AR_NUM[n]:-$n})" ;;
        de) title="$base (Teil $n)" ;;
        *) title="$base (part $n)" ;;
      esac
    fi
    slugify "$base"; slug=${SLUG:-$lang-post}
    s=$slug; n=2
    while [ -n "${used[$s]:-}" ]; do s="$slug-$n"; n=$(( n + 1 )); done
    used[$s]=1; slug=$s

    status=publish; pass=""; sticky=0
    if (( i % 17 == 3 )); then status=draft
    elif (( i % 29 == 7 )); then status=pending
    elif (( i % 31 == 11 )); then status=private
    elif (( i % 47 == 5 )); then status=future
    elif (( i % 59 == 13 )); then pass=reader-preview
    fi
    case $i in 2|77|151|260) sticky=1 ;; esac

    if [ "$status" = future ]; then rand_ord "$ORD_FUT" "$ORD_FUT_END"; else rand_ord "$ORD_START" "$ORD_END"; fi
    ord=$ORD; stamp "$ord"
    if [ "$status" = pending ]; then choose "parisa chris julia"
    else choose "shahryar nadia omid lukas amira yousef hannah mehdi sara"; fi
    author=$PICK
    categories_for "$topic" "$lang"; cats=$CATS
    tags_for "$topic" "$lang"; tags=$TAGS
    ri 100; thumb=""
    if (( RI < 70 )); then ri "${#IMG_KEYS[@]}"; thumb=${IMG_KEYS[$RI]}; fi
    ri 100; fmt=""
    if (( RI < 6 )); then ri 4; fmt=${FORMATS[$RI]}; fi

    P_TITLE[i]=$title; P_SLUG[i]=$slug; P_LANG[i]=$lang; P_TOPIC[i]=$topic; P_STATUS[i]=$status
    P_DATE[i]=$DT; P_ORD[i]=$ord; P_AUTHOR[i]=$author; P_CATS[i]=$cats; P_TAGS[i]=$tags
    P_THUMB[i]=$thumb; P_FORMAT[i]=$fmt; P_PASS[i]=$pass; P_STICKY[i]=$sticky
    P_FILE[i]=$CONTENT/post-$i.html
    P_URL[i]="$SITE_URL/${DT:0:4}/${DT:5:2}/$slug/"
  done
  PUB=""; ELIXIR_SLUG=""
  for ((i = 0; i < NPOSTS; i++)); do
    if [ "${P_STATUS[i]}" = publish ] && [ -z "${P_PASS[i]}" ]; then
      PUB+="$i "
      if [ -z "$ELIXIR_SLUG" ] && [ "${P_TOPIC[i]}" = elixir ]; then ELIXIR_SLUG=${P_SLUG[i]}; fi
    fi
  done
}

# Bodies: each post's file, its excerpt (the lead paragraph, for 40 per cent) and its Yoast meta.
plan_bodies() {
  local i y
  for ((i = 0; i < NPOSTS; i++)); do
    CUR_TOPIC=${P_TOPIC[i]}; CUR_LANG=${P_LANG[i]}
    ri 100
    if (( RI < 12 )); then { body_classic; } > "${P_FILE[i]}"
    else { body_blocks; } > "${P_FILE[i]}"; fi
    P_EXCERPT[i]=""
    ri 100
    if (( RI < 40 )); then P_EXCERPT[i]=$LEAD; fi
    y=""
    ri 100
    if (( RI < 30 )); then
      y="\"_yoast_wpseo_metadesc\":\"$(jesc "$LEAD")\""
      ri 100
      if (( RI < 20 )); then y+=",\"_yoast_wpseo_title\":\"$(jesc "${P_TITLE[i]} | Mishka Test Blog")\""; fi
    fi
    P_YOAST[i]=$y
  done
}

# Comments on published, unprotected posts: a third get none, the rest get one to eight, with replies
# (from readers and sometimes from an author) after their parent. Pending and spam are a few per cent.
plan_comments() {
  CM_POST=(); CM_LOCAL=(); CM_PARENT=(); CM_NAME=(); CM_EMAIL=(); CM_LOGIN=()
  CM_TEXT=(); CM_DATE=(); CM_STATUS=(); CM_ORD=()
  NCM=0
  local i j k n r ptr base ord login name email text st
  local -a local_k
  for ((i = 0; i < NPOSTS; i++)); do
    [ "${P_STATUS[i]}" = publish ] || continue
    [ -z "${P_PASS[i]}" ] || continue
    ri 100; r=$RI
    if (( r < 30 )); then n=0
    elif (( r < 45 )); then n=1
    elif (( r < 62 )); then n=2
    elif (( r < 76 )); then n=3
    elif (( r < 86 )); then n=4
    elif (( r < 94 )); then n=5
    else n=8; fi
    local_k=()
    for ((j = 0; j < n; j++)); do
      k=$NCM; NCM=$(( NCM + 1 )); local_k[j]=$k
      ptr=-1
      if (( j > 0 )); then
        ri 100
        if (( RI < 40 )); then ri "$j"; ptr=${local_k[$RI]}; fi
      fi
      CM_PARENT[k]=$ptr
      base=${P_ORD[i]}
      if (( ptr >= 0 )); then base=${CM_ORD[ptr]}; fi
      ri 91; ord=$(( base + RI ))
      if (( ord > ORD_END )); then ord=$ORD_END; fi
      login=""
      ri 100
      if (( ptr >= 0 && RI < 35 )); then
        choose "shahryar nadia omid lukas amira yousef hannah mehdi sara"; login=$PICK
        name=${U_NAME[$login]}; email=${U_EMAIL[$login]}
        ri ${#REPLY_TEXT[@]}; text=${REPLY_TEXT[$RI]}
      elif (( ptr >= 0 )); then
        ri ${#CMT_NAME[@]}; name=${CMT_NAME[$RI]}; email="commenter$k@example.test"
        ri ${#REPLY_TEXT[@]}; text=${REPLY_TEXT[$RI]}
      else
        ri ${#CMT_NAME[@]}; name=${CMT_NAME[$RI]}; email="commenter$k@example.test"; text=${CMT_TEXT[$RI]}
      fi
      if [ -n "$login" ]; then st=1
      else
        ri 100
        if (( RI < 2 )); then st=spam; elif (( RI < 7 )); then st=0; else st=1; fi
      fi
      stamp "$ord"
      CM_POST[k]=$i; CM_LOCAL[k]=$j; CM_LOGIN[k]=$login; CM_NAME[k]=$name; CM_EMAIL[k]=$email
      CM_TEXT[k]=$text; CM_DATE[k]=$DT; CM_STATUS[k]=$st; CM_ORD[k]=$ord
    done
  done
}

# Pages: one file each. Kinds and dates are drawn in row order.
plan_pages() {
  local i slug parent title kind status lang extra author ord
  PG_SLUG=(); PG_PARENT=(); PG_TITLE=(); PG_STATUS=(); PG_AUTHOR=(); PG_DATE=(); PG_FILE=()
  for ((i = 0; i < ${#PAGE_LIST[@]}; i++)); do
    IFS='|' read -r slug parent title kind status lang extra <<< "${PAGE_LIST[i]}"
    if [ "$kind" = member ]; then author=$extra
    else choose "shahryar nadia lukas"; author=$PICK; fi
    rand_ord "$ORD_2020" "$ORD_END"; ord=$ORD; stamp "$ord"
    PG_SLUG[i]=$slug; PG_PARENT[i]=$parent; PG_TITLE[i]=$title; PG_STATUS[i]=$status
    PG_AUTHOR[i]=$author; PG_DATE[i]=$DT; PG_FILE[i]=$CONTENT/page-$i.html
    CUR_TOPIC=business; CUR_LANG=$lang
    page_content "$kind" "$lang" "$extra" > "${PG_FILE[i]}"
  done
}

plan_all() {
  plan_posts
  plan_bodies
  plan_comments
  plan_pages
}
