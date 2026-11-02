#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# Core of the bulk plan: the random generator, the date table, the content banks and the helpers.
# seed_bulk.sh sources the three plan files in order (plan-core.sh, plan-bodies.sh, plan-items.sh) and
# runs no WP-CLI command while planning. Every random choice comes from one generator with a fixed seed.

shopt -u patsub_replacement 2>/dev/null || true

NPOSTS=350
RS=20260101
CONTENT=/tmp/bulk-content
mkdir -p "$CONTENT"

# --- Random numbers ---------------------------------------------------------------------------------
# A linear congruential generator: the same seed gives the same plan on any machine.
rnd() { RS=$(( (RS * 1103515245 + 12345) & 0x7fffffff )); R=$(( RS >> 8 )); }
ri() { rnd; RI=$(( R % $1 )); }

# Picks one word of a space-separated pool into PICK.
choose() {
  local -a a
  read -ra a <<< "$1"
  if (( ${#a[@]} == 0 )); then echo "empty pool" >&2; exit 1; fi
  ri "${#a[@]}"
  PICK=${a[$RI]}
}

# --- Dates ------------------------------------------------------------------------------------------
# Every calendar day from 2019 to 2027, so a random day is a table index (ORD) and comments can
# come after their post without any date arithmetic.
MDAYS=(31 28 31 30 31 30 31 31 30 31 30 31)
DATE_TAB=()
for ((y = 2019; y <= 2027; y++)); do
  for ((m = 1; m <= 12; m++)); do
    dim=${MDAYS[m - 1]}
    if (( m == 2 && (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) )); then dim=29; fi
    for ((d = 1; d <= dim; d++)); do
      printf -v dt '%04d-%02d-%02d' "$y" "$m" "$d"
      DATE_TAB+=("$dt")
    done
  done
done

ord_of() { # date -> ORD
  local i
  for i in "${!DATE_TAB[@]}"; do
    if [[ ${DATE_TAB[i]} == "$1" ]]; then ORD=$i; return 0; fi
  done
  echo "unknown date $1" >&2
  exit 1
}
ord_of 2019-01-01; ORD_START=$ORD
ord_of 2020-01-01; ORD_2020=$ORD
ord_of 2026-10-31; ORD_END=$ORD
ord_of 2027-01-05; ORD_FUT=$ORD
ord_of 2027-06-28; ORD_FUT_END=$ORD

rand_ord() { # lo hi -> ORD, a random day in the range
  ri $(( $2 - $1 + 1 ))
  ORD=$(( $1 + RI ))
}

stamp() { # ordinal -> DT, that day at a random local time between 07:00 and 20:59
  local h
  ri 14; h=$(( 7 + RI ))
  ri 60
  printf -v DT '%s %02d:%02d:00' "${DATE_TAB[$1]}" "$h" "$RI"
}

# --- Banks (bulk/*.txt) -----------------------------------------------------------------------------
# titles.txt: topic|lang|title
TT_TOPIC=(); TT_LANG=(); TT_TEXT=(); declare -A TL_IDX=()
while IFS='|' read -r t l x; do
  [ -n "$x" ] || continue
  TL_IDX[$l]+="${#TT_TEXT[@]} "
  TT_TOPIC+=("$t"); TT_LANG+=("$l"); TT_TEXT+=("$x")
done < "$BULK/titles.txt"

# paragraphs.txt: topic|lang|text
PA_TEXT=(); declare -A PA_POOL=() PA_LANG=()
while IFS='|' read -r t l x; do
  [ -n "$x" ] || continue
  PA_POOL["$t|$l"]+="${#PA_TEXT[@]} "
  PA_LANG[$l]+="${#PA_TEXT[@]} "
  PA_TEXT+=("$x")
done < "$BULK/paragraphs.txt"

# fragments.txt: kind|key|text (q lines hold text|cite)
FR_TEXT=(); declare -A FPOOL=()
while IFS='|' read -r k key x; do
  [ -n "$x" ] || continue
  FPOOL["$k|$key"]+="${#FR_TEXT[@]} "
  FR_TEXT+=("$x")
done < "$BULK/fragments.txt"

# comments.txt: c|lang|name|text for readers, r|lang|text for replies
CMT_NAME=(); CMT_TEXT=(); REPLY_TEXT=()
while IFS='|' read -r kind lang a b; do
  case $kind in
    c) CMT_NAME+=("$a"); CMT_TEXT+=("$b") ;;
    r) REPLY_TEXT+=("$a${b:+|$b}") ;;
  esac
done < "$BULK/comments.txt"

# --- Text helpers -----------------------------------------------------------------------------------
# Output is HTML-escaped where it lands in block markup. Not called inside a random draw.
esc() { local s=$1; s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; printf '%s' "$s"; }
jesc() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }

# Title to ASCII slug (SLUG). Non-Latin titles come out empty and get a language prefix later.
slugify() {
  local s=$1
  s=${s//ä/ae}; s=${s//ö/oe}; s=${s//ü/ue}; s=${s//Ä/ae}; s=${s//Ö/oe}; s=${s//Ü/ue}
  s=${s//ß/ss}; s=${s//é/e}; s=${s//è/e}
  s=$(printf '%s' "$s" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  SLUG=$s
}

# A paragraph of the topic and language into PARA; English when the pair has none.
para_text() {
  local pool=${PA_POOL["$CUR_TOPIC|$CUR_LANG"]:-}
  [ -n "$pool" ] || pool=${PA_LANG[$CUR_LANG]:-}
  [ -n "$pool" ] || pool=${PA_LANG[en]}
  choose "$pool"
  PARA=${PA_TEXT[$PICK]}
}

# A fragment of a kind and key into FRAG; English when the key has none.
frag() {
  local pool=${FPOOL["$1|$2"]:-}
  [ -n "$pool" ] || pool=${FPOOL["$1|en"]}
  choose "$pool"
  FRAG=${FR_TEXT[$PICK]}
}

# A bullet item: the topic's own list, or the language's list for non-English posts.
frag_li() {
  local key=$CUR_TOPIC
  [ "$CUR_LANG" = en ] || key=$CUR_LANG
  frag li "$key"
}

ptext() { printf '<!-- wp:paragraph -->\n<p>%s</p>\n<!-- /wp:paragraph -->\n\n' "$(esc "$1")"; }

# --- Constants --------------------------------------------------------------------------------------
FA_NUM=("" "" "۲" "۳" "۴" "۵" "۶" "۷" "۸" "۹" "۱۰")
AR_NUM=("" "" "الثاني" "الثالث" "الرابع" "الخامس" "السادس" "السابع" "الثامن" "التاسع" "العاشر")
FORMATS=(aside gallery quote image)

# Media keys from seed.sh that bulk posts use as featured and inline images.
IMG_KEYS=(hero cover gallery-1 gallery-2 gallery-3 og-image diagram photo animated)
declare -A MALT=(
  [hero]="A blue gradient hero image with a white circle"
  [cover]="A purple to orange gradient used as a cover background"
  [gallery-1]="A green gradient with the text Gallery 1"
  [gallery-2]="A red and orange gradient with the text Gallery 2"
  [gallery-3]="A blue and violet gradient with the text Gallery 3"
  [og-image]="Dark violet banner with the text Open Graph"
  [diagram]="WordPress, Normalize and Mishka CMS boxes joined by arrows"
  [photo]="A pink and peach gradient with the text WebP photo"
  [animated]="Three frames of a colour-shifting gradient"
)

# Logins in the order they are created, with their role.
USER_ORDER=(lukas amira yousef hannah mehdi sara chris julia)
declare -A U_ROLE=(
  [lukas]=editor [amira]=author [yousef]=author [hannah]=author
  [mehdi]=editor [sara]=author [chris]=contributor [julia]=contributor
)
declare -A U_EMAIL=(
  [shahryar]=shahryar@mishka.tools [nadia]=nadia.karimi@example.test [omid]=omid.rahimi@example.test
  [parisa]=parisa.salehi@example.test [lukas]=lukas.brandt@example.test [amira]=amira.haddad@example.test
  [yousef]=yousef.almasri@example.test [hannah]=hannah.schulz@example.test [mehdi]=mehdi.jafari@example.test
  [sara]=sara.ahmadi@example.test [chris]=chris.morgan@example.test [julia]=julia.lange@example.test
)
declare -A U_NAME=(
  [shahryar]="Shahryar Tavakkoli" [nadia]="Nadia Karimi" [omid]="امید رحیمی" [parisa]="Parisa Salehi"
  [lukas]="Lukas Brandt" [amira]="أميرة حداد" [yousef]="Yousef Al-Masri" [hannah]="Hannah Schulz"
  [mehdi]="مهدی جعفری" [sara]="سارا احمدی" [chris]="Chris Morgan" [julia]="Julia Lange"
)
declare -A U_BIO=(
  [lukas]="Editor for the German and English posts. Writes about remote teams, pricing and case studies."
  [amira]="كاتبة ومحررة تكتب عن التصميم وتجربة المستخدم وكتابة المحتوى العربي."
  [yousef]="Writes about WordPress security, hosting and site performance."
  [hannah]="Designer and writer. Covers accessibility, forms and typography."
  [mehdi]="ویراستار بخش فارسی. درباره کسب‌وکار، مدیریت تیم و آموزش‌های گام‌به‌گام می‌نویسد."
  [sara]="نویسنده بخش آشپزی و سفر. دستورهای خانگی و یادداشت‌های سفر منتشر می‌کند."
  [chris]="Guest contributor who writes about Elixir in production."
  [julia]="Freelance contributor. Writes about design systems and small agencies."
)

# Categories: slug|name|parent slug|description. Parents come before children.
CAT_ROWS=(
  "business|Business||Running a studio, pricing and team life."
  "remote-work|Remote work|business|How we work across cities and time zones."
  "pricing|Pricing|business|Quotes, retainers and invoices."
  "case-studies|Case studies|business|Projects we finished, with the numbers."
  "hiring|Hiring|business|Interviews, job posts and onboarding."
  "design|Design||Interfaces, type and visual decisions."
  "ui-design|UI design|design|Components, patterns and screens."
  "design-systems|Design systems|ui-design|Tokens, libraries and governance."
  "typography|Typography|design|Typefaces, scales and reading comfort."
  "accessibility|Accessibility|design|Designing for everyone who uses the web."
  "travel|Travel||Trips, cities and practical notes."
  "travel-iran|Travel in Iran|travel|Cities, trains and the roads between them."
  "travel-turkey|Travel in Turkey|travel|Istanbul, the coast and the east."
  "city-guides|City guides|travel|Walks, cafés and museums by city."
  "berlin|Berlin|city-guides|Notes from a city we know well."
  "food|Food||Recipes and kitchen notes."
  "persian-cooking|Persian cooking|food|Traditional dishes, made at home."
  "baking|Baking|food|Breads, cakes and the patience they need."
  "web-development|Web development||Building sites and web apps."
  "frontend|Frontend|web-development|Browsers, components and speed."
  "backend|Backend|web-development|APIs, databases and jobs."
  "performance|Performance|web-development|Measuring and making pages faster."
  "security|Security|web-development|Keeping sites and data safe."
  "events|Events|news|Meetups, talks and workshops."
  "liveview|LiveView|elixir|Server-rendered interfaces with Phoenix LiveView."
)

# Tags per topic, separated by semicolons. Names hold no commas (WP-CLI splits tags on commas).
TAGS_elixir="Elixir;Phoenix;LiveView;Ecto;OTP;GenServer;ExUnit;Dialyzer;Oban;Telemetry;Docker;Background jobs"
TAGS_wordpress="WordPress;Gutenberg;Block themes;Plugins;Yoast SEO;WP-CLI;REST API;Redirects;Permalinks;Migration;Backups;Custom post types;Comments;Shortcodes"
TAGS_webdev="Performance;Core Web Vitals;HTTP caching;CDN;Lazy loading;WebP;Fonts;HTTPS;Content Security Policy;CORS;Logging;Deployment"
TAGS_design="Typography;Color;Dark mode;Figma;Icons;Forms;Microcopy;Accessibility"
TAGS_business="Remote work;Pricing;Freelancing;Hiring;Onboarding;Invoicing;Case study;Team rituals"
TAGS_travel="Travel;Iran;Isfahan;Istanbul;Berlin;Budget travel;Trains;Cafés"
TAGS_food="Recipes;Persian food;Baking;Sourdough;Herbs;Spices;Desserts"
TAGS_news="Release notes;Changelog;Community;Meetup;Open source;Roadmap"
TAGS_fa="آشپزی;سفر;طراحی;کسب‌وکار;برنامه‌نویسی"

TAG_ALL=(); declare -A TAGSEEN=()
for v in TAGS_elixir TAGS_wordpress TAGS_webdev TAGS_design TAGS_business TAGS_travel TAGS_food TAGS_news TAGS_fa; do
  IFS=';' read -ra parts <<< "${!v}"
  for p in "${parts[@]}"; do
    if [ -z "${TAGSEEN[$p]:-}" ]; then TAGSEEN[$p]=1; TAG_ALL+=("$p"); fi
  done
done
IFS=';' read -ra FA_TAGS <<< "$TAGS_fa"
