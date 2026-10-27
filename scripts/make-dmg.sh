#!/usr/bin/env bash
# Build, sign, notarize and staple the release DMG.
#
# Usage: ./scripts/make-dmg.sh <version> [path-to-Purge.app]
# Example: ./scripts/make-dmg.sh 1.3.2 /tmp/purge-release/export/Purge.app
#
# Prints the edSignature, length and sha256 needed for the appcast entry.
# Run ./release.sh afterwards to publish, then commit the appcast.
set -euo pipefail

VERSION="${1:?Usage: ./scripts/make-dmg.sh <version> [path-to-Purge.app]}"
APP="${2:-/tmp/purge-release/export/Purge.app}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="Developer ID Application: Jithin Sabu (BX83ZBV95B)"
NOTARY_PROFILE="purge-notary"
OUT_DIR="$HOME/Downloads/Purge"
DMG="$OUT_DIR/Purgev${VERSION}.dmg"
STAGING="$(mktemp -d)/staging"

[ -d "$APP" ] || { echo "App not found at: $APP" >&2; exit 1; }

# The app carries its version from build time. A DMG named 1.3.2 around a
# 1.3.1 build looks completely fine until Sparkle offers the same update
# forever, so refuse the mismatch here rather than discover it after release.
APP_VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)"
if [ "$APP_VERSION" != "$VERSION" ]; then
  echo "Version mismatch: app is $APP_VERSION but building Purgev${VERSION}.dmg" >&2
  echo "Bump MARKETING_VERSION in both configs and re-archive." >&2
  exit 1
fi

# Sparkle decides whether an update is newer by the build number
# (CFBundleVersion, CURRENT_PROJECT_VERSION), not by the version above. A build
# number that wasn't bumped means installed copies never see the update, or
# see it again after every install. Each appcast item lists sparkle:version
# just before sparkle:shortVersionString.
APP_BUILD="$(defaults read "$APP/Contents/Info" CFBundleVersion)"
case "$APP_BUILD" in
  '' | *[!0-9]*)
    echo "Build number '$APP_BUILD' is not a whole number." >&2
    exit 1
    ;;
esac
APPCAST_BUILDS="$(awk -F'[<>]' '
  $2 == "sparkle:version" { build = $3 }
  $2 == "sparkle:shortVersionString" { print $3, build }
' "$REPO_ROOT/appcast.xml")"
LISTED_BUILD="$(echo "$APPCAST_BUILDS" | awk -v v="$VERSION" '$1 == v && !seen++ { print $2 }')"
SHIPPED_BUILD="$(echo "$APPCAST_BUILDS" | awk -v v="$VERSION" '$1 != v && $2 + 0 > max { max = $2 + 0 } END { print max + 0 }')"
if [ -n "$LISTED_BUILD" ] && [ "$APP_BUILD" != "$LISTED_BUILD" ]; then
  echo "Build mismatch: appcast.xml lists $VERSION as build $LISTED_BUILD, but the app is build $APP_BUILD." >&2
  exit 1
fi
if [ -z "$LISTED_BUILD" ] && [ "$APP_BUILD" -le "$SHIPPED_BUILD" ]; then
  echo "Build mismatch: app is build $APP_BUILD, but appcast.xml already ships build $SHIPPED_BUILD." >&2
  echo "Bump CURRENT_PROJECT_VERSION in both configs and re-archive." >&2
  exit 1
fi

echo "==> Verifying the exported app is properly signed"
# Older Xcode left Sparkle's nested binaries ad-hoc signed, which notarization
# rejects. Recent Xcode does not. Check rather than re-sign blindly: re-signing
# a good export risks breaking the outer signature for no gain.
codesign --verify --deep --strict "$APP"
for nested in Autoupdate Updater.app XPCServices/Installer.xpc XPCServices/Downloader.xpc; do
  path="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current/$nested"
  [ -e "$path" ] || continue
  # Capture first: piping straight into `grep -q` lets grep exit after its
  # first match and SIGPIPE codesign, which pipefail then reports as codesign
  # itself failing even though the timestamp was right there in the output.
  info="$(codesign -dvvv "$path" 2>&1)"
  echo "$info" | grep -q "^Timestamp=" \
    || { echo "$nested has no secure timestamp; re-sign inside-out before continuing." >&2; exit 1; }
done

echo "==> Staging"
# Only the app: exporting also writes ExportOptions.plist, DistributionSummary.plist
# and Packaging.log beside it, and create-dmg would happily package them.
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"

echo "==> Creating $DMG"
mkdir -p "$OUT_DIR"
rm -f "$DMG"
# dmg_bg.png is 1200x736 at 144 dpi: 600x368 points, drawn 1:1 in the
# icon view. Finder stores the title bar inside window bounds (~32 pt
# on macOS 11+), so a 368 pt window leaves only 336 pt of content and
# clips the bottom of the art. 400 pt makes the content area 368 pt.
create-dmg \
  --volname "Purge" \
  --volicon "$REPO_ROOT/Assets/dmg/VolumeIcon.icns" \
  --background "$REPO_ROOT/Assets/dmg/dmg_bg.png" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --text-size 16 \
  --icon "Purge.app" 175 192 \
  --app-drop-link 425 192 \
  "$DMG" "$STAGING"

echo "==> Signing the DMG (before notarizing)"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "==> Notarizing"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"

echo
echo "==> Appcast values"
# sign_update runs last: stapling changes the file size, and a stale length
# breaks the update for everyone.
"$REPO_ROOT/bin/sign_update" "$DMG"
echo "sparkle:version: $APP_BUILD"
echo "sha256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "dmg:    $DMG"
