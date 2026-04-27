# Zero-touch automation for the Homerun exporter

This guide covers how the daily Markdown export at 09:30 runs unattended and
what to do when it stops working.

## Why this is hard

Homerun issues **very** short-lived JWTs (verified TTL: ~15 min). A fresh one
is minted only by exchanging the longer-lived `jrtoken` against the API.
`rookiepy` reads Chrome's cookie DB but never triggers that exchange, so any
unattended run that relies on rookiepy alone fails the moment the JWT in
Chrome's DB goes stale (which is *every* time Chrome's been idle for >15 min).

The harness below tries multiple strategies in priority order until one
returns a cookie string with a fresh JWT.

### What works (verified 2026-04-27)

- Endpoint: `POST https://datadog.cloud.homerunpresales.com/api/v1/jwt/refresh`
- Required: `Cookie: jrtoken=...` (an expired or absent `jwttoken` is fine).
- CSRF/`x-xsrf-token` is **not** required.
- Response: `Set-Cookie: jwttoken=<fresh JWT>; Path=/api/v1; HttpOnly; Secure`,
  TTL ~15 min from issue.
- Round-trip latency from this Mac: ~0.1 s.

`refresh_token` is therefore the primary strategy and runs without a browser.

## Components

| File | Purpose |
| --- | --- |
| `auth/__init__.py` | Public API: `get_fresh_cookies(...)` and `run_strategy(...)` |
| `auth/jwt_utils.py` | JWT parsing helpers (no I/O) |
| `auth/strategy_rookiepy.py` | Read cookies straight from Chrome (baseline; cannot refresh; host-only) |
| `auth/strategy_playwright.py` | Drive headless Chromium with persisted `storage_state.json` |
| `auth/strategy_refresh_token.py` | Pure-HTTP exchange against Homerun's refresh endpoint (works in container) |
| `auth/strategy_applescript.py` | Ask Chrome (via `osascript`) to reload Homerun, then rookiepy (host-only) |
| `auth/__main__.py` | CLI: `fetch`, `bootstrap-playwright`, `discover-refresh`, `benchmark` |
| `scripts/test_auth_methods.py` | Convenience wrapper around `python -m auth benchmark` |
| `scripts/run_export.sh` | Cron/launchd wrapper: docker compose run (preferred) or host fallback |
| `scripts/entrypoint.sh` | Container entrypoint dispatcher (legacy / scheduled / auth modes) |
| `Dockerfile` | Image definition: python 3.12-slim + tini + auth harness + exporter |
| `docker-compose.yml` | One-line launcher with `~/.homerun` and `~/Google Drive/My Drive/SE Brain/homerun-output` mounted |
| `com.homerun.export.daily.plist` | macOS launchd schedule (09:30 daily) |

## Strategies

Default priority order (best -> worst for unattended use):

1. **refresh_token** — pure HTTP against `/api/v1/jwt/refresh`, ~0.1 s,
   no browser. Self-seeds from `~/.homerun/cookies.txt` if present, otherwise
   bootstraps once from `rookiepy` and persists the result. After the first
   successful run the daily job is **completely independent** of Chrome:
   it works with Chrome closed, the Mac locked, or even with FileVault holding
   the user keychain (verified 2026-04-27 by simulating a broken rookiepy).
2. **playwright** — runs a real browser, gets a brand-new JWT, works as long
   as the saved storage state's refresh token is still valid. Optional
   fallback; not required.
3. **applescript** — asks Chrome to reload the app, then reads cookies. Needs
   the Mac unlocked and Chrome running. Note: Homerun only mints a new JWT
   when the existing one is near expiry, so this strategy can return stale
   cookies if invoked early.
4. **rookiepy** — last resort; no refresh, just snapshots whatever Chrome has.

The harness skips strategies whose dependencies are missing so a missing
Playwright install just falls through to the next option.

### Resilience model

- Daily refresh persists `~/.homerun/cookies.txt` (mode 0600) on every run.
- `jrtoken` is long-lived; in practice each refresh issues a new `jwttoken`
  while keeping the same `jrtoken`. The persisted file is therefore enough to
  keep the cron alive indefinitely.
- If `~/.homerun/cookies.txt` is missing or the `jrtoken` it holds is rejected,
  the strategy auto-falls-back to `rookiepy` to re-seed (this is why the very
  first invocation requires you to be logged in to Homerun in Chrome once).

## Failure notifications

`run_export.sh` always emits a native macOS notification on any failure. To
also get a Slack alert, drop a `~/.homerun/env` file (mode `0600`) with::

    SLACK_BOT_TOKEN=xoxb-...
    SLACK_CHANNEL_ID=C0AP0P1RU13
    # optional, once you've sniffed it via `python -m auth discover-refresh`
    HOMERUN_REFRESH_PATH=authenticate/refresh

The wrapper sources that file on every run, so launchd (which doesn't inherit
your shell env) picks the values up automatically.

## How it runs (containerized, default)

The whole pipeline is packaged in a small Python 3.12-slim image
(`homerun-exporter:local`) so the only host requirements are Docker and a
one-time Chrome login. `scripts/run_export.sh` automatically picks Docker
mode when `docker` is on `PATH`; set `HOMERUN_RUN_MODE=host` to bypass the
container and run directly on the host instead.

```text
launchd ──► run_export.sh ─┬─► docker compose run --rm exporter scheduled
                           │       ├─► entrypoint.sh sees "scheduled"
                           │       ├─► auth fetch (refresh_token, /api/v1/jwt/refresh)
                           │       ├─► persists cookies.txt back to /state (~/.homerun on host)
                           │       └─► pull_info_from_opp.py --all -o /output --type md
                           │             /output -> ~/Google Drive/My Drive/SE Brain/homerun-output (Drive)
                           └─► host fallback if docker isn't available
```

Volume mounts wired in `docker-compose.yml`:

| Container path | Host path | Purpose |
| --- | --- | --- |
| `/state` | `~/.homerun` | Read/write `cookies.txt` (mode 0600) |
| `/output` | `~/Google Drive/My Drive/SE Brain/homerun-output` | Markdown export destination (Drive-synced). Override with `HOMERUN_OUTPUT_HOST_DIR`. |

Container env knobs (overridable via shell or `.env`):

| Variable | Default | Meaning |
| --- | --- | --- |
| `HOMERUN_AUTH_PRIORITY` | `refresh_token` | Comma-separated strategy order |
| `HOMERUN_MIN_TTL` | `600` | Minimum acceptable JWT TTL in seconds |
| `HOMERUN_EXPORT_TYPE` | `md` | Output format (`md` / `json` / `txt`) |
| `HOMERUN_EXPORT_ARGS` | `--all` | Extra flags passed to the exporter |
| `HOMERUN_BASE_URL` | datadog SaaS URL | Override for other Homerun tenants |
| `SLACK_BOT_TOKEN` / `SLACK_CHANNEL_ID` | unset | Optional in-container Slack alert |

## One-time setup (containerized path)

```bash
cd "/Users/.../Homerun Scripts"

# 1. Log in to Homerun in Chrome once so rookiepy can grab a valid jrtoken.
#    -> open https://datadog.cloud.homerunpresales.com/, log in, hard-refresh

# 2. Build the image (or `docker compose build` later — `run_export.sh`
#    triggers a rebuild automatically when the image is missing).
docker compose build exporter

# 3. Run the wrapper once. It bootstraps cookies.txt from host Chrome via
#    rookiepy, then immediately runs the container against /api/v1/jwt/refresh.
./scripts/run_export.sh

# 4. Verify the cron is registered (09:30 daily).
launchctl list | grep com.homerun.export.daily
```

After step 3 the host machine never needs Chrome again — the container can
refresh forever from `~/.homerun/cookies.txt`.

## Ad-hoc commands (containerized)

```bash
# Full unattended export (what launchd runs)
docker compose run --rm exporter scheduled

# Diagnose strategies without exporting
docker compose run --rm exporter auth benchmark --priority refresh_token,rookiepy

# Legacy mode — anything not "scheduled"/"auth" is forwarded to the exporter
docker compose run --rm exporter --list
docker compose run --rm exporter --all
docker compose run --rm exporter "Acme Corp - New Business - Annual - 2026"
```

## Host-only fallback path

If Docker is unavailable (or you want to debug the auth harness against your
live Chrome session via `rookiepy` / `applescript`), set:

```bash
HOMERUN_RUN_MODE=host ./scripts/run_export.sh
```

The wrapper then runs `python -m auth fetch` and `pull_info_from_opp.py`
directly using the venv at `.venv/bin/python`.

Verified end-to-end run (containerized): 6 opportunities + `all.md` written
in ~5 s.

You can run it ad-hoc to test:

```bash
./scripts/run_export.sh
```

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `docker compose run` fails with image-not-found | Image not built yet | `docker compose build exporter` |
| `[container] ERROR: /state/cookies.txt missing or empty` | First run, no host bootstrap yet | `HOMERUN_RUN_MODE=host ./scripts/run_export.sh` once with Chrome logged in, or run any `auth fetch` on the host to seed `~/.homerun/cookies.txt` |
| `refresh_token: no refresh endpoint accepted...` | Endpoint changed or unknown | `python -m auth discover-refresh`, set `HOMERUN_REFRESH_PATH` in `~/.homerun/env` |
| `playwright: storage state not found` | Never ran bootstrap (host-mode only) | `python -m auth bootstrap-playwright` |
| `applescript: osascript failed` (host mode) | Chrome locked / Automation permission missing | System Settings -> Privacy & Security -> Automation -> allow your terminal/launchd binary to control Chrome |
| `rookiepy: jwttoken not present` (host mode) | Not logged in to Homerun in Chrome | log in, hard-refresh once |
| Container exits with `permission denied` writing to `/state` | macOS file-sharing not enabled for `~/.homerun` | Docker Desktop -> Settings -> Resources -> File sharing — ensure your home directory is shared |

## Constraints

- The first run **must** happen with Chrome unlocked and logged in to Homerun
  on the host (so `rookiepy` can seed `~/.homerun/cookies.txt`). After that,
  the container is fully independent of Chrome — `docker compose run` will
  refresh JWTs purely over HTTP.
- The `jrtoken` itself is whatever Homerun considers a "remember me" token —
  if the security team forces re-authentication (SSO timeout, password reset,
  device verification), the wrapper will fail and you'll need to log back in
  in Chrome and re-run once to re-seed the cookies file.
- launchd does not inherit your shell env. Put any secrets/overrides in
  `~/.homerun/env` at mode 0600; `run_export.sh` sources it on every run.
- Storage state files live under `~/.homerun/` with mode 0600. Do not commit
  them; the included `.gitignore` excludes the directory.
- All output is written atomically (temp file + rename) to avoid Drive picking
  up half-written files.
