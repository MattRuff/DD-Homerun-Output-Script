#!/usr/bin/env bash
# Install (or re-install) the daily Homerun export launchd job.
#
# Auto-detects the absolute paths to this checkout so the generated plist is
# portable across machines / users. Re-running this script is safe: it
# unloads any existing job before loading the freshly-generated plist.
#
# Usage:
#   ./scripts/install-launchd.sh                # default schedule: 09:30 daily
#   ./scripts/install-launchd.sh 9 30           # explicit HH MM
#   ./scripts/install-launchd.sh 18 0           # 18:00 daily
#   ./scripts/install-launchd.sh --uninstall    # remove the job

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="$(cd "$PKG_DIR/.." && pwd)"

WRAPPER="$PKG_DIR/scripts/run_export.sh"
LOG="$WORKSPACE_DIR/output/export.log"
LABEL="com.homerun.export.daily"
PLIST_DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"

if [ "${1:-}" = "--uninstall" ]; then
  if [ -f "$PLIST_DEST" ]; then
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    rm -f "$PLIST_DEST"
    echo "Removed $PLIST_DEST"
  else
    echo "Nothing to uninstall ($PLIST_DEST not found)"
  fi
  exit 0
fi

HOUR="${1:-9}"
MIN="${2:-30}"

if ! [[ "$HOUR" =~ ^[0-9]+$ ]] || [ "$HOUR" -gt 23 ]; then
  echo "ERROR: hour must be an integer 0-23 (got '$HOUR')" >&2
  exit 1
fi
if ! [[ "$MIN" =~ ^[0-9]+$ ]] || [ "$MIN" -gt 59 ]; then
  echo "ERROR: minute must be an integer 0-59 (got '$MIN')" >&2
  exit 1
fi
if [ ! -x "$WRAPPER" ]; then
  echo "ERROR: wrapper not executable: $WRAPPER" >&2
  exit 1
fi

mkdir -p "$(dirname "$LOG")" "$(dirname "$PLIST_DEST")"

cat > "$PLIST_DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${WRAPPER}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${WORKSPACE_DIR}</string>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>${HOUR}</integer>
        <key>Minute</key>
        <integer>${MIN}</integer>
    </dict>
    <key>RunAtLoad</key>
    <false/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${LOG}</string>
    <key>StandardErrorPath</key>
    <string>${LOG}</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST_DEST" 2>/dev/null || true
launchctl load -w "$PLIST_DEST"

printf "Installed launchd job:\n"
printf "  label    %s\n" "$LABEL"
printf "  plist    %s\n" "$PLIST_DEST"
printf "  wrapper  %s\n" "$WRAPPER"
printf "  log      %s\n" "$LOG"
printf "  schedule %02d:%02d daily\n" "$HOUR" "$MIN"
printf "\nVerify with: launchctl list | grep %s\n" "$LABEL"
