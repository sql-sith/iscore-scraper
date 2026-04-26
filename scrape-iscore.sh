#!/usr/bin/env bash
# scrape-iscore.sh
#
# Archives an IScorE competition site for offline/historical reference.
# Produces a self-contained directory with relative links that works whether
# hosted at a domain root or in a subdirectory.
#
# Usage:
#   ./scrape-iscore.sh [options]
#
# Options:
#   -u URL    Base URL of the IScorE site  (default: https://iscore.iseage.org)
#   -c FILE   Path to a Netscape-format cookies file (required to capture
#             authenticated pages: /blue/, /red/wiki/, /messages/, etc.)
#   -o DIR    Output directory             (default: iscore-YYYY)
#   -r ID     Team score report ID         (default: 1004)
#   -w N      Wait N seconds between wget requests to be polite  (default: 1)
#   -i        Insecure mode (skip certificate checks)
#   -n        Non-interactive: skip cookie re-prompt on session expiry
#   -h        Show this help
#
# See README-scraping.md for full instructions including how to get a cookie file.

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
SITE_URL="https://iscore.iseage.org"
YEAR=$(date +%Y)
OUTPUT_DIR="iscore-${YEAR}"
COOKIES_FILE=""
WAIT=1
TEAM_REPORT_ID="1004"   # ID in /reports/team/{id}/ — appears in nav links
INTERACTIVE=true
INSECURE=false

# ── Argument parsing ───────────────────────────────────────────────────────────
usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
    exit 0
}

set -euo pipefail

INSECURE=false
INTERACTIVE=true

# the leading colon captures options that require arguments but none is supplied:
while getopts ":u:c:o:r:w:nih" opt; do
  case "$opt" in
    u) SITE_URL="${OPTARG%/}" ;;   # strip trailing slash if present
    c) COOKIES_FILE="$OPTARG" ;;
    o) OUTPUT_DIR="$OPTARG" ;;
    r) TEAM_REPORT_ID="$OPTARG" ;;
    w) WAIT="$OPTARG" ;;
    n) INTERACTIVE=false ;;       # pure flag
    i) INSECURE=true ;;           # pure flag
    h) usage; exit 0 ;;

    :)  # missing argument for an option that requires one
        echo "Option -$OPTARG requires an argument." >&2
        usage >&2
        exit 2
        ;;

    \?) # unknown option
        echo "Unknown option: -$OPTARG" >&2
        usage >&2
        exit 2
        ;;
  esac
done

# shift out parsed options to check for unexpected ("extra") arguments:
shift $((OPTIND - 1))
if (($#)); then
  echo "Unexpected argument(s): $*" >&2
  usage >&2
  exit 2
fi

# ── Prerequisites ──────────────────────────────────────────────────────────────
for cmd in wget curl grep sed; do
    command -v "$cmd" >/dev/null || { echo "ERROR: '$cmd' is required but not found." >&2; exit 1; }
done

# ── Derived values ─────────────────────────────────────────────────────────────
SITE_HOST=$(echo "$SITE_URL" | sed 's|https\?://||; s|/.*||')
DEST="${OUTPUT_DIR}/${SITE_HOST}"

# ── Helpers ────────────────────────────────────────────────────────────────────
log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARNING: $*" >&2; }

# Build wget and curl option arrays
WGET_ARGS=(
    --mirror                 # recursive, infinite depth, timestamps
    --convert-links          # rewrite links to relative paths (key for subdirectory hosting)
    --adjust-extension       # add .html to extension-less files
    --page-requisites        # grab CSS, JS, images referenced by each page
    --no-parent              # don't crawl above the seed URLs
    "--wait=${WAIT}"         # be polite
    -e robots=off            # ignore robots.txt (archival use)
    --no-verbose             # reduce noise; remove this if you need to debug
    "--directory-prefix=${OUTPUT_DIR}"
)

CURL_ARGS=( --silent --show-error --fail )

if [[ -n "$COOKIES_FILE" ]]; then
    if [[ ! -f "$COOKIES_FILE" ]]; then
        echo "ERROR: Cookie file not found: $COOKIES_FILE" >&2
        echo "See README-scraping.md for how to export cookies from your browser." >&2
        exit 1
    fi
    WGET_ARGS+=( "--load-cookies=${COOKIES_FILE}" )
    CURL_ARGS+=( --cookie "$COOKIES_FILE" )
fi

if [[ "$INSECURE" == "true" ]]; then
    WGET_ARGS+=( --no-check-certificate )
    CURL_ARGS+=( --insecure )
fi

# ── fix_page FILE ─────────────────────────────────────────────────────────────
# Rewrites absolute root-relative hrefs/srcs in a curl-fetched HTML page to
# relative paths. Unlike wget --convert-links, curl does no rewriting, so every
# curl-fetched page requires this post-processing step.
#
# The correct relative prefix depends on the file's depth in the archive tree,
# which this function derives automatically from the file path. It also detects
# whether the page lives inside /blue/ so that blue-subsection nav links get
# the right prefix.
#
# Running this on a wget-processed page is always safe: wget already rewrote
# all absolute paths to relative ones, so none of the patterns will match.
#
#   FILE  absolute path to the HTML file to fix in-place
fix_page() {
    local f=$1

    # Derive depth from the path relative to $DEST.
    # e.g. blue/anomalies/42/index.html → rel_dir=blue/anomalies/42 → depth 3
    local rel="${f#"${DEST}/"}"
    local rel_dir="${rel%/index.html}"
    local slash_count
    slash_count=$(tr -dc '/' <<< "$rel_dir" | wc -c)
    local depth=$(( slash_count + 1 ))

    # Root prefix: depth repetitions of "../"
    local rp=''
    for (( i = 0; i < depth; i++ )); do rp="${rp}../"; done

    # Blue-section prefix for sub-pages of /blue/ (e.g. /blue/tsi/, /blue/anomalies/).
    # Pages inside /blue/ can drop the "blue/" component; pages outside need the
    # full rp + "blue/" path.
    local bp
    if [[ "$rel_dir" == blue/* ]]; then
        bp=''
        for (( i = 0; i < depth - 1; i++ )); do bp="${bp}../"; done
    else
        bp="${rp}blue/"
    fi

    # Static assets
    sed -i "s|href=\"/static/|href=\"${rp}static/|g"   "$f"
    sed -i "s|src=\"/static/|src=\"${rp}static/|g"     "$f"

    # Root-level nav links
    sed -i "s|href=\"/\"|href=\"${rp}index.html\"|g"                                                 "$f"
    sed -i "s|href=\"/logout/\"|href=\"${rp}logout/index.html\"|g"                                   "$f"
    sed -i "s|href=\"/messages/\"|href=\"${rp}messages/index.html\"|g"                               "$f"
    sed -i "s|href=\"/user_profile/\"|href=\"${rp}user_profile/index.html\"|g"                       "$f"
    sed -i "s|href=\"/red/wiki/\"|href=\"${rp}red/wiki/index.html\"|g"                               "$f"
    sed -i "s|href=\"/services/status/\"|href=\"${rp}services/status/index.html\"|g"                 "$f"

    # Statistics section
    sed -i "s|href=\"/statistics/trends/\"|href=\"${rp}statistics/trends/index.html\"|g"             "$f"
    sed -i "s|href=\"/statistics/flag/\"|href=\"${rp}statistics/flag/index.html\"|g"                 "$f"
    sed -i "s|href=\"/statistics/anomalies/\"|href=\"${rp}statistics/anomalies/index.html\"|g"       "$f"
    sed -i "s|href=\"/statistics/availability/\"|href=\"${rp}statistics/availability/index.html\"|g" "$f"

    # Blue team section.
    # /blue/ itself always uses rp (resolves to root then into blue/).
    # Sub-pages use bp: for pages inside /blue/ this is one level shallower
    # (they're already in blue/); for pages outside /blue/ bp includes "blue/".
    sed -i "s|href=\"/blue/\"|href=\"${rp}blue/index.html\"|g"                                       "$f"
    sed -i "s|href=\"/blue/tsi/\"|href=\"${bp}tsi/index.html\"|g"                                    "$f"
    sed -i "s|href=\"/blue/anomalies/\"|href=\"${bp}anomalies/index.html\"|g"                        "$f"
    sed -i "s|href=\"/blue/usability/\"|href=\"${bp}usability/index.html\"|g"                        "$f"
    sed -i "s|href=\"/blue/dns/\"|href=\"${bp}dns/index.html\"|g"                                    "$f"
    sed -i "s|href=\"/blue/teaminfo/\"|href=\"${bp}teaminfo/index.html\"|g"                          "$f"
    sed -i "s|href=\"/blue/download/flags/\"|href=\"${bp}download/flags/index.html\"|g"              "$f"
    sed -i "s|href=\"/blue/summary\"|href=\"${bp}summary.html\"|g"                                   "$f"

    # Breadcrumb self-link: derive the exact absolute URL this page would have
    # on the live server, then rewrite it to "./".  Must come before the
    # generic /reports/team/ rewrite below.
    sed -i "s|href=\"/${rel_dir}/\"|href=\"./\"|g"                                                   "$f"

    # Score report nav link — points to our team's report page
    sed -i "s|href=\"/reports/team/[0-9]*/\"|href=\"${rp}reports/team/${TEAM_REPORT_ID}/index.html\"|g" "$f"
}

# ── is_login_page FILE ────────────────────────────────────────────────────────
# Returns 0 if the file looks like an IScorE login page, 1 otherwise.
is_login_page() {
    grep -q '<title>Login' "$1" 2>/dev/null
}

# ── validate_file_type FILE ───────────────────────────────────────────────────
# Checks that a fetched binary or text file matches its expected type by
# inspecting the first few bytes. Warns and returns 1 on mismatch.
validate_file_type() {
    local f="$1"
    if [[ ! -s "$f" ]]; then
        warn "  ${f##"$DEST"/}: file is empty"
        return 1
    fi
    local ext="${f##*.}"
    case "$ext" in
        pdf)
            local magic
            magic=$(dd if="$f" bs=4 count=1 2>/dev/null)
            if [[ "$magic" != "%PDF" ]]; then
                warn "  ${f##"$DEST"/}: expected PDF but file does not start with %PDF (got login page?)"
                return 1
            fi
            ;;
        json)
            if ! python3 -c "import sys,json; json.load(open(sys.argv[1]))" "$f" 2>/dev/null; then
                warn "  ${f##"$DEST"/}: expected JSON but file is not valid JSON (got login page?)"
                return 1
            fi
            ;;
    esac
    return 0
}

# ── prompt_cookie_refresh ─────────────────────────────────────────────────────
# In interactive mode, tells the user the session expired and waits for them
# to refresh cookies.txt before continuing. In non-interactive mode, just warns.
# Returns 0 to signal "ready to retry", 1 if non-interactive.
prompt_cookie_refresh() {
    warn "Session expired — one or more pages came back as the login page."
    if [[ "$INTERACTIVE" == "true" ]]; then
        echo >&2
        echo "  [?] Please export fresh cookies to: ${COOKIES_FILE}" >&2
        echo "      Then press Enter to retry, or Ctrl+C to abort." >&2
        read -r _
        return 0
    fi
    warn "  (Run without -n to be prompted for fresh cookies interactively.)"
    return 1
}

# ── Summary ────────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  IScorE site archiver"
echo "  Site:    ${SITE_URL}"
echo "  Output:  ${OUTPUT_DIR}/"
echo "  Auth:    ${COOKIES_FILE:-none (public pages only)}"
echo "  Report:  /reports/team/${TEAM_REPORT_ID}/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[[ -z "$COOKIES_FILE" ]] && warn "No cookie file provided — authenticated pages (/blue/, /red/wiki/, etc.) will be skipped."
echo

mkdir -p "$DEST"

# ══════════════════════════════════════════════════════════════════════════════
# Phase 1 — wget mirror
#
# All HTML pages are fetched in a single wget run so that --convert-links can
# rewrite links across all of them at once.
#
# /scoreboard/ is included explicitly because it is an AJAX fragment (no
# <html> tag) loaded by the main page with $.get(). wget fetches it as a seed
# URL but does NOT spider its links, since link-following only works on full
# HTML documents. Other teams' report pages must be fetched explicitly in
# Phase 2e.
# ══════════════════════════════════════════════════════════════════════════════
log "Phase 1: Mirroring site pages..."

SEED_URLS=(
    "${SITE_URL}/"
    "${SITE_URL}/scoreboard/"
    "${SITE_URL}/statistics/trends/"
    "${SITE_URL}/statistics/flag/"
    "${SITE_URL}/statistics/anomalies/"
    "${SITE_URL}/statistics/availability/"
    "${SITE_URL}/services/status/"
)

if [[ -n "$COOKIES_FILE" ]]; then
    SEED_URLS+=(
        "${SITE_URL}/blue/"
        "${SITE_URL}/red/wiki/"
        "${SITE_URL}/messages/"
        "${SITE_URL}/user_profile/"
    )
fi

wget "${WGET_ARGS[@]}" "${SEED_URLS[@]}" || {
    rc=$?
    if (( rc == 8 )); then
        warn "wget exited with code 8 (server errors, e.g. 404s for missing assets) — continuing"
    else
        echo "ERROR: wget failed with exit code ${rc}" >&2
        exit "$rc"
    fi
}
log "Phase 1 complete."
echo

# ── Early session-expiry check ─────────────────────────────────────────────────
# If Phase 1 captured any auth pages as login pages, prompt for fresh cookies
# now before Phase 2 begins — that way the curl fetches succeed on first attempt.
if [[ -n "$COOKIES_FILE" ]]; then
    PHASE1_LOGIN_COUNT=0
    for dir in blue red messages user_profile reports; do
        [[ -d "${DEST}/${dir}" ]] || continue
        while IFS= read -r f; do
            is_login_page "$f" && (( PHASE1_LOGIN_COUNT++ )) || true
        done < <(find "${DEST}/${dir}" -name "*.html" 2>/dev/null)
    done
    if (( PHASE1_LOGIN_COUNT > 0 )); then
        warn "${PHASE1_LOGIN_COUNT} authenticated page(s) from Phase 1 look like login pages."
        if prompt_cookie_refresh; then
            # Reload CURL_ARGS with the freshened cookies file
            CURL_ARGS=( --silent --show-error --fail --cookie "$COOKIES_FILE" )
        fi
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# Phase 2 — Explicit fetches for content wget won't discover
#
# Covers four categories:
#   a) JSON API endpoints — polled by live JS but never linked as HTML
#   b) Timezone data files — referenced by a hardcoded absolute JS path
#   c) Individual anomaly detail pages — only one is ever <a href>-linked in
#      the blue/anomalies list (the most-recently-accepted one); the rest only
#      appear in form action= attributes which wget does not follow
#   d) Submission pages (report, documentation, explanation) and their attached
#      documents — linked from blue/index.html but wget saves them as login pages
#      because the session expires during the crawl
# ══════════════════════════════════════════════════════════════════════════════
log "Phase 2: Fetching content not discovered by link-following..."

# 2a — API data snapshots
mkdir -p "${DEST}/api/v1/flags" "${DEST}/api/v1/anomalies"

if curl "${CURL_ARGS[@]}" "${SITE_URL}/api/v1/flags/stats.json" \
        -o "${DEST}/api/v1/flags/stats.json" 2>/dev/null; then
    validate_file_type "${DEST}/api/v1/flags/stats.json"
    log "  Saved /api/v1/flags/stats.json"
else
    warn "/api/v1/flags/stats.json not available (may require auth or may not exist)"
fi

if curl "${CURL_ARGS[@]}" "${SITE_URL}/api/v1/anomalies/stats" \
        -o "${DEST}/api/v1/anomalies/stats.json" 2>/dev/null; then
    validate_file_type "${DEST}/api/v1/anomalies/stats.json"
    log "  Saved /api/v1/anomalies/stats"
else
    warn "/api/v1/anomalies/stats not available (may require auth or may not exist)"
fi

# 2b — Timezone data (used by score trends and flag stats charts)
# The pages reference this with a hardcoded absolute path /static/tz/northamerica,
# so wget's spider never fetches it. Without it, ALL Flot time-axis charts fail.
mkdir -p "${DEST}/static/tz"
if curl "${CURL_ARGS[@]}" "${SITE_URL}/static/tz/northamerica" \
        -o "${DEST}/static/tz/northamerica" 2>/dev/null; then
    log "  Saved /static/tz/northamerica (timezone data for charts)"
else
    warn "/static/tz/northamerica not available — score trend and flag charts may not render"
fi

# ── fetch_curl_pages LABEL INDEX_FILE URL_PREFIX ID_PATTERN ──────────────────
# Helper used by 2c and 2d to fetch a set of authenticated HTML pages whose IDs
# are extracted from an already-saved index file. Warns on login captures and
# offers an interactive retry if the session has expired.
#
#   LABEL        display name used in log/warn messages
#   INDEX_FILE   local file to scan for IDs (already fetched by wget)
#   URL_PREFIX   live server URL prefix; fetches ${URL_PREFIX}/${id}/
#   ID_PATTERN   grep -oP pattern (without /K) that precedes the numeric ID
#   OUT_PREFIX   local directory prefix for saving; saves to ${OUT_PREFIX}/${id}/
fetch_curl_pages() {
    local label=$1 index_file=$2 url_prefix=$3 id_pattern=$4 out_prefix=$5

    [[ -f "$index_file" ]] || { warn "  ${label}: index file not found, skipping"; return; }

    local ids ok=0 warn_count=0
    ids=$(grep -oP "${id_pattern}\K[0-9]+" "$index_file" | sort -un 2>/dev/null || true)

    if [[ -z "$ids" ]]; then
        warn "  ${label}: no IDs found in ${index_file##"$DEST"/}"
        return
    fi

    local retried=false
    for id in $ids; do
        mkdir -p "${out_prefix}/${id}/"
        if curl "${CURL_ARGS[@]}" "${url_prefix}/${id}/" \
                -o "${out_prefix}/${id}/index.html" 2>/dev/null \
           && [[ -s "${out_prefix}/${id}/index.html" ]]; then
            if is_login_page "${out_prefix}/${id}/index.html"; then
                warn "  ${label} ${id}: got login page"
                (( warn_count++ )) || true
                # Offer one interactive retry per category (not per page)
                if [[ "$retried" == "false" ]] && prompt_cookie_refresh; then
                    retried=true
                    # Retry this page immediately with fresh cookies
                    if curl "${CURL_ARGS[@]}" "${url_prefix}/${id}/" \
                            -o "${out_prefix}/${id}/index.html" 2>/dev/null \
                       && ! is_login_page "${out_prefix}/${id}/index.html"; then
                        (( warn_count-- )) || true
                        (( ok++ )) || true
                    fi
                fi
            else
                (( ok++ )) || true
            fi
        else
            warn "  ${label} ${id}: fetch failed or empty"
            (( warn_count++ )) || true
        fi
    done
    log "  ${label}: ${ok} saved, ${warn_count} warnings"
}

# 2c — Anomaly detail pages
# IDs come from form action= attributes like /blue/anomalies/{id}/accept_decline/
# which wget does not rewrite (query-string actions are left as absolute paths).
if [[ -n "$COOKIES_FILE" ]]; then
    log "  Fetching individual anomaly detail pages..."
    fetch_curl_pages \
        "anomaly" \
        "${DEST}/blue/anomalies/index.html" \
        "${SITE_URL}/blue/anomalies" \
        '/blue/anomalies/' \
        "${DEST}/blue/anomalies"
fi

# 2d — Submission pages (report, documentation, explanation)
# These are linked from blue/index.html. After wget's --convert-links the hrefs
# are relative (e.g. submit/report/1383/), so we match the relative form.
if [[ -n "$COOKIES_FILE" ]]; then
    log "  Fetching submission pages..."
    for type in report documentation explanation; do
        fetch_curl_pages \
            "submit/${type}" \
            "${DEST}/blue/index.html" \
            "${SITE_URL}/blue/submit/${type}" \
            "submit/${type}/" \
            "${DEST}/blue/submit/${type}"
    done

    # Fetch uploaded documents (PDFs, etc.) referenced by submission pages
    if [[ -d "${DEST}/blue/submit" ]]; then
        log "  Fetching uploaded documents (PDFs, etc.)..."
        DOC_PATHS=$(grep -roh 'upload/docs/[^"]*' "${DEST}/blue/submit/" 2>/dev/null \
            | sed 's|.*upload/docs/|/static/upload/docs/|' | sort -u || true)
        DOC_OK=0
        DOC_WARN=0
        for doc in $DOC_PATHS; do
            local_path="${DEST}/${doc#/}"
            mkdir -p "${DEST}/$(dirname "${doc#/}")"
            if curl "${CURL_ARGS[@]}" "${SITE_URL}${doc}" -o "$local_path" 2>/dev/null; then
                if validate_file_type "$local_path"; then
                    (( DOC_OK++ )) || true
                else
                    (( DOC_WARN++ )) || true
                fi
            else
                warn "  Could not fetch: ${doc}"
                (( DOC_WARN++ )) || true
            fi
        done
        log "  Uploaded documents: ${DOC_OK} fetched, ${DOC_WARN} warnings"
    fi
fi

# 2e — Other teams' score report pages
# The scoreboard AJAX fragment is not spidered by wget, so all team report
# pages must be fetched explicitly. Our own report (TEAM_REPORT_ID) was already
# fetched by wget via a direct link from blue/index.html.
SCOREBOARD_INDEX="${DEST}/scoreboard/index.html"
if [[ -f "$SCOREBOARD_INDEX" ]]; then
    log "  Fetching other teams' score report pages..."
    REPORT_IDS=$(grep -oP 'reports/team/\K[0-9]+' "$SCOREBOARD_INDEX" | sort -un || true)
    REPORT_OK=0; REPORT_WARN=0
    for id in $REPORT_IDS; do
        [[ "$id" == "$TEAM_REPORT_ID" ]] && continue   # wget already fetched ours
        mkdir -p "${DEST}/reports/team/${id}"
        outfile="${DEST}/reports/team/${id}/index.html"
        if curl "${CURL_ARGS[@]}" "${SITE_URL}/reports/team/${id}/" \
                -o "$outfile" 2>/dev/null \
           && [[ -s "$outfile" ]] \
           && ! is_login_page "$outfile"; then
            (( REPORT_OK++ )) || true
        else
            warn "  report ${id}: fetch failed or got login page"
            rm -f "$outfile"
            (( REPORT_WARN++ )) || true
        fi
    done
    log "  Other team reports: ${REPORT_OK} saved, ${REPORT_WARN} warnings"
else
    warn "  scoreboard not found — other teams' report pages not fetched"
fi

log "Phase 2 complete."
echo

# ══════════════════════════════════════════════════════════════════════════════
# Phase 3 — Post-processing fixes
#
# Fixes several issues that survive wget's link rewriting:
#   a) Scoreboard: main page loads it via AJAX with a hardcoded absolute URL
#      (/scoreboard/) which fails offline; rewrite to a relative path.
#      Also rewrites submit links in blue/index.html to trailing-slash form to
#      avoid browsers serving stale (login-page) cached versions.
#   b) Timezone paths: score trends and flag pages hardcode /static/tz as an
#      absolute base path; rewrite to relative so it resolves from any host dir
#   c) Live-update stripping: remove JS intervals that reload pages or poll
#      APIs during the competition (meaningless and noisy in an archive)
#   d) Curl-fetched pages: fix absolute paths on all pages that curl fetched
#      (anomaly detail pages and submission pages), using fix_curl_page()
# ══════════════════════════════════════════════════════════════════════════════
log "Phase 3: Post-processing fixes..."

# 3a — Fix scoreboard AJAX URL and submit link cache-busting
# --convert-links rewrites href/src attributes but not JS string literals.
# The main page does $.get('/scoreboard/', ...) — rewrite to a relative path.
#
# Submission links are rewritten from index.html form to trailing-slash form.
# wget --convert-links produces href="submit/report/1383/index.html", but
# browsers may have cached a stale (login-page) version of that URL from an
# earlier failed crawl. Trailing-slash URLs are distinct cache entries.
INDEX_HTML="${DEST}/index.html"
if [[ -f "$INDEX_HTML" ]]; then
    sed -i "s|$.get('/scoreboard/'|$.get('scoreboard/index.html'|g" "$INDEX_HTML"
    log "  Fixed scoreboard AJAX URL in index.html"
fi

BLUE_INDEX="${DEST}/blue/index.html"
if [[ -f "$BLUE_INDEX" ]]; then
    for type in report documentation explanation; do
        sed -i "s|href=\"submit/${type}/\([0-9]*\)/index\.html\"|href=\"submit/${type}/\1/\"|g" "$BLUE_INDEX"
    done
    log "  Rewrote submit links in blue/index.html to trailing-slash form"
fi

# Fix scoreboard's absolute https:// team-report links.
# wget --convert-links only rewrites root-relative (/path) hrefs, not fully-
# qualified https://domain/path URLs. The scoreboard is also an AJAX fragment,
# so wget may not process its links at all. Rewrite to root-relative paths
# (not file-relative) because the fragment is injected into index.html at the
# archive root via $.get().
SCOREBOARD_HTML="${DEST}/scoreboard/index.html"
if [[ -f "$SCOREBOARD_HTML" ]]; then
    sed -i 's|href="https://iscore\.iseage\.org/reports/team/\([0-9]*/\)"|href="reports/team/\1index.html"|g' \
        "$SCOREBOARD_HTML"
    log "  Fixed absolute team-report links in scoreboard/index.html"
fi

# 3b — Fix hardcoded /static/tz absolute path in chart pages
# timezoneJS loads timezone data from a path set by zoneFileBasePath.
# The live pages use an absolute path that only works at the server root.
# Rewrite to a relative path based on each page's depth.
TRENDS_HTML="${DEST}/statistics/trends/index.html"
FLAG_HTML="${DEST}/statistics/flag/index.html"
for f in "$TRENDS_HTML" "$FLAG_HTML"; do
    if [[ -f "$f" ]]; then
        sed -i 's|zoneFileBasePath = "/static/tz"|zoneFileBasePath = "../../static/tz"|g' "$f"
        log "  Fixed timezone base path in ${f##"$DEST"/}"
    fi
done

# 3c — Strip live-update behaviors

# Service status page does a full page reload every 20 seconds
STATUS_HTML="${DEST}/services/status/index.html"
if [[ -f "$STATUS_HTML" ]]; then
    sed -i 's/setInterval[^;]*window\.location\.reload[^;]*;//g' "$STATUS_HTML"
    log "  Stripped auto-reload from services/status"
fi

# Flag and anomaly stats pages poll their APIs every 15-60 seconds
for page in flag anomalies; do
    PAGE_HTML="${DEST}/statistics/${page}/index.html"
    if [[ -f "$PAGE_HTML" ]]; then
        sed -i 's/setInterval(updateGraphs[^;]*;//g' "$PAGE_HTML"
        log "  Stripped API polling from statistics/${page}"
    fi
done

# 3d — Fix absolute paths in all curl-fetched pages
#
# curl doesn't rewrite paths. Every page fetched in Phase 2 has absolute
# root-relative hrefs and srcs. fix_page() calculates the correct relative
# prefix from the file's depth and handles all page types uniformly.
# Running it on a wget-processed page is safe (patterns won't match).

CURL_PAGES_FIXED=0
for f in \
    "${DEST}/blue/anomalies"/*/index.html \
    "${DEST}/blue/submit"/*/*/index.html \
    "${DEST}/reports/team"/*/index.html; do
    [[ -f "$f" ]] || continue
    is_login_page "$f" && continue
    # Our own report was fetched by wget; its absolute paths are already gone,
    # so fix_page would be a no-op — but skip it explicitly for clarity.
    [[ "$f" == */reports/team/"${TEAM_REPORT_ID}"/index.html ]] && continue
    fix_page "$f"
    (( CURL_PAGES_FIXED++ )) || true
done
log "  Fixed paths in ${CURL_PAGES_FIXED} curl-fetched page(s)"

log "Phase 3 complete."
echo

# ══════════════════════════════════════════════════════════════════════════════
# Phase 4 — Validation
#
# Warn about any authenticated pages that were saved as the login page.
# This happens when the session cookie expires mid-crawl.
# ══════════════════════════════════════════════════════════════════════════════
log "Phase 4: Validating archive..."

AUTH_DIRS=( "blue" "red" "messages" "user_profile" "reports" )
LOGIN_CAPTURES=()

for dir in "${AUTH_DIRS[@]}"; do
    if [[ -d "${DEST}/${dir}" ]]; then
        while IFS= read -r f; do
            if is_login_page "$f"; then
                LOGIN_CAPTURES+=( "${f#"${DEST}"/}" )
            fi
        done < <(find "${DEST}/${dir}" -name "*.html")
    fi
done

if [[ ${#LOGIN_CAPTURES[@]} -gt 0 ]]; then
    warn "${#LOGIN_CAPTURES[@]} authenticated page(s) were saved as the login page."
    warn "This means the session cookie expired during the crawl."
    warn "Re-export fresh cookies and re-run to fix. Affected files:"
    for f in "${LOGIN_CAPTURES[@]}"; do
        warn "  $f"
    done
else
    log "  All authenticated pages look correct (no login-page captures detected)"
fi

echo

# ══════════════════════════════════════════════════════════════════════════════
# Phase 5 — Inventory
# ══════════════════════════════════════════════════════════════════════════════
log "Phase 5: Generating inventory..."

HTML_COUNT=$(find "$DEST" -name "*.html" | wc -l)
IMG_COUNT=$(find "$DEST" \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" -o -name "*.gif" -o -name "*.webp" \) | wc -l)
REPORT_COUNT=$(find "$DEST/reports" -name "index.html" 2>/dev/null | wc -l)
PDF_COUNT=$(find "$DEST" -name "*.pdf" 2>/dev/null | wc -l)
TOTAL_SIZE=$(du -sh "$DEST" 2>/dev/null | cut -f1)

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Archive complete!"
echo "  Location:     ${OUTPUT_DIR}/"
echo "  Total size:   ${TOTAL_SIZE}"
echo "  HTML pages:   ${HTML_COUNT}"
echo "  Images:       ${IMG_COUNT}"
echo "  PDFs:         ${PDF_COUNT}"
echo "  Team reports: ${REPORT_COUNT}"
[[ -n "$COOKIES_FILE" ]] && echo "  Auth pages:   included" || echo "  Auth pages:   NOT included (no cookie file)"
[[ ${#LOGIN_CAPTURES[@]} -gt 0 ]] && echo "  Login captures: ${#LOGIN_CAPTURES[@]} (see warnings above)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "To serve locally:  cd ${OUTPUT_DIR} && python3 -m http.server 8080"
echo "Then open:         http://localhost:8080/${SITE_HOST}/"
