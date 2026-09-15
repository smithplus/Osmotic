#!/bin/bash
# Technical SEO audit for the landing page, https://smithplus.github.io/Osmotic/
#   scripts/seo_audit.sh [base-url]     (default: the live site; exit 1 when anything FAILs)
#
# The check functions and PASS/WARN/FAIL reporting are adapted from Churchly/SEO-audit
# (audit-urls.sh), which audits web.tabella.app; the groups follow its six-layer method
# (crawlability, indexability, rendering, architecture, structured data, page experience)
# with this site's URLs. Every request sends no-cache headers, so a fresh deploy is what's checked.
# bash 3.2 compatible (macOS).

BASE="${1:-https://smithplus.github.io/Osmotic/}"
BASE="${BASE%/}/"
ORIGIN="$(echo "$BASE" | sed -E 's#^(https?://[^/]+).*#\1#')"
HOST="${ORIGIN#*://}"
UA="Mozilla/5.0 (Osmotic-SEO-Audit)"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; GRAY='\033[0;90m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0
FAIL_LIST=(); WARN_LIST=()

pass() { echo -e "${GREEN}✓ PASS${NC} $1"; [[ -n "$2" ]] && echo -e "       $2"; ((PASS++)); echo ""; }
warn() { echo -e "${YELLOW}⚠ WARN${NC} $1"; [[ -n "$2" ]] && echo -e "       $2"; WARN_LIST+=("$1${2:+  ($2)}"); ((WARN++)); echo ""; }
fail() { echo -e "${RED}✗ FAIL${NC} $1"; [[ -n "$2" ]] && echo -e "       $2"; FAIL_LIST+=("$1${2:+  ($2)}"); ((FAIL++)); echo ""; }
group() { echo -e "${BLUE}── $1${NC}"; echo ""; }

req() { curl -s -A "$UA" -H "Cache-Control: no-cache" -H "Pragma: no-cache" --connect-timeout 8 --max-time 25 "$@" 2>/dev/null; }
status_of() { req -o /dev/null -w "%{http_code}" --max-redirs 0 "$1"; }
final_of() { req -o /dev/null -L --max-redirs 10 -w "%{http_code} %{url_effective}" "$1"; }
header_of() { req -I "$1" | tr -d '\r' | grep -i "^$2:" | head -1 | cut -d' ' -f2-; }

# check_status <label> <url> <expected first-hop status> [expected final url (redirects)]
check_status() {
  local label="$1" url="$2" expected="$3" dest="$4" got final
  got=$(status_of "$url")
  if [[ "$got" == "000" ]]; then fail "[---] $label" "$url: connection failed"; return; fi
  if [[ -n "$dest" ]]; then
    final=$(final_of "$url")
    if [[ "$got" == "$expected" && "$final" == "200 $dest" ]]; then pass "[$got→200] $label" "Final: $dest"
    elif [[ "$final" == "200 $dest" && ( "$got" == "301" || "$got" == "308" ) ]]; then warn "[$got→200] $label" "$got instead of $expected (Google treats them the same)"
    else fail "[$got] $label" "expected $expected → $dest, got $got → ${final:-nothing}"; fi
  elif [[ "$got" == "$expected" ]]; then pass "[$got] $label"
  else fail "[$got] $label" "$url: expected $expected"; fi
}

# check_type <label> <url> <content-type fragment>
check_type() {
  local label="$1" url="$2" want="$3" code ctype
  code=$(status_of "$url"); ctype=$(header_of "$url" content-type)
  if [[ "$code" == "200" && "$ctype" == *"$want"* ]]; then pass "[200 $want] $label"
  elif [[ "$code" == "200" ]]; then warn "[200] $label" "Content-Type is '${ctype}', expected *$want*"
  else fail "[$code] $label" "$url"; fi
}

meta() { echo "$HTML" | grep -oE "<meta[^>]+$1=\"$2\"[^>]*>" | head -1 | grep -oE 'content="[^"]*"' | sed 's/content="//;s/"$//'; }

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  OSMOTIC LANDING SEO AUDIT${NC}"
echo -e "${BLUE}  $BASE  ·  $(date)${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

HTML=$(req --retry 2 "$BASE")

# ---------------------------------------------------------------- Layer 1: crawlability
group "LAYER 1: Crawlability (status codes, robots.txt, sitemap, llms.txt)"
check_status "Home responds 200" "$BASE" 200
check_type "Home is served as HTML" "$BASE" "text/html"
ROBOTS=$(req "${ORIGIN}/robots.txt")
ROBOTS_CODE=$(status_of "${ORIGIN}/robots.txt")
if [[ "$ROBOTS_CODE" == "404" ]]; then
  pass "[404] robots.txt at ${ORIGIN}/ (host root)" "No robots.txt: everything is crawlable. A project site can't publish one (it would live in a ${HOST} repo)."
elif echo "$ROBOTS" | grep -qiE "^Disallow:[[:space:]]*/(Osmotic)?/?[[:space:]]*$"; then
  fail "robots.txt blocks the landing page" "$(echo "$ROBOTS" | grep -i disallow | head -3 | tr '\n' ' ')"
else
  pass "[$ROBOTS_CODE] robots.txt doesn't block the landing page"
fi
SITEMAP=$(req "${BASE}sitemap.xml")
if echo "$SITEMAP" | grep -q "<loc>${BASE}</loc>"; then pass "[sitemap] ${BASE}sitemap.xml lists the home URL"
else fail "[sitemap] ${BASE}sitemap.xml missing or doesn't list ${BASE}" "Submit it in Search Console once it exists"; fi
check_type "sitemap.xml is served as XML" "${BASE}sitemap.xml" "xml"
LLMS=$(req "${BASE}llms.txt")
if [[ "$(status_of "${BASE}llms.txt")" == "200" && "$LLMS" == "# "* ]]; then pass "[llms.txt] ${BASE}llms.txt returns 200 with a Markdown title"
else fail "[llms.txt] ${BASE}llms.txt missing or not Markdown"; fi

# ---------------------------------------------------------------- Layer 2: indexability
group "LAYER 2: Indexability (canonical, redirects, soft 404s, directives)"
CANON=$(echo "$HTML" | grep -oE '<link rel="canonical" href="[^"]*"' | head -1 | sed 's/.*href="//;s/"$//')
if [[ "$CANON" == "$BASE" ]]; then pass "[canonical] Home canonical self-references" "$CANON"
else fail "[canonical] Home canonical" "expected $BASE, got ${CANON:-MISSING}"; fi
if echo "$HTML" | grep -qiE '<meta[^>]+name="robots"[^>]+noindex'; then fail "[robots meta] Home carries noindex"
else pass "[robots meta] No noindex on the home page"; fi
if req -I "$BASE" | tr -d '\r' | grep -qi '^x-robots-tag:.*noindex'; then fail "[X-Robots-Tag] noindex header on the home page"
else pass "[X-Robots-Tag] No noindex header"; fi
check_status "HTTP → HTTPS" "http://${HOST}${BASE#"$ORIGIN"}" 301 "$BASE"
check_status "No trailing slash → with slash" "${BASE%/}" 301 "$BASE"
check_status "index.html is served (duplicate covered by the canonical)" "${BASE}index.html" 200
MISSING_CODE=$(status_of "${BASE}this-page-does-not-exist-$RANDOM")
if [[ "$MISSING_CODE" == "404" ]]; then pass "[404] Unknown URLs return a real 404 (no soft 404)"
else fail "[$MISSING_CODE] Unknown URLs should return 404"; fi
NOTFOUND=$(req "${BASE}this-page-does-not-exist")
if echo "$NOTFOUND" | grep -q 'href="/Osmotic/'; then pass "[404 page] The custom 404 links back to the landing page"
else warn "[404 page] The 404 page doesn't link back to ${BASE}"; fi

# ---------------------------------------------------------------- Layer 3: rendering
group "LAYER 3: Rendering (everything important is in the server HTML)"
TITLE=$(echo "$HTML" | grep -oE '<title>[^<]*</title>' | head -1 | sed 's/<title>//;s/<\/title>//')
if [[ -n "$TITLE" && "$TITLE" != *undefined* && "$TITLE" == *Osmotic* ]]; then
  if (( ${#TITLE} <= 60 )); then pass "[title] Title is set, specific, ${#TITLE} chars" "$TITLE"
  else warn "[title] Title is ${#TITLE} chars (Google shows about 60)" "$TITLE"; fi
else fail "[title] Title missing, generic or broken" "${TITLE:-MISSING}"; fi
DESC=$(meta name description)
if (( ${#DESC} >= 50 && ${#DESC} <= 160 )); then pass "[description] ${#DESC} chars" "$DESC"
elif [[ -n "$DESC" ]]; then warn "[description] ${#DESC} chars (aim for 50–160)" "$DESC"
else fail "[description] Missing"; fi
H1S=$(echo "$HTML" | grep -o '<h1' | wc -l | tr -d ' ')
if [[ "$H1S" == "1" ]]; then pass "[h1] Exactly one <h1>"; else fail "[h1] Found $H1S <h1> elements (want 1)"; fi
if echo "$HTML" | grep -qE '<html[^>]+lang="en"'; then pass "[lang] <html lang=\"en\">"; else fail "[lang] <html> has no lang"; fi
NOALT=$(echo "$HTML" | grep -oE '<img [^>]*>' | grep -vc 'alt="[^"]\{8,\}"')
if [[ "$NOALT" == "0" ]]; then pass "[img alt] Every image has a descriptive alt"; else fail "[img alt] $NOALT image(s) without a real alt"; fi
NOSIZE=$(echo "$HTML" | grep -oE '<img [^>]*>' | grep -v 'width="' | wc -l | tr -d ' ')
if [[ "$NOSIZE" == "0" ]]; then pass "[CLS] Every image declares width and height"; else warn "[CLS] $NOSIZE image(s) without width/height"; fi
if echo "$HTML" | grep -q 'viewport'; then pass "[mobile] viewport meta present"; else fail "[mobile] No viewport meta"; fi

# ---------------------------------------------------------------- Layer 4: architecture and links
group "LAYER 4: Site architecture and internal links"
for path in style.css main.js images/icon.png images/library.webp; do
  check_status "Asset ${path} responds 200" "${BASE}${path}" 200
done
BROKEN=0
for href in $(echo "$HTML" | grep -oE 'href="#[^"]+"' | sed 's/href="#//;s/"$//' | sort -u); do
  echo "$HTML" | grep -q "id=\"$href\"" || { BROKEN=1; fail "[anchor] #$href has no target"; }
done
[[ "$BROKEN" == "0" ]] && pass "[anchors] Every in-page link has a target"
EXT_HTTP=$(echo "$HTML" | grep -oE 'href="http://[^"]+"' | head -3)
if [[ -z "$EXT_HTTP" ]]; then pass "[links] No plain-HTTP links"; else warn "[links] Plain-HTTP links" "$EXT_HTTP"; fi
DL_CODE=$(final_of "https://github.com/smithplus/Osmotic/releases/latest" | cut -d' ' -f1)
if [[ "$DL_CODE" == "200" ]]; then pass "[download] The static download link (latest release) resolves"; else fail "[download] Latest release link returns $DL_CODE"; fi

# ---------------------------------------------------------------- Layer 5: structured data and social
group "LAYER 5: Structured data (JSON-LD) and social cards"
JSONLD=$(echo "$HTML" | tr '\n' ' ' | grep -oE '<script type="application/ld\+json">[^<]+</script>' | sed 's/<script type="application\/ld+json">//;s/<\/script>//')
if [[ -n "$JSONLD" ]]; then
  if echo "$JSONLD" | python3 -c 'import json,sys; d=json.load(sys.stdin); items=d.get("@graph",[d]); t=[i.get("@type") for i in items]; sys.exit(0 if "SoftwareApplication" in t else 1)' 2>/dev/null; then
    pass "[JSON-LD] Valid JSON with a SoftwareApplication in the server HTML"
    echo "$JSONLD" | python3 -c 'import json,sys; d=json.load(sys.stdin); a=[i for i in d.get("@graph",[d]) if i.get("@type")=="SoftwareApplication"][0]; missing=[k for k in ("name","operatingSystem","applicationCategory","offers") if k not in a]; sys.exit(1 if missing else 0)' 2>/dev/null \
      && pass "[JSON-LD] SoftwareApplication has name, operatingSystem, applicationCategory, offers" \
      || fail "[JSON-LD] SoftwareApplication is missing a field Google requires"
  else fail "[JSON-LD] Present but not valid JSON, or no SoftwareApplication"; fi
else fail "[JSON-LD] No <script type=\"application/ld+json\"> in the server HTML"; fi
for p in og:title og:description og:url og:image og:type; do
  v=$(meta property "$p"); [[ -n "$v" ]] && pass "[$p] set" "$v" || fail "[$p] missing"
done
[[ "$(meta property og:url)" == "$BASE" ]] && pass "[og:url] matches the canonical" || fail "[og:url] differs from the canonical"
OGIMG=$(meta property og:image)
if [[ -n "$OGIMG" ]]; then
  check_type "og:image responds as an image" "$OGIMG" "image/"
  SIZE=$(req -o /dev/null -w "%{size_download}" "$OGIMG")
  if (( SIZE < 300000 )); then pass "[og:image] $((SIZE / 1024)) KB (previews skip cards over ~300 KB)"
  else warn "[og:image] $((SIZE / 1024)) KB: some previews skip cards over ~300 KB"; fi
fi
[[ -n "$(meta name twitter:card)" ]] && pass "[twitter:card] set" "$(meta name twitter:card)" || fail "[twitter:card] missing"

# ---------------------------------------------------------------- Layer 6: page experience and security
group "LAYER 6: Page experience and security"
[[ "$BASE" == https://* ]] && pass "[HTTPS] Served over HTTPS" || fail "[HTTPS] Not HTTPS"
if echo "$HTML" | grep -q 'Content-Security-Policy'; then pass "[CSP] Content Security Policy present (meta)"; else warn "[CSP] No Content Security Policy"; fi
HSTS=$(header_of "$BASE" strict-transport-security)
[[ -n "$HSTS" ]] && pass "[HSTS] $HSTS" || warn "[HSTS] No Strict-Transport-Security header (set by the host; GitHub Pages controls it)"
PAGE_BYTES=$(req -o /dev/null -w "%{size_download}" "$BASE")
HERO_BYTES=$(req -o /dev/null -w "%{size_download}" "${BASE}images/library.webp")
TOTAL=$((PAGE_BYTES + HERO_BYTES))
if (( TOTAL < 250000 )); then pass "[weight] HTML + hero image: $((TOTAL / 1024)) KB"
else warn "[weight] HTML + hero image: $((TOTAL / 1024)) KB"; fi
TTFB=$(req -o /dev/null -w "%{time_starttransfer}" "$BASE")
if awk "BEGIN{exit !($TTFB < 0.8)}"; then pass "[TTFB] ${TTFB}s"; else warn "[TTFB] ${TTFB}s (over 0.8 s)"; fi
if echo "$HTML" | grep -q 'fetchpriority="high"'; then pass "[LCP] Hero image has fetchpriority=high"; else warn "[LCP] Hero image isn't prioritized"; fi
if echo "$HTML" | grep -qE '<script[^>]+src=[^>]+defer'; then pass "[render] Scripts are deferred"; else warn "[render] A script may block rendering"; fi

# ---------------------------------------------------------------- summary
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  FINAL RESULT${NC}"
echo -e "${GREEN}  ✓ PASS: $PASS${NC}"
echo -e "${YELLOW}  ⚠ WARN: $WARN${NC}"
echo -e "${RED}  ✗ FAIL: $FAIL${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
if [[ ${#FAIL_LIST[@]} -gt 0 ]]; then
  echo -e "${RED}── FAILS ──${NC}"; for i in "${FAIL_LIST[@]}"; do echo -e "  ${RED}✗${NC} $i"; done; echo ""
fi
if [[ ${#WARN_LIST[@]} -gt 0 ]]; then
  echo -e "${YELLOW}── WARNINGS ──${NC}"; for i in "${WARN_LIST[@]}"; do echo -e "  ${YELLOW}⚠${NC} $i"; done; echo ""
fi
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
