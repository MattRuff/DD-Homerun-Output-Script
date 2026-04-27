#!/usr/bin/env bash
# Container entrypoint with two modes:
#
#   1. "scheduled" — unattended export. Reads a persisted cookies.txt from
#      $HOMERUN_STATE_DIR, refreshes the JWT against /api/v1/jwt/refresh, runs
#      pull_info_from_opp.py --all, and writes Markdown to $HOMERUN_OUTPUT_DIR.
#      This is what the launchd cron / docker-compose scheduler invokes.
#
#   2. legacy / pass-through — anything that doesn't start with "scheduled" is
#      forwarded straight to pull_info_from_opp.py so existing usage
#      (`docker run IMAGE --all`, `docker run IMAGE --list`, etc.) keeps
#      working unchanged.
#
# All paths are container paths. Volume mounts:
#   /state  -> persisted cookies (RW, mode 0600)
#   /output -> Drive-synced export folder (RW)
#
# Environment knobs (with defaults):
#   HOMERUN_STATE_DIR     /state
#   HOMERUN_OUTPUT_DIR    /output
#   HOMERUN_AUTH_PRIORITY refresh_token        # rookiepy/applescript/playwright impossible in container
#   HOMERUN_MIN_TTL       600                  # Homerun JWTs live ~17 min
#   HOMERUN_EXPORT_TYPE   md
#   HOMERUN_EXPORT_ARGS   "--all"              # extra flags passed to the exporter
#   SLACK_BOT_TOKEN / SLACK_CHANNEL_ID         # optional failure notification

set -uo pipefail

STATE_DIR="${HOMERUN_STATE_DIR:-/state}"
OUTPUT_DIR="${HOMERUN_OUTPUT_DIR:-/output}"
COOKIES_FILE="$STATE_DIR/cookies.txt"
PRIORITY="${HOMERUN_AUTH_PRIORITY:-refresh_token}"
MIN_TTL="${HOMERUN_MIN_TTL:-600}"
EXPORT_TYPE="${HOMERUN_EXPORT_TYPE:-md}"
EXPORT_ARGS="${HOMERUN_EXPORT_ARGS:---all}"

ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { printf "[%s] [container] %s\n" "$(ts)" "$*"; }

slack_alert() {
  local msg="$1"
  if [ -n "${SLACK_BOT_TOKEN:-}" ] && [ -n "${SLACK_CHANNEL_ID:-}" ]; then
    /usr/bin/curl -sS -X POST https://slack.com/api/chat.postMessage \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      -H "Content-Type: application/json; charset=utf-8" \
      --data "{\"channel\":\"$SLACK_CHANNEL_ID\",\"text\":\":warning: Homerun export (container) failed: $msg\"}" \
      >/dev/null 2>&1 || true
  fi
}

setup_state_symlink() {
  # The auth package reads/writes cookies under $HOME/.homerun by default.
  # Make that point at the mounted $STATE_DIR so every subcommand
  # (scheduled / auth / fetch / benchmark) shares the same persisted file.
  export HOME="${HOME:-/root}"
  if [ -d "$STATE_DIR" ] && [ "$STATE_DIR" != "$HOME/.homerun" ]; then
    rm -rf "$HOME/.homerun"
    ln -s "$STATE_DIR" "$HOME/.homerun"
  else
    mkdir -p "$HOME/.homerun"
  fi
}

run_scheduled() {
  log "starting scheduled export (priority=$PRIORITY, min_ttl=${MIN_TTL}s)"

  if [ ! -d "$STATE_DIR" ]; then
    log "ERROR: state dir $STATE_DIR not mounted; nothing to refresh from"
    slack_alert "state dir $STATE_DIR not mounted"
    return 2
  fi
  mkdir -p "$OUTPUT_DIR"

  if [ ! -s "$COOKIES_FILE" ]; then
    log "ERROR: $COOKIES_FILE missing or empty. Bootstrap once on the host:"
    log "         python -m auth fetch --priority refresh_token,rookiepy"
    slack_alert "missing $COOKIES_FILE — host bootstrap required"
    return 3
  fi

  local cookies
  if ! cookies=$(python -m auth fetch \
      --priority "$PRIORITY" \
      --min-ttl "$MIN_TTL" \
      --verbose); then
    log "ERROR: auth fetch failed (see stderr above)"
    slack_alert "auth harness failed inside container"
    return 4
  fi
  if [ -z "$cookies" ]; then
    log "ERROR: auth fetch returned empty cookies"
    slack_alert "empty cookies returned from auth harness"
    return 5
  fi
  log "auth ok, running exporter"

  # shellcheck disable=SC2086 - we want word splitting on EXPORT_ARGS
  if ! HOMERUN_COOKIES="$cookies" python pull_info_from_opp.py \
       $EXPORT_ARGS \
       -o "$OUTPUT_DIR" \
       --type "$EXPORT_TYPE"; then
    log "ERROR: pull_info_from_opp.py exited non-zero"
    slack_alert "exporter exited non-zero"
    return 6
  fi

  log "export complete -> $OUTPUT_DIR"
  return 0
}

main() {
  setup_state_symlink

  if [ "${1:-}" = "scheduled" ]; then
    shift
    run_scheduled "$@"
    return $?
  fi
  if [ "${1:-}" = "auth" ]; then
    shift
    exec python -m auth "$@"
  fi
  exec python pull_info_from_opp.py "$@"
}

main "$@"
