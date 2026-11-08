#!/usr/bin/env bash
# Run a UI test script against the debug app, launched through Launch Services like a real open.
# Serves "snap" requests (window screenshots) from this shell, so the app itself never asks for
# Screen Recording permission.
# Usage: scripts/uitest.sh script.json [log]
set -euo pipefail
cd "$(dirname "$0")/.."
LOG="${2:-/tmp/focal-uitest.log}"
SNAPDIR="$(dirname "$1")"
: > "$LOG"
DEV_APP="$PWD/build.noindex/Focal Dev.app"   # CONFIG=debug scripts/build-app.sh
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
trap '"$LSREG" -u "$DEV_APP" 2>/dev/null || true' EXIT   # launching registers it; keep it out of Open With
open -n -W -a "$DEV_APP" --env FOCAL_LOG=1 --env "FOCAL_UITEST=$1" --stderr "$LOG" &
APP=$!
while kill -0 "$APP" 2>/dev/null; do
  for req in "$SNAPDIR"/*.req; do
    [ -e "$req" ] || continue
    screencapture -x -o -l "$(cat "$req")" "${req%.req}"
    rm -f "$req"
  done
  sleep 0.05
done
cat "$LOG"
