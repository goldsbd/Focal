#!/usr/bin/env bash
# Build the app into build.noindex/ (".noindex": Spotlight never lists these copies).
#   CONFIG=release (default): build.noindex/Focal.app      — staged for scripts/install.sh
#   CONFIG=debug:             build.noindex/Focal Dev.app  — UI-test build, its own name and bundle id,
#                             so it is never confused with the installed app and never touches its settings.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
OUT="build.noindex"
if [ "$CONFIG" = debug ]; then NAME="Focal Dev"; BUNDLE_ID="ai.digitalzoo.focal.dev"; else NAME="Focal"; BUNDLE_ID="ai.digitalzoo.focal"; fi
APP="$OUT/$NAME.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Focal"
[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources/AppIcon.icns

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Focal"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Set :CFBundleName $NAME" \
  -c "Set :CFBundleDisplayName $NAME" "$APP/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "$APP ($CONFIG)"
