# Homerun Presales Data Exporter

Export evaluation data (general info, meeting minutes, call transcripts) from the [Homerun Presales](https://www.homerunpresales.com/) API as structured JSON or plain text — ready for LLM post-processing, CRM enrichment, or reporting.

## Quick Start (Docker — recommended)

The fastest way to get running. No Python install or dependency management needed.

```bash
docker pull matthewruyffelaert667/homerun-ddog-scripts
```

### Using `docker-run.sh` (automatic auth)

The included wrapper script extracts fresh cookies from your local Chrome session and passes them to the container — no manual cookie handling:

```bash
./docker-run.sh --all
./docker-run.sh --list
./docker-run.sh "Acme Corp - New Business - Annual - 2026"
```

Requires `rookiepy` on the host. If it's in a venv, point to it:

```bash
pip install rookiepy                          # one-time setup
HOMERUN_PYTHON=.venv/bin/python ./docker-run.sh --all  # if rookiepy is in a venv
```

### Manual cookie passing

If you don't have rookiepy on the host, pass cookies directly:

```bash
docker run --rm -e HOMERUN_COOKIES='jwttoken=...; jrtoken=...' \
  matthewruyffelaert667/homerun-ddog-scripts --all

docker run --rm matthewruyffelaert667/homerun-ddog-scripts \
  --cookies 'jwttoken=...; jrtoken=...' --all
```

## Auth

Auth is **automatic** when using `docker-run.sh` or running locally with [rookiepy](https://github.com/nicholaschiasson/rookiepy) — just be logged in to Homerun in Chrome.

> **Tip:** If the script reports an expired JWT, do a hard refresh in Chrome (`Cmd+Shift+R`), wait for the page to fully load, then re-run.

**Alternative auth methods:**

| Method | Flag |
|--------|------|
| Environment variable | `HOMERUN_COOKIES="name=value; ..."` |
| Cookie file | `-f cookies.txt` |
| CLI argument | `-c "name=value; ..."` |

## Usage

All examples below work with both `docker-run.sh` and direct Python. Replace `./docker-run.sh` with `python pull_info_from_opp.py` if running locally.

```bash
# List your active opportunities
./docker-run.sh --list

# Export all your active opps (default)
./docker-run.sh --all

# Export a single opp by UUID
./docker-run.sh 79f4b70e-183b-4c00-871c-df2c01b0e504

# Export a single opp by name (exact or partial match)
./docker-run.sh "Acme Corp - New Business - Annual - 2026"

# Filter by tech lead(s)
./docker-run.sh --list --team 'Jane Doe' 'John Smith'
./docker-run.sh --all --team 'Jane Doe'

# Write to a specific directory (mounted from host)
docker run --rm -v ~/output:/output -e HOMERUN_COOKIES='...' \
  matthewruyffelaert667/homerun-ddog-scripts --all -o /output

# Plain text instead of JSON
./docker-run.sh --all --type txt

# Write single opp to a file
./docker-run.sh "Acme Corp" -P prompt.json
```

When looking up by name, the script first searches your own opportunities, then falls back to searching all opportunities across all tech leads.

## Local Setup (alternative)

If you prefer running without Docker:

**Requirements:** Python 3.10+ (rookiepy needs <= 3.12) and a Homerun Presales account.

```bash
python3.12 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python pull_info_from_opp.py --all
```

**Configure your instance** by setting `HOMERUN_BASE_URL`:

```bash
export HOMERUN_BASE_URL="https://yourcompany.cloud.homerunpresales.com/api/v1"
```

Or edit the `BASE_URL` default at the top of `pull_info_from_opp.py`.

## Output Schema (JSON)

Each exported opportunity contains:

| Field | Description |
|-------|-------------|
| `Opportunity_ID` | Salesforce opportunity ID |
| `Opportunity_Name` | Full opportunity name |
| `Customer`, `Type`, `Term`, `Year` | Parsed from the opportunity name |
| `Stage`, `Deal_Size`, `SE`, `SR` | Current stage, deal size, SE/SR owners |
| `Sentiment`, `Tech_Win`, `Deal_Win` | Evaluation outcomes |
| `Current_Status` | Parsed status entries with dates and authors |
| `Meeting_Minutes` | Array of meeting notes (date, title, summary) |
| `Transcripts` | Array of transcript segments (meeting, speaker, timestamp, text) |

## Customization

- **`KNOWN_USERS`**: Optional cache of display-name → UUID mappings for `--team` lookups. Avoids an API call for known names. Falls back to the API for any name not listed.
- **`SALESFORCE_STAGES_1_5`**: Stage filter values for the `--team` / `stage_filter="active"` mode. Adjust if your Homerun instance uses different stage names.

## License

MIT License. See [LICENSE](LICENSE).
