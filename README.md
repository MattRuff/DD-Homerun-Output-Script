# Homerun Presales Data Exporter

Export evaluation data (general info, meeting minutes, call transcripts) from the [Homerun Presales](https://www.homerunpresales.com/) API as Markdown, JSON, plain text, Word, or Google Docs — ready for LLM post-processing, CRM enrichment, or reporting.

Two ways to run it:

| Path | What you get | When to use |
|---|---|---|
| **Unattended (recommended)** | Daily Markdown drop into a Drive-synced folder, JWTs refreshed automatically, no human in the loop | Set-and-forget pipelines feeding LLM agents, dashboards, or CRMs |
| **Ad-hoc** | Run one export right now from the terminal | Debugging, one-off lookups, custom flags, or trying the project for the first time |

For the deep-dive on the unattended pipeline (architecture, fallback flows, container internals), see [`AUTOMATION.md`](./AUTOMATION.md).

---

## Quickstart — Unattended daily export (Docker + `launchd`)

Result: a fresh Markdown export of every active opportunity lands in `~/Google Drive/My Drive/SE Brain/homerun-output/` every morning at 09:30, with no terminal interaction.

### Prerequisites

- macOS (the schedule uses `launchd`; the auth harness's `applescript` and `rookiepy` strategies are macOS-only)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) running
- Chrome with an active Homerun session (just need to be logged in **once** for bootstrap — after that, the long-lived `jrtoken` keeps the system rolling forever)

### Setup (3 steps, one time)

```bash
# 1. Clone and enter the repo
git clone https://github.com/MattRuff/DD-Homerun-Output-Script.git
cd DD-Homerun-Output-Script

# 2. Build the container and install the launchd job (default 09:30 daily)
docker compose build
./scripts/install-launchd.sh

# 3. Kick off a run right now to verify everything works
#    (also seeds ~/.homerun/cookies.txt from your live Chrome session on first run)
./scripts/run_export.sh
```

After step 3, Markdown files should appear in `~/Google Drive/My Drive/SE Brain/homerun-output/`. The next scheduled run is at 09:30 the following morning.

> **Verify the schedule is loaded:** `launchctl list | grep com.homerun.export.daily` should print a line with the label and an exit code.

### Customizing the schedule or output path

```bash
# Different schedule — re-run the installer with HH MM:
./scripts/install-launchd.sh 7 30      # 07:30 daily
./scripts/install-launchd.sh 18 0      # 18:00 daily
./scripts/install-launchd.sh --uninstall   # remove the job entirely

# Output goes somewhere else — set this once in ~/.homerun/env (mode 0600):
mkdir -p ~/.homerun && chmod 700 ~/.homerun
cat > ~/.homerun/env <<'EOF'
HOMERUN_OUTPUT_HOST_DIR="$HOME/Documents/homerun_output"
EOF
chmod 0600 ~/.homerun/env
```

### Failure notifications

| Channel | Default | How to enable |
|---|---|---|
| **macOS notification banner** | Active | Make sure Script Editor has notification permission in *System Settings → Notifications* |
| **Failure log** | Active | Tail `output/export.log` — every error lands there with a stack trace |
| **Slack alert** | Off | Add `SLACK_BOT_TOKEN=xoxb-...` and `SLACK_CHANNEL_ID=C0...` to `~/.homerun/env` (mode 0600) |

---

## Quickstart — Ad-hoc / one-off export

For "I want a single export right now" use cases.

### With Docker (recommended)

```bash
docker pull matthewruyffelaert667/homerun-ddog-scripts:latest
# (or build locally: docker build -t homerun-exporter .)

# docker-run.sh extracts your live Chrome cookies and passes them in:
./docker-run.sh --list                                        # list active opps
./docker-run.sh --all                                         # export everything
./docker-run.sh "Acme Corp - New Business - Annual - 2026"    # by name (partial match ok)
./docker-run.sh 79f4b70e-183b-4c00-871c-df2c01b0e504           # by UUID
./docker-run.sh --all --team 'Jane Doe' 'John Smith'          # filter by tech lead
./docker-run.sh --all -o ~/Desktop/homerun_output             # custom output dir
./docker-run.sh --all --type json                             # md (default), json, txt, docx, gdoc
```

Pass cookies manually if you don't want `docker-run.sh` to auto-detect:

```bash
docker run --rm \
  -e HOMERUN_COOKIES='jwttoken=...; jrtoken=...' \
  -v "$HOME/Documents/homerun_output:/output" \
  matthewruyffelaert667/homerun-ddog-scripts:latest --all -o /output
```

### Local Python (no Docker)

```bash
python3.12 -m venv venv && source venv/bin/activate
pip install -r requirements.txt

python pull_info_from_opp.py --list
python pull_info_from_opp.py --all
python pull_info_from_opp.py "Acme Corp - New Business - Annual - 2026"
python pull_info_from_opp.py --all --type json --team 'Jane Doe'
```

> **Python version:** `rookiepy` requires Python 3.10–3.12. If your default is 3.13+: `brew install python@3.12 && python3.12 -m venv venv`.

---

## Auth — how it actually works

Auth is a **harness of four strategies** that the wrapper tries in order. The first one that returns a JWT with at least 600 seconds of remaining TTL wins. Persisted state lives in `~/.homerun/cookies.txt` (mode 0600).

| Strategy | What it does | Works when |
|---|---|---|
| `refresh_token` ⭐ **primary** | POSTs the long-lived `jrtoken` to `/api/v1/jwt/refresh` and gets a new JWT — pure HTTP, no browser | Always, including in containers, with Chrome closed, Mac locked |
| `playwright` | Drives a headless Chromium with persisted `storage_state.json` | Headless environments where you've run `python -m auth bootstrap-playwright` once |
| `applescript` | Uses `osascript` to ask Chrome to reload Homerun, then re-reads cookies | macOS host with Chrome running |
| `rookiepy` | Reads Chrome's cookie database directly via the macOS Keychain | macOS host with Chrome's cookie DB readable |

Inspect what's working on your machine:

```bash
python -m auth benchmark
# strategy       ok   elapsed_s   jwt_ttl_s  error
# refresh_token  yes        0.2         714
# playwright     no         0.0              storage state not found …
# applescript    no         0.0              applescript strategy only works on macOS
# rookiepy       yes        0.1         714
```

The unattended pipeline only relies on `refresh_token` after the first bootstrap, which is why it can keep running with Chrome closed and your Mac locked. See [`AUTOMATION.md`](./AUTOMATION.md) for the full architecture.

### Manual cookie passing (override auth entirely)

```bash
export HOMERUN_COOKIES='jwttoken=...; jrtoken=...'
python pull_info_from_opp.py --all
# or:
python pull_info_from_opp.py -c 'jwttoken=...; jrtoken=...' --all
python pull_info_from_opp.py -f cookies.txt --all
```

### macOS permissions (first-time only, host runs)

The host-side strategies (`rookiepy`, `applescript`) read Chrome's encrypted cookie database. Two grants are needed once:

1. **Full Disk Access** for your terminal — *System Settings → Privacy & Security → Full Disk Access* → toggle on Terminal/iTerm/Cursor/etc., then restart it.
2. **Keychain access** — the first run prompts *"python3 wants to use your confidential information stored in 'Chrome Safe Storage'"*. Click **"Always Allow"**.

Container runs don't need either of these; the container only does HTTP and never touches Chrome.

---

## Configuration

Most settings have sensible defaults. Override via env vars or `~/.homerun/env` (sourced by the wrapper, mode 0600).

| Variable | Default | What it controls |
|---|---|---|
| `HOMERUN_BASE_URL` | `https://datadog.cloud.homerunpresales.com/api/v1` | Homerun instance — change for non-Datadog tenants |
| `HOMERUN_OUTPUT_HOST_DIR` | `~/Google Drive/My Drive/SE Brain/homerun-output` | Where the unattended export lands on the host |
| `HOMERUN_AUTH_PRIORITY` | `refresh_token,playwright,applescript,rookiepy` | Comma-separated strategy order |
| `HOMERUN_MIN_TTL` | `600` | Reject JWTs with less than this many seconds left |
| `HOMERUN_EXPORT_TYPE` | `md` | `md`, `json`, `txt`, `docx`, `gdoc` |
| `HOMERUN_EXPORT_ARGS` | `--all` | Extra flags passed to `pull_info_from_opp.py` |
| `HOMERUN_RUN_MODE` | `auto` | `auto` (Docker if available, else host), `docker` (force), `host` (force) |
| `HOMERUN_LOG` | `<repo>/output/export.log` | Wrapper log file |
| `SLACK_BOT_TOKEN` / `SLACK_CHANNEL_ID` | unset | Enable Slack failure alerts |

### Updating to a new release

```bash
cd DD-Homerun-Output-Script
git pull
docker compose build       # rebuild local image with new code
# launchd picks up the new wrapper automatically — no plist reload needed
```

---

## Best practices

- **Lock down secrets**: `~/.homerun/cookies.txt` and `~/.homerun/env` should both be `chmod 0600`. The container mounts `~/.homerun` as `/state` — anyone with the host file has full access to your Homerun session.
- **Don't share `cookies.txt`**: it contains an active `jrtoken` that's effectively a long-lived API key. Rotate it by logging out of Homerun in Chrome (which invalidates the token), then re-bootstrapping.
- **Drive sync awareness**: if Drive is paused or in conflict, exports will land on disk but won't sync. Check `~/Google Drive/.../homerun-output/` directly if files seem missing in Drive web UI.
- **Sleep / power**: `launchd` will fire the next missed schedule when the Mac wakes (default behavior). For zero gaps, consider keeping the Mac plugged in and disabling sleep during the 09:30 window.
- **Watch the log**: `tail -F output/export.log` during business hours surfaces any silent regressions. Slack alerts are the most reliable channel for unattended monitoring.
- **Pin a version in production**: pull a specific tag (`matthewruyffelaert667/homerun-ddog-scripts:v1.2.0`) instead of `:latest` if you want bit-exact reproducibility across runs.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `[container] ERROR: /state/cookies.txt missing or empty` | First run before bootstrap | `python -m auth fetch --priority refresh_token,rookiepy` (or just run the wrapper — it bootstraps on first run) |
| `auth fetch failed` inside container, `refresh_token` only strategy | `jrtoken` is invalidated (logged out, password reset, etc.) | Re-bootstrap from a fresh Chrome session: `python -m auth fetch --priority refresh_token,rookiepy --verbose` |
| `RuntimeError: can't find cookies file` (host) | Chrome's cookie DB not accessible | Grant **Full Disk Access** to your terminal in System Settings, then restart it |
| Keychain prompt repeats every run | You clicked "Allow" instead of "Always Allow" | Open Keychain Access → search `Chrome Safe Storage` → right-click → Get Info → Access Control → add your Python binary |
| `JWT token expired Xh ago` (host, no harness) | Stale Chrome session | Either run via the harness (`python -m auth fetch`) or hard-refresh Homerun in Chrome (`Cmd+Shift+R`) |
| `rookiepy` won't install / build error | Python 3.13+ | Use Python 3.12: `brew install python@3.12 && python3.12 -m venv venv` |
| No notification on failure | Focus mode / DND, or Script Editor lacks permission | *System Settings → Notifications → Script Editor* — set to allow banners |
| `docker compose run failed` then *"falling back to host mode"* | Docker daemon down, or image not built | `docker compose build` (rebuild), or `open -a Docker` (start daemon) |
| Files not appearing in Drive | Drive sync paused or in conflict | Open Drive Desktop, click the icon in the menu bar, check sync status |
| `applescript only works on macOS` | Container or Linux host | Expected — that strategy is host-only; `refresh_token` should still succeed |

---

## Configure your Homerun instance

By default the script points to the Datadog Homerun instance. To use a different tenant:

```bash
export HOMERUN_BASE_URL="https://yourcompany.cloud.homerunpresales.com/api/v1"
```

Or set it permanently in `~/.homerun/env`. For the container, override at run time:

```bash
HOMERUN_BASE_URL=https://yourcompany.cloud.homerunpresales.com/api/v1 \
  docker compose run --rm exporter scheduled
```

---

## CLI reference

```
python pull_info_from_opp.py [--list] [--all] [--team NAME ...] [-o DIR]
                              [--type {md,json,txt,docx,gdoc}]
                              [-c COOKIES] [-f FILE] [--credentials FILE]
                              [--debug]
                              [evaluation_uuid_or_name]
```

| Flag | Description |
|---|---|
| `--list` | List your active opportunities |
| `--all` | Export all active opportunities (default when no UUID given) |
| `--team NAME ...` | Filter by one or more tech leads |
| `-o DIR` | Output directory (default: `~/Documents/homerun_output/`; container default: `/output`) |
| `--type` | Output format: `md` (default), `json`, `txt`, `docx`, `gdoc` |
| `-c COOKIES` | Pass cookie string directly |
| `-f FILE` | Read cookies from a file |
| `--credentials FILE` | Path to Google OAuth `credentials.json` (for `--type gdoc`) |
| `--debug` | Print extra diagnostic info to stderr |

Auth harness CLI:

```
python -m auth fetch              [--priority STRATEGIES] [--min-ttl SECONDS] [--verbose]
python -m auth benchmark          [--min-ttl SECONDS]
python -m auth bootstrap-playwright   # interactive: log in once, persist storage_state.json
python -m auth discover-refresh   # probe candidate refresh endpoints
```

---

## Output schema

Each exported opportunity contains:

| Field | Description |
|---|---|
| `Opportunity_ID` | Salesforce opportunity ID |
| `Opportunity_Name` | Full opportunity name |
| `Customer`, `Type`, `Term`, `Year` | Parsed from the opportunity name |
| `Stage`, `Deal_Size`, `SE`, `SR` | Current stage, deal size, SE/SR owners |
| `Sentiment`, `Tech_Win`, `Deal_Win` | Evaluation outcomes |
| `Current_Status` | Parsed status entries with dates and authors |
| `Next_Steps` | AE/CSM and SE next steps fields |
| `Meeting_Minutes` | Array of meeting notes (date, title, summary) |
| `Transcripts` | Array of meetings, each with a `meeting` name and `segments` array (speaker, timestamp, text) |

---

## Customization

- **`KNOWN_USERS`** — optional cache of `"display name" → UUID` mappings for `--team` lookups. Avoids an API call for names listed here. Falls back to the API for any name not found.
- **`SALESFORCE_STAGES_1_5`** — stage filter values used by `--team` / `stage_filter="active"` mode. Adjust if your Homerun instance uses different stage names.

---

## Repository layout

```
homerun-presales-exporter/
├── pull_info_from_opp.py        # Core exporter
├── auth/                        # Multi-strategy auth harness
│   ├── strategy_refresh_token.py    (primary — pure HTTP)
│   ├── strategy_playwright.py
│   ├── strategy_applescript.py
│   └── strategy_rookiepy.py
├── scripts/
│   ├── entrypoint.sh            # Container entrypoint (scheduled / auth / legacy)
│   ├── run_export.sh            # launchd cron wrapper (Docker → host fallback)
│   ├── install-launchd.sh       # Install / uninstall the daily launchd job
│   └── test_auth_methods.py     # Diagnostic helper
├── docker-compose.yml           # Volume mounts + env knobs for the unattended path
├── docker-run.sh                # Ad-hoc Docker wrapper (auto-extracts Chrome cookies)
├── docker-push.sh               # Build + push to Docker Hub
├── Dockerfile
├── AUTOMATION.md                # Deep-dive on the unattended pipeline
└── README.md                    # ← you are here
```

---

## License

MIT License. See [LICENSE](LICENSE).
