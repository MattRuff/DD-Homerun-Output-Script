# Homerun Presales Data Exporter

Export evaluation data (general info, meeting minutes, call transcripts) from the [Homerun Presales](https://www.homerunpresales.com/) API as Markdown, JSON, plain text, Word, or Google Docs — ready for LLM post-processing, CRM enrichment, or reporting.

> **Looking for unattended automation?** See [`AUTOMATION.md`](./AUTOMATION.md) for the scheduled `docker compose` + `launchd` setup that refreshes JWTs automatically and exports daily into Drive without human interaction.

## Getting Started

Clone the repo first:

```bash
git clone https://github.com/MattRuff/DD-Homerun-Output-Script.git
cd DD-Homerun-Output-Script
```

Then choose Docker (recommended — no Python setup) or run locally with Python.

---

## Option 1: Docker (recommended)

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running
- Chrome with an active Homerun session (just be logged in)

### One-time setup

Build the image from source:

```bash
docker build -t homerun-exporter .
```

> The pre-built Docker Hub image is outdated. Always build from source to get the latest fixes.

### Run it

```bash
# List your active opportunities
DOCKER_IMAGE=homerun-exporter ./docker-run.sh --list

# Export all your active opps (saves to ~/Documents/homerun_output/)
DOCKER_IMAGE=homerun-exporter ./docker-run.sh --all

# Export a single opp by name (exact or partial match)
DOCKER_IMAGE=homerun-exporter ./docker-run.sh "Acme Corp - New Business - Annual - 2026"

# Export a single opp by UUID
DOCKER_IMAGE=homerun-exporter ./docker-run.sh 79f4b70e-183b-4c00-871c-df2c01b0e504

# Filter by tech lead(s)
DOCKER_IMAGE=homerun-exporter ./docker-run.sh --list --team 'Jane Doe' 'John Smith'
DOCKER_IMAGE=homerun-exporter ./docker-run.sh --all --team 'Jane Doe'

# Save output to a custom directory
DOCKER_IMAGE=homerun-exporter ./docker-run.sh --all -o ~/Desktop/homerun_output

# Change output format (md, json, txt, docx)
DOCKER_IMAGE=homerun-exporter ./docker-run.sh --all --type json
```

`docker-run.sh` automatically extracts your Chrome cookies and passes them into the container. Output files are written to your Mac (mounted from the container).

### Manual cookie passing (Docker without docker-run.sh)

If you prefer to pass cookies yourself:

```bash
docker run --rm \
  -e HOMERUN_COOKIES='jwttoken=...; jrtoken=...' \
  -v ~/Documents/homerun_output:/output \
  homerun-exporter --all -o /output
```

---

## Option 2: Run locally with Python

### Prerequisites

- Python 3.10–3.12 (3.13+ is not supported — see note below)
- Chrome with an active Homerun session

### Setup

```bash
python3.12 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### Run it

```bash
source venv/bin/activate

python pull_info_from_opp.py --list
python pull_info_from_opp.py --all
python pull_info_from_opp.py "Acme Corp - New Business - Annual - 2026"
python pull_info_from_opp.py --all --type json
python pull_info_from_opp.py --all --team 'Jane Doe'
```

Output saves to `~/Documents/homerun_output/` by default. Override with `-o`:

```bash
python pull_info_from_opp.py --all -o ~/Desktop/homerun_output
```

> **Python version:** `rookiepy` (used as a fallback for non-macOS) requires Python ≤ 3.12. On macOS the script reads Chrome cookies directly via the Keychain and does not need `rookiepy` at runtime, but the package still needs to install cleanly. If your system Python is 3.13+:
> ```bash
> brew install python@3.12
> python3.12 -m venv venv
> ```

---

## Auth

Auth is **automatic** — the script reads cookies directly from your Chrome session. Just be logged in to Homerun in Chrome before running.

> **If you see an expired JWT error:** open Homerun in Chrome, do a hard refresh (`Cmd+Shift+R`), wait for the page to fully load, then re-run.

### macOS permissions (first-time only)

The script reads Chrome's encrypted cookie database. Two things must be in place:

**1. Full Disk Access for your terminal**

macOS restricts access to `~/Library/Application Support/Google/Chrome/`.

> **System Settings > Privacy & Security > Full Disk Access** — toggle on your terminal app (Terminal, iTerm2, Cursor, VS Code, etc.), then restart it.

**2. Keychain access for "Chrome Safe Storage"**

The first time the script runs, macOS will prompt:

> *"python3 wants to use your confidential information stored in 'Chrome Safe Storage' in your keychain."*

Click **"Always Allow"** (not just "Allow") so it doesn't prompt again.

If you accidentally clicked "Deny":
> Open **Keychain Access** > search `Chrome Safe Storage` > right-click > **Get Info** > **Access Control** tab > add your Python binary or set to "Allow all applications".

### Alternative auth methods

| Method | How |
|--------|-----|
| Environment variable | `export HOMERUN_COOKIES='jwttoken=...; jrtoken=...'` |
| Cookie file | `python pull_info_from_opp.py -f cookies.txt --all` |
| CLI flag | `python pull_info_from_opp.py -c 'jwttoken=...; jrtoken=...' --all` |

### Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `No Homerun cookies in Chrome` | Wrong Chrome profile or not logged in | Log in to Homerun in Chrome, hard refresh (`Cmd+Shift+R`) |
| `RuntimeError: can't find cookies file` | Chrome cookie DB not accessible | Grant **Full Disk Access** to your terminal and restart it |
| `OSError: [Errno 1] Operation not permitted` | Same as above | Grant **Full Disk Access** and restart terminal |
| Keychain prompt keeps appearing | Clicked "Allow" instead of "Always Allow" | Open Keychain Access, find "Chrome Safe Storage", update Access Control |
| `rookiepy` won't install / build error | Python 3.13+ | Use Python 3.12: `brew install python@3.12 && python3.12 -m venv venv` |
| `JWT token expired Xh ago` | Stale session | Hard refresh Homerun in Chrome, wait for page to fully load |

---

## Configure your Homerun instance

By default the script points to the Datadog Homerun instance. To use a different instance, set `HOMERUN_BASE_URL`:

```bash
export HOMERUN_BASE_URL="https://yourcompany.cloud.homerunpresales.com/api/v1"
```

Or edit the `BASE_URL` constant at the top of `pull_info_from_opp.py`.

---

## Usage reference

```
python pull_info_from_opp.py [--list] [--all] [--team NAME ...] [-o DIR]
                              [--type {md,json,txt,docx,gdoc}]
                              [-c COOKIES] [-f FILE] [--debug]
                              [evaluation_uuid_or_name]
```

| Flag | Description |
|------|-------------|
| `--list` | List your active opportunities |
| `--all` | Export all active opportunities (default when no UUID given) |
| `--team NAME ...` | Filter by one or more tech leads |
| `-o DIR` | Output directory (default: `~/Documents/homerun_output/`) |
| `--type` | Output format: `md` (default), `json`, `txt`, `docx`, `gdoc` |
| `-c COOKIES` | Pass cookie string directly |
| `-f FILE` | Read cookies from a file |
| `--debug` | Print extra diagnostic info to stderr |

---

## Output schema

Each exported opportunity contains:

| Field | Description |
|-------|-------------|
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

## License

MIT License. See [LICENSE](LICENSE).
