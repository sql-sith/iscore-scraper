# IScorE Scraper — Claude Context

This repo archives competition results from iscore.iseage.org after each CDC event. The
primary audience is high school cyber defense teams who want an offline, browseable copy of
their scoreboard, anomaly history, and submission records.

## Key Files

- `scrape-iscore.sh` — five-phase archive script (see below)
- `probe-other-files.sh` — probes other teams' artifacts visible to a logged-in user
- `README.md` — instructions for running the scraper and hosting the output
- `output/` — competition archives and probe results, organized by year and event

## Archive Folder Convention

All output lives under `output/`, split by year and tool:

```
output/YYYY/iscore/NN-competition-name/iscore.iseage.org/   # scrape-iscore.sh
output/YYYY/probe/NN-competition-name/{reports,static}/     # probe-other-files.sh
```

`NN` is a two-digit sequence number within the year (02, 04, …). Examples:
- `output/2026/iscore/02-international-cdc/iscore.iseage.org/`
- `output/2026/iscore/04-highschool-cdc/iscore.iseage.org/`
- `output/2026/probe/02-international-cdc/`
- `output/2026/probe/04-highschool-cdc/`

Always confirm the target folder, team number, and report ID with the user before running.

## Scrape Workflow

`scrape-iscore.sh` takes these key flags:

```bash
./scrape-iscore.sh -c cookies.txt -o output/YYYY/iscore/NN-name -r REPORT_ID
```

| Flag | Purpose |
|------|---------|
| `-c` | Netscape-format cookie file (required for authenticated pages) |
| `-o` | Output directory — site goes into `<dir>/iscore.iseage.org/` |
| `-r` | Team score report ID (appears in `/reports/team/{id}/`) |
| `-n` | Non-interactive: skip cookie re-prompt (use for background runs) |
| `-i` | Skip TLS certificate checks |

### The Five Phases

1. **wget mirror** — bulk crawl with `--convert-links` (rewrites absolute hrefs to relative)
2. **curl fetches** — anomaly detail pages, submission pages, other team reports, API snapshots, timezone data; all missed by wget's link-follower
3. **Post-processing** — fix AJAX URL, timezone base path, strip live-update intervals, apply `fix_page()` to all curl-fetched pages
4. **Validation** — flag any authenticated pages that were saved as the login page
5. **Inventory** — count and summarize what was captured

## Cookie Handling

- Export Netscape-format cookies from the browser using "Get cookies.txt LOCALLY"
- Sessions expire; a long wget crawl (10+ minutes) can exhaust a fresh session
- The script prompts for cookie refresh interactively (-n suppresses this)
- If running in background with -n, re-fetch any session-expired pages afterward
- **When errors appear in authenticated sections, suspect session expiry first.** A stale
  session produces login-page captures that look like success and curl fetches that silently
  return login HTML. Refresh cookies and retry before investigating other causes.

## Known YoY Variability

The script is reliable for the patterns established in 2025–2026, but the IScorE site
changes between competitions. Things to watch for:

- **Dashboard anomaly links** — In 2026 (International CDC) the dashboard listed anomalies
  as individual dropdown messages linking to `/goto_message/{id}/`. By 2026 (Highschool CDC)
  this had changed to a single "view all anomalies" link. Phase 2c reads from
  `blue/anomalies/index.html` directly, so it handles both layouts correctly.
- **wget exit code 8** — The server returns 404 for Bootstrap Glyphicon fonts. With
  `set -euo pipefail`, this kills the script before Phases 2–5 run. The fix is already in
  the script (exit code 8 is tolerated); watch for similar issues with other missing assets.
- **Submission document paths** — After `fix_page()` rewrites absolute paths to relative,
  the grep pattern for uploaded docs must match `upload/docs/` without a leading slash.
  The script has the correct `sed 's|.*upload/docs/|...'` pattern as of 2026.
- **Session expiry scope** — `red/flag/earnback`, `red/flag/capture`, `red/flag/plant`, and
  `red/index.html` will always appear as login captures when using a blue-team account.
  These are permission denials, not session expiry — don't re-fetch them.
- **API endpoints** — `/api/v1/anomalies/stats` was not available for the 2026 Highschool
  CDC. The script warns and continues; this is normal.

## Team Info (update each competition)

| Competition | Team # | Report ID | Folder |
|------------|--------|-----------|--------|
| International CDC 2026 | 24 | 1004 | `output/2026/iscore/02-international-cdc` |
| Highschool CDC 2026 | 9 | 1071 | `output/2026/iscore/04-highschool-cdc` |

Login: `sky.kaptin` — refresh cookies from browser before each run.

## Serving Locally

```bash
cd output/2026/iscore/04-highschool-cdc && python3 -m http.server 8080
# open http://localhost:8080/iscore.iseage.org/
```
