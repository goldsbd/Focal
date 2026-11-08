#!/usr/bin/env bash
# A release for other people: an Apple silicon app (Intel isn't built: nobody can test it), signed with Developer ID and the hardened
# runtime, in a DMG that Apple has notarized and that carries its ticket (opens offline without Gatekeeper warnings).
#
#   scripts/release.sh [version]          version defaults to CFBundleShortVersionString in Resources/Info.plist
#
#   FOCAL_SIGN_IDENTITY   signing identity (default: the keychain's "Developer ID Application" one)
#                         "-" makes an ad-hoc signed DMG and skips notarizing: for testing the packaging only
#   FOCAL_NOTARY_PROFILE  notarytool keychain profile (default: focal-notary), made once with
#                         xcrun notarytool store-credentials focal-notary --apple-id <Apple ID> --team-id <team>
#
# Output: build.noindex/release/Focal-<version>.dmg and its SHA-256 (for a Homebrew cask).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
BUILD_NUMBER="$(git rev-list --count HEAD)"
PROFILE="${FOCAL_NOTARY_PROFILE:-focal-notary}"
OUT="build.noindex/release"
APP="$OUT/Focal.app"
DMG="$OUT/Focal-$VERSION.dmg"

IDENTITY="${FOCAL_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
  if [ -z "$IDENTITY" ]; then
    echo "No \"Developer ID Application\" certificate in the keychain." >&2
    echo "Create one: Xcode ▸ Settings ▸ Accounts ▸ your team ▸ Manage Certificates ▸ + ▸ Developer ID Application." >&2
    echo "(FOCAL_SIGN_IDENTITY=- builds an unsigned test DMG.)" >&2
    exit 1
  fi
fi
ADHOC=false
[ "$IDENTITY" = "-" ] && ADHOC=true

echo "== Focal $VERSION ($BUILD_NUMBER), signing as: $IDENTITY"
ARCHS=(--arch arm64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Focal"
lipo -info "$BIN"
[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources/AppIcon.icns

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Focal"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

if $ADHOC; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

# The DMG: the app and a shortcut to Applications to drag it onto.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Focal $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if $ADHOC; then
  echo "== ad-hoc test build (not notarized: Gatekeeper will refuse it on other Macs)"
else
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  echo "== notarizing (a few minutes)"
  RESULT="$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --output-format json)"
  echo "$RESULT"
  if ! echo "$RESULT" | grep -q '"status" *: *"Accepted"'; then
    ID="$(echo "$RESULT" | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE"
    echo "Notarization was not accepted." >&2
    exit 1
  fi
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

echo "== $DMG"
shasum -a 256 "$DMG"
