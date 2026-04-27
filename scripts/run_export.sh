#!/usr/bin/env bash
# Zero-touch driver for the daily Homerun Markdown export.
#
# Default flow (preferred):
#   1. Source ~/.homerun/env if present (Slack token, refresh path overrides).
#   2. Run `docker compose run --rm exporter scheduled` so the entire export
#      executes inside the homerun-exporter:local container with
#      ~/.homerun and ~/Google Drive/My Drive/SE Brain/homerun-output mounted in.
#
# Fallback flow (when Docker is unavailable):
#   - Run `python -m auth fetch` + `pull_info_from_opp.py --all` directly on
#     the host. This is the original behavior and is preserved for environments
#     where Docker isn't installed (or for debugging the auth harness against a
#     live host Chrome via rookiepy).
#
# Override the mode with HOMERUN_RUN_MODE=docker | host (default: auto).
#
# Failure handling:
#   - macOS: native notification on any non-zero exit.
#   - Slack: posts to $SLACK_CHANNEL_ID if $SLACK_BOT_TOKEN is set.
#   - All output is appended to $LOG (default: <repo>/output/export.log).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="$(cd "$PKG_DIR/.." && pwd)"

# Optional env file for SLACK_BOT_TOKEN / SLACK_CHANNEL_ID / HOMERUN_REFRESH_PATH
# (launchd does not inherit your shell env, so put secrets here at mode 0600).
if [ -f "$HOME/.homerun/env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$HOME/.homerun/env"
  set +a
fi

OUTPUT_DIR="${HOMERUN_OUTPUT_DIR:-$HOME/Google Drive/My Drive/SE Brain/homerun-output}"
LOG="${HOMERUN_LOG:-$WORKSPACE_DIR/output/export.log}"
PRIORITY="${HOMERUN_AUTH_PRIORITY:-refresh_token,playwright,applescript,rookiepy}"
MIN_TTL="${HOMERUN_MIN_TTL:-600}"
RUN_MODE="${HOMERUN_RUN_MODE:-auto}"

mkdir -p "$(dirname "$LOG")" "$OUTPUT_DIR" "$HOME/.homerun"

ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { printf "[%s] %s\n" "$(ts)" "$*" >>"$LOG"; }

notify_failure() {
  local msg="$1"
  if [ "$(uname)" = "Darwin" ] && command -v osascript >/dev/null 2>&1; then
    /usr/bin/osascript -e \
      "display notification \"$msg\" with title \"Homerun export FAILED\"" \
      >/dev/null 2>&1 || true
  fi
  if [ -n "${SLACK_BOT_TOKEN:-}" ] && [ -n "${SLACK_CHANNEL_ID:-}" ]; then
    /usr/bin/curl -sS -X POST https://slack.com/api/chat.postMessage \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      -H "Content-Type: application/json; charset=utf-8" \
      --data "{\"channel\":\"$SLACK_CHANNEL_ID\",\"text\":\":warning: Homerun export failed: $msg\"}" \
      >>"$LOG" 2>&1 || true
  fi
}

# --- Mode detection -----------------------------------------------------------

DOCKER_BIN=""
if [ "$RUN_MODE" != "host" ]; then
  for candidate in /usr/local/bin/docker /opt/homebrew/bin/docker docker; do
    if command -v "$candidate" >/dev/null 2>&1; then
      DOCKER_BIN="$(command -v "$candidate")"
      break
    fi
  done
fi

if [ -n "${HOMERUN_PYTHON:-}" ]; then
  PYTHON="$HOMERUN_PYTHON"
elif [ -x "$WORKSPACE_DIR/.venv/bin/python" ]; then
  PYTHON="$WORKSPACE_DIR/.venv/bin/python"
elif [ -x "$PKG_DIR/.venv/bin/python" ]; then
  PYTHON="$PKG_DIR/.venv/bin/python"
else
  PYTHON="python3"
fi

# --- Run modes ----------------------------------------------------------------

run_via_docker() {
  log "==== run_export.sh (docker mode) starting ===="
  # docker-compose.yml lives next to this script's parent (the repo root). For
  # legacy layouts where it's at the workspace root, fall back to that.
  if [ -f "$PKG_DIR/docker-compose.yml" ]; then
    cd "$PKG_DIR"
  elif [ -f "$WORKSPACE_DIR/docker-compose.yml" ]; then
    cd "$WORKSPACE_DIR"
  else
    log "ERROR: no docker-compose.yml found at $PKG_DIR or $WORKSPACE_DIR"
    notify_failure "docker-compose.yml not found"
    return 1
  fi

  # Bootstrap the cookies file on first run so the container has something to
  # refresh from. The container itself only does HTTP, so it can't read Chrome.
  if [ ! -s "$HOME/.homerun/cookies.txt" ]; then
    log "no persisted cookies yet; bootstrapping from Chrome via host rookiepy"
    if ! "$PYTHON" -m auth fetch --priority refresh_token,rookiepy \
         --min-ttl "$MIN_TTL" --verbose >/dev/null 2>>"$LOG"; then
      log "ERROR: bootstrap from host failed (Chrome cookies unavailable?)"
      notify_failure "container bootstrap failed; see $LOG"
      return 1
    fi
  fi

  if ! "$DOCKER_BIN" compose run --rm exporter scheduled >>"$LOG" 2>&1; then
    log "ERROR: docker compose run failed"
    notify_failure "docker compose run exited non-zero; see $LOG"
    return 1
  fi

  log "==== run_export.sh (docker mode) complete (output: $OUTPUT_DIR) ===="
  return 0
}

run_on_host() {
  log "==== run_export.sh (host mode) starting (priority=$PRIORITY, min_ttl=${MIN_TTL}s) ===="
  cd "$PKG_DIR"

  local cookies
  if ! cookies=$("$PYTHON" -m auth fetch \
      --priority "$PRIORITY" \
      --min-ttl "$MIN_TTL" \
      --verbose 2>>"$LOG"); then
    log "ERROR: no auth strategy could produce fresh cookies"
    notify_failure "auth harness exhausted all strategies; see $LOG"
    return 1
  fi
  if [ -z "$cookies" ]; then
    log "ERROR: auth harness returned empty cookies"
    notify_failure "auth harness returned empty cookies"
    return 1
  fi

  log "auth ok; running exporter"
  if ! HOMERUN_COOKIES="$cookies" \
       "$PYTHON" "$PKG_DIR/pull_info_from_opp.py" --all \
       -o "$OUTPUT_DIR" \
       --type md \
       >>"$LOG" 2>&1; then
    log "ERROR: pull_info_from_opp.py failed"
    notify_failure "exporter exited non-zero; see $LOG"
    return 1
  fi

  log "==== run_export.sh (host mode) complete (output: $OUTPUT_DIR) ===="
  return 0
}

# --- Dispatch -----------------------------------------------------------------

if [ "$RUN_MODE" = "host" ] || [ -z "$DOCKER_BIN" ]; then
  run_on_host
  exit $?
fi

# Auto / docker mode — try docker first, fall back to host on docker failure
# unless the user explicitly forced docker mode.
if run_via_docker; then
  exit 0
fi

if [ "$RUN_MODE" = "docker" ]; then
  exit 1
fi

log "docker run failed; falling back to host mode"
run_on_host
exit $?
