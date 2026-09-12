#!/usr/bin/env bash
# Build Purge signed, make sure the embedded privileged helper is really signed
# (not left ad-hoc), and install it to /Applications so the SMAppService daemon can
# register. This is for LOCAL testing of the "Protected App Removal" helper — no DMG,
# no notarization. Shipping still goes through scripts/make-dmg.sh.
#
# Usage: ./scripts/test-privileged-helper.sh
#
# You will be asked for your password once, to replace /Applications/Purge.app.
set -euo pipefail

IDENTITY="Developer ID Application: Jithin Sabu (BX83ZBV95B)"
TEAM="BX83ZBV95B"
HELPER="Contents/MacOS/io.getpurge.helper"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DDIR="$REPO_ROOT/build/HelperTest"

cd "$REPO_ROOT"

echo "==> Checking the Developer ID signing certificate is present"
if ! security find-identity -v -p codesigning | grep -q "$TEAM"; then
  echo "No Developer ID Application certificate for team $TEAM found in your keychain." >&2
  echo "The helper cannot be signed without it, so testing can't proceed." >&2
  exit 1
fi

echo "==> Building a signed Release (this is a real signed build, not signing-off)"
xcodebuild -project purge.xcodeproj -scheme purge -configuration Release \
  -derivedDataPath "$DDIR" clean build >/dev/null

APP="$DDIR/Build/Products/Release/Purge.app"
[ -d "$APP" ] || { echo "Build did not produce $APP" >&2; exit 1; }
[ -e "$APP/$HELPER" ] || { echo "Helper missing from the build at $HELPER" >&2; exit 1; }

echo "==> Verifying the embedded helper's signature"
# The one thing that historically goes wrong (same as Sparkle's nested binaries):
# the copy phase can leave the helper ad-hoc. Require a real Developer ID signature,
# the right team, and hardened runtime; re-sign inside-out only if it is wrong.
helper_info="$(codesign -dvvv "$APP/$HELPER" 2>&1 || true)"
needs_resign=0
echo "$helper_info" | grep -q "Authority=Developer ID Application" || needs_resign=1
echo "$helper_info" | grep -q "TeamIdentifier=$TEAM"               || needs_resign=1
echo "$helper_info" | grep -q "flags=.*runtime"                    || needs_resign=1

if [ "$needs_resign" -eq 1 ]; then
  echo "    Helper was not correctly signed by the build. Re-signing inside-out."
  codesign -f -o runtime -s "$IDENTITY" "$APP/$HELPER"
  # Re-sign the outer app so its seal covers the freshly re-signed helper. No --deep,
  # so the already-valid Sparkle framework is left untouched.
  codesign -f -o runtime -s "$IDENTITY" "$APP"
else
  echo "    Helper is correctly signed by the build."
fi

echo "==> Final signature check (app + everything nested)"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "    Helper identity:"
codesign -dvvv "$APP/$HELPER" 2>&1 | grep -E "^(Identifier|Authority=Developer ID|TeamIdentifier|flags)=" | sed 's/^/      /'

echo "==> Installing to /Applications"
osascript -e 'quit app "Purge"' >/dev/null 2>&1 || true
sleep 1
if [ -e "/Applications/Purge.app" ]; then
  rm -rf "/Applications/Purge.app" 2>/dev/null || sudo rm -rf "/Applications/Purge.app"
fi
cp -R "$APP" "/Applications/Purge.app"

echo
echo "==> Done. /Applications/Purge.app is signed and ready."
echo "    Next:"
echo "      1. open -a Purge"
echo "      2. Settings > Protected App Removal > turn it on, then approve Purge in"
echo "         System Settings > General > Login Items & Extensions."
echo "      3. Confirm the daemon registered:"
echo "         sudo launchctl print system/io.getpurge.helper | head"
