#!/usr/bin/env bash
# probe-other-files.sh
#
# Probes the live IScorE site as an authenticated user to discover which
# per-team files and pages are visible to all logged-in users (not just
# the owning team).
#
# For each team found in the archived scoreboard it tries:
#   - /reports/team/{report_id}/          (score report page)
#   - /static/upload/docs/*_Team_{N}.pdf  (submitted documents, known patterns)
#
# Anything that responds with real content (not a login page, not 404) is
# saved under the output directory and listed in the summary.
#
# Usage:
#   ./probe-other-files.sh [options]
#
# Options:
#   -u URL    Base URL of the IScorE site     (default: https://iscore.iseage.org)
#   -c FILE   Path to a Netscape-format cookies file (required)
#   -a DIR    Path to local archive directory (default: iscore-YYYY/iscore.iseage.org)
#   -o DIR    Output directory for findings   (default: probe-YYYY)
#   -i        Insecure mode (ignore certificate validation)
#   -t ID     Our own team report ID to skip  (default: 1004)
#   -h        Show this help

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
SITE_URL="https://iscore.iseage.org"
YEAR=$(date +%Y)
ARCHIVE_DIR="iscore-${YEAR}/iscore.iseage.org"
OUTPUT_DIR="probe-${YEAR}"
OUR_REPORT_ID="1004"
COOKIES_FILE=""
INSECURE=false

# ── Argument parsing ───────────────────────────────────────────────────────────
usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
    exit 0
}

while getopts "u:c:a:o:t:ih" opt; do
    case $opt in
        u) SITE_URL="${OPTARG%/}" ;;
        c) COOKIES_FILE="$OPTARG" ;;
        a) ARCHIVE_DIR="$OPTARG" ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        t) OUR_REPORT_ID="$OPTARG" ;;
        i) INSECURE=true ;;
        h) usage ;;
        *) echo "Unknown option: -$OPTARG" >&2; exit 1 ;;
    esac
done

if [[ -z "$COOKIES_FILE" ]]; then
    echo "ERROR: -c FILE is required (Netscape-format cookies from your browser login)." >&2
    echo "See README.md for how to export cookies." >&2
    exit 1
fi
if [[ ! -f "$COOKIES_FILE" ]]; then
    echo "ERROR: Cookie file not found: ${COOKIES_FILE}" >&2
    exit 1
fi

# ── Prerequisites ──────────────────────────────────────────────────────────────
for cmd in curl grep sed; do
    command -v "$cmd" >/dev/null || { echo "ERROR: '$cmd' is required but not found." >&2; exit 1; }
done

SCOREBOARD="${ARCHIVE_DIR}/scoreboard/index.html"
if [[ ! -f "$SCOREBOARD" ]]; then
    echo "ERROR: Archived scoreboard not found at: ${SCOREBOARD}" >&2
    echo "Run scrape-iscore.sh first to build the local archive." >&2
    exit 1
fi

# ── Helpers ────────────────────────────────────────────────────────────────────
log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARNING: $*" >&2; }

CURL_ARGS=( --silent --show-error --location --max-time 10 --cookie "$COOKIES_FILE" )
if [[ "$INSECURE" == "true" ]]; then
    CURL_ARGS+=( --insecure )
fi

# is_login_page FILE  — returns 0 if file looks like an IScorE login redirect
is_login_page() { grep -q '<title>Login' "$1" 2>/dev/null; }

# probe URL OUTFILE LABEL
# Fetches URL as the authenticated user. Saves to OUTFILE and returns:
#   0  real content received (visible to our login)
#   1  got login page (session expired or resource truly restricted)
#   2  HTTP error (404, 403, etc.) or empty response
probe() {
    local url=$1 outfile=$2 label=$3
    mkdir -p "$(dirname "$outfile")"

    local http_code
    http_code=$(curl "${CURL_ARGS[@]}" -w "%{http_code}" -o "$outfile" "$url" 2>/dev/null || echo "000")

    if [[ "$http_code" == "000" ]] || [[ ! -s "$outfile" ]]; then
        rm -f "$outfile"
        return 2
    fi

    if [[ "$http_code" != "200" ]]; then
        rm -f "$outfile"
        return 2
    fi

    if is_login_page "$outfile"; then
        rm -f "$outfile"
        return 1
    fi

    return 0
}

# ── Parse scoreboard: build arrays of report IDs and team numbers ──────────────
# Scoreboard entries look like:
#   reports/team/981/">Team 1: The Phishermen
# We extract both the report ID and the competition team number.
declare -A TEAM_NUM_BY_REPORT   # report_id -> competition team number
declare -A TEAM_NAME_BY_REPORT  # report_id -> display name

while IFS= read -r line; do
    report_id=$(echo "$line" | grep -oP 'reports/team/\K[0-9]+')
    team_num=$(echo  "$line" | grep -oP 'Team \K[0-9]+(?=:)')
    team_name=$(echo "$line" | grep -oP 'Team [0-9]+: \K.*' | sed 's|[<"].*||')
    [[ -n "$report_id" && -n "$team_num" ]] || continue
    TEAM_NUM_BY_REPORT[$report_id]="$team_num"
    TEAM_NAME_BY_REPORT[$report_id]="${team_name:-unknown}"
done < <(grep -oP 'reports/team/[0-9]+[^"]*"[^>]*>[^<]+' "$SCOREBOARD")

TOTAL_TEAMS=${#TEAM_NUM_BY_REPORT[@]}
log "Found ${TOTAL_TEAMS} teams in archived scoreboard."
log "Skipping our own team (report ID: ${OUR_REPORT_ID})."
echo

mkdir -p "$OUTPUT_DIR"

# ── Known document filename patterns ──────────────────────────────────────────
# These are the base names we observed for our team's submissions.
# The server appends _Team_{N} to whatever filename was uploaded, so these
# patterns will only match if other teams used the same base names — but it's
# worth trying.
DOC_PATTERNS=(
    "intrusion-report"
    "intrusion-report-1"
    "intrusion-report-2"
    "intrusion-report-3"
    "green-team-documentation"
    "white-team-documentation"
)

# ── Probe ─────────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Probing as authenticated user"
echo "  Site:    ${SITE_URL}"
echo "  Auth:    ${COOKIES_FILE}"
echo "  Output:  ${OUTPUT_DIR}/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

FOUND_PAGES=()
FOUND_DOCS=()
ACCESS_DENIED=0
NOT_FOUND=0

for report_id in $(echo "${!TEAM_NUM_BY_REPORT[@]}" | tr ' ' '\n' | sort -n); do
    [[ "$report_id" == "$OUR_REPORT_ID" ]] && continue

    team_num="${TEAM_NUM_BY_REPORT[$report_id]}"
    team_name="${TEAM_NAME_BY_REPORT[$report_id]}"
    label="Team ${team_num} (report ${report_id}): ${team_name}"

    # ── Score report page ────────────────────────────────────────────────────
    url="${SITE_URL}/reports/team/${report_id}/"
    outfile="${OUTPUT_DIR}/reports/team/${report_id}/index.html"
    case $(probe "$url" "$outfile" "$label report"; echo $?) in
        0) log "  OPEN   ${url}"
           FOUND_PAGES+=( "$url" ) ;;
        1) log "  DENIED ${url}"
           (( ACCESS_DENIED++ )) || true ;;
        2) log "  404    ${url}"
           (( NOT_FOUND++ )) || true ;;
    esac

    # ── Uploaded documents ───────────────────────────────────────────────────
    for pattern in "${DOC_PATTERNS[@]}"; do
        filename="${pattern}_Team_${team_num}.pdf"
        url="${SITE_URL}/static/upload/docs/${filename}"
        outfile="${OUTPUT_DIR}/static/upload/docs/${filename}"
        case $(probe "$url" "$outfile" "$label doc $pattern"; echo $?) in
            0) # Verify it's actually a PDF
               magic=$(dd if="$outfile" bs=4 count=1 2>/dev/null)
               if [[ "$magic" == "%PDF" ]]; then
                   size=$(wc -c < "$outfile")
                   log "  OPEN   ${url}  (${size} bytes)"
                   FOUND_DOCS+=( "$url" )
               else
                   warn "  Fetched ${url} but content is not a PDF — skipping"
                   rm -f "$outfile"
               fi ;;
            1) : ;;  # auth required for a static file would be unusual; skip quietly
            2) : ;;  # not found; expected for most teams
        esac
    done
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Probe complete"
echo "  Teams probed:        $(( TOTAL_TEAMS - 1 ))"
echo "  Open report pages:   ${#FOUND_PAGES[@]}"
echo "  Open documents:      ${#FOUND_DOCS[@]}"
echo "  Access denied:       ${ACCESS_DENIED}"
echo "  Not found:           ${NOT_FOUND}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ ${#FOUND_PAGES[@]} -gt 0 ]]; then
    echo
    echo "Accessible score report pages:"
    for url in "${FOUND_PAGES[@]}"; do echo "  $url"; done
fi

if [[ ${#FOUND_DOCS[@]} -gt 0 ]]; then
    echo
    echo "Accessible documents:"
    for url in "${FOUND_DOCS[@]}"; do echo "  $url"; done
fi

echo
echo "Saved to: ${OUTPUT_DIR}/"
