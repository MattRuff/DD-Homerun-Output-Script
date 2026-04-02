# Homerun Presales Data Exporter

Export evaluation data (general info, meeting minutes, call transcripts) from the [Homerun Presales](https://www.homerunpresales.com/) API as structured JSON or plain text — ready for LLM post-processing, CRM enrichment, or reporting.

## Setup

**Requirements:** Python 3.10+ and a Homerun Presales account.

```bash
pip install -r requirements.txt
```

**Configure your instance** by setting `HOMERUN_BASE_URL`:

```bash
export HOMERUN_BASE_URL="https://yourcompany.cloud.homerunpresales.com/api/v1"
```

Or edit the `BASE_URL` default at the top of `pull_info_from_opp.py`.

## Auth

Auth is **automatic** — the script reads cookies from your Chrome session via [rookiepy](https://github.com/nicholaschiasson/rookiepy). Just be logged in to Homerun in Chrome.

> **Note:** rookiepy requires Python <= 3.12 (it does not yet compile on 3.13+). If your default Python is newer, create a venv with an older version:
> ```bash
> python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt
> ```

**Alternatives** (if you can't use rookiepy):

| Method | Flag |
|--------|------|
| Cookie file | `-f cookies.txt` |
| Environment variable | `export HOMERUN_COOKIES="name=value; ..."` |
| CLI argument | `-c "name=value; ..."` |

The script validates JWT expiry **before** making API calls and gives a clear error message if cookies are stale.

## Usage

```bash
# List your active opportunities
python pull_info_from_opp.py --list

# Export all your active opps to output/ (default)
python pull_info_from_opp.py --all

# Export a single opp by UUID
python pull_info_from_opp.py 79f4b70e-183b-4c00-871c-df2c01b0e504

# Export a single opp by name (exact or partial match)
python pull_info_from_opp.py "Acme Corp - New Business - Annual - 2026"

# Filter by tech lead(s)
python pull_info_from_opp.py --list --team 'Jane Doe' 'John Smith'
python pull_info_from_opp.py --all --team 'Jane Doe'

# Write to a specific directory
python pull_info_from_opp.py --all -o /path/to/output

# Plain text instead of JSON
python pull_info_from_opp.py --all --type txt

# Write single opp to a file
python pull_info_from_opp.py "Acme Corp" -P prompt.json
```

When looking up by name, the script first searches your own opportunities, then falls back to searching all opportunities across all tech leads.

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

## Docker

A Docker image is available at `matthewruyffelaert667/homerun-ddog-scripts`.

The easiest way to run it is with the **`docker-run.sh`** wrapper, which automatically extracts fresh cookies from your local Chrome and passes them to the container:

```bash
./docker-run.sh --all
./docker-run.sh --list
./docker-run.sh "Acme Corp - New Business - Annual - 2026"
```

Requires `rookiepy` installed on the host (`pip install rookiepy`). Override the Python binary with `HOMERUN_PYTHON` if your rookiepy lives in a venv:

```bash
HOMERUN_PYTHON=.venv/bin/python ./docker-run.sh --all
```

**Manual cookie passing** (no rookiepy on host):

```bash
docker run --rm -e HOMERUN_COOKIES='jwttoken=...; jrtoken=...' \
  matthewruyffelaert667/homerun-ddog-scripts --all

docker run --rm matthewruyffelaert667/homerun-ddog-scripts \
  --cookies 'jwttoken=...; jrtoken=...' --all
```

## License

MIT License. See [LICENSE](LICENSE).
