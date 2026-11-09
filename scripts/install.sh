#!/usr/bin/env bash
# Build release and install to ~/Applications/Focal.app, registered with Launch Services.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh
# Replace the copy that's already installed, wherever it is (a DMG install lands in /Applications): a second copy lists twice in Open With.
DEST="$HOME/Applications/Focal.app"
[ -d /Applications/Focal.app ] && DEST=/Applications/Focal.app
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
mkdir -p "$HOME/Applications"
# Quit a running Focal the way a person would, so unsaved changes get their usual prompt. Never kill it:
# a force-kill closed whatever was open and discarded unsaved edits.
if pgrep -f "$DEST/Contents/MacOS/Focal" >/dev/null; then
  osascript -e 'tell application id "ai.digitalzoo.focal" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do pgrep -f "$DEST/Contents/MacOS/Focal" >/dev/null || break; sleep 0.2; done
  if pgrep -f "$DEST/Contents/MacOS/Focal" >/dev/null; then
    echo "Focal is still open (unsaved changes, or Quit was cancelled). Not installing." >&2
    exit 1
  fi
fi
rm -rf "$DEST"
cp -R build.noindex/Focal.app "$DEST"
"$LSREG" -u "$PWD/build.noindex/Focal.app" 2>/dev/null || true   # only the installed copy may appear in app lists
"$LSREG" -f "$DEST"
echo "installed $DEST"
