# Archiving IScorE Competition Sites

This document explains how to create a reliable offline archive of an IScorE
competition site (iscore.iseage.org) after each competition.

## Prerequisites

```bash
# Ubuntu/Debian
sudo apt install wget curl

# macOS
brew install wget curl
```

## Quick Start

```bash
# Public pages only (no login required)
./scrape-iscore.sh

# With authenticated pages (blue team dashboard, red wiki, etc.)
./scrape-iscore.sh -c cookies.txt
```

Output goes to `iscore-YYYY/` by default. To preview it locally:

```bash
cd iscore-YYYY/iscore.iseage.org/
python3 -m http.server 8080
# open http://localhost:8080/iscore.iseage.org/
# Ctrl-C in the Python window when you want to close the web server.
```

---

## Getting a Cookie File (for Authenticated Pages)

The `/blue/` dashboard, red wiki, messages, and user profile pages require a
login. The script uses a Netscape-format cookies file to authenticate.

### Method 1: Browser extension (recommended)

1. Log in to iscore.iseage.org in your browser
2. Install the **"Get cookies.txt LOCALLY"** extension
   ([Chrome](https://chrome.google.com/webstore/detail/get-cookiestxt-locally/cclelndahbckbenkjhflpdbgdldlbecc) /
   [Firefox](https://addons.mozilla.org/en-US/firefox/addon/cookies-txt/))
3. Click the extension icon while on iscore.iseage.org and export cookies
4. Save the file as `cookies.txt` in this directory
5. Run: `./scrape-iscore.sh -c cookies.txt`

> **Tip:** Do this immediately after the competition ends, before the session
> expires. Cookie files are valid as long as the server-side session is alive.

### Method 2: curl login (may not work if the site uses CSRF tokens)

```bash
# Step 1: Get a session cookie by logging in
curl -c cookies.txt -b cookies.txt \
     -X POST https://iscore.iseage.org/login/ \
     -d "username=YOUR_USERNAME&password=YOUR_PASSWORD" \
     -L --silent --output /dev/null

# Step 2: Verify you're logged in (look for your team name in the response)
curl -b cookies.txt https://iscore.iseage.org/blue/ | grep -o '<title>[^<]*</title>'

# Step 3: Run the scraper
./scrape-iscore.sh -c cookies.txt
```

If step 1 silently fails (redirects back to login), the site requires a CSRF
token and you'll need to use Method 1 instead.

---

## What Gets Captured

| Content | URL | Requires Auth | Notes |
|---------|-----|---------------|-------|
| Scoreboard | `/` and `/scoreboard/` | No | `/scoreboard/` is the AJAX fragment |
| Score Trends | `/statistics/trends/` | No | Full time series, all teams |
| Flag Stats | `/statistics/flag/` | No | |
| Anomaly Stats | `/statistics/anomalies/` | No | |
| Availability | `/statistics/availability/` | No | Uses Google Charts (needs internet to render charts) |
| Service Status | `/services/status/` | No | Snapshot of final state |
| All team reports | `/reports/team/*/` | No | Discovered automatically from scoreboard links |
| Blue team dashboard | `/blue/` | **Yes** | Your team's private view |
| Red wiki | `/red/wiki/` | **Yes** | |
| Messages | `/messages/` | **Yes** | |
| User profile | `/user_profile/` | **Yes** | |
| Flags API | `/api/v1/flags/stats.json` | Maybe | JSON snapshot |
| Anomalies API | `/api/v1/anomalies/stats` | Maybe | JSON snapshot |

### What is NOT captured

- **Live chart rendering** — the Availability page loads Google Charts from an
  external CDN. Charts render if you have internet access; the underlying data
  is still saved in the page's JavaScript.
- **Pages behind the Red team login** — if red team pages use different
  credentials than blue team, a separate cookie file would be needed.

---

## Script Options

```
./scrape-iscore.sh [options]

  -u URL    Base URL of the IScorE site  (default: https://iscore.iseage.org)
  -c FILE   Path to cookies file         (default: none, public pages only)
  -o DIR    Output directory             (default: iscore-YYYY)
  -w N      Seconds to wait between requests (default: 1)
  -h        Show help
```

### Examples

```bash
# Archive to a custom directory
./scrape-iscore.sh -c cookies.txt -o 2026-competition

# Archive a different year's site
./scrape-iscore.sh -u https://iscore.iseage.org -c cookies.txt -o iscore-2026

# Faster (less polite) — only if you're confident the server can handle it
./scrape-iscore.sh -c cookies.txt -w 0
```

---

## Hosting the Archive

### At a domain root (simplest)

Because the script uses `--convert-links`, all links in the archive are
**relative**. The archive works correctly whether it's served from:
- `https://2026.highschoolhackers.com/` (root)
- `https://www.highschoolhackers.com/2026/` (subdirectory)

No path editing needed in either case.

### Copying to a web server

```bash
# The content to serve is inside the site hostname subdirectory
rsync -av iscore-2026/iscore.iseage.org/ user@server:/var/www/html/2026/
```

---

## Lessons Learned (Why This Approach)

### The link-rewriting problem

**Browser "Save Page As"** leaves absolute, root-relative links in the HTML:
```html
<link href="/static/CACHE/css/output.css">
<a href="/statistics/trends/">
```
These break when hosted in a subdirectory because `/static/` resolves to the
domain root, not the subdirectory.

**HTTrack** and **wget with `--convert-links`** both rewrite links to relative
paths:
```html
<link href="../../static/CACHE/css/output.css">
<a href="../../statistics/trends/index.html">
```
These work anywhere. The script uses wget with `--convert-links`.

### The AJAX fragment problem

The scoreboard at `/scoreboard/` is loaded by JavaScript from the main page —
it's never a normal HTML link, so a naive site spider never visits it.
**This fragment contains all the team report links.**

The script seeds wget explicitly with `/scoreboard/` so wget discovers and
fetches all team report pages automatically.

### The live-update problem

Three pages continuously update themselves during the competition:

| Page | Behavior |
|------|----------|
| Service Status | Full page reload every 20 seconds |
| Flag Stats | API poll every 15 seconds |
| Anomaly Stats | API poll every 60 seconds |

The script strips these intervals from the saved HTML so the archive doesn't
make pointless requests to a server that may no longer be running.

---

## Year-to-Year Notes

Things that may change between competitions and may need updating:

- **Site URL** — always `https://iscore.iseage.org` so far, but use `-u` if it
  changes
- **Authenticated page paths** — if the blue/red team sections move, update
  `SEED_URLS` in the script
- **API endpoints** — `/api/v1/flags/stats.json` and `/api/v1/anomalies/stats`
  may change; check the page source if the API snapshots are empty
- **Live-update patterns** — the `sed` patterns in Phase 3 are based on the
  2025/2026 site's JavaScript; if the site is rebuilt they may need updating.
  Check by searching the saved HTML for `setInterval`.
- **Google Charts dependency** — the Availability page switched from a locally
  bundled charting library (Flot, 2025) to Google Charts (2026). If it switches
  back or to another CDN library, offline rendering behavior will change.
