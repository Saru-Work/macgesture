#!/bin/bash
# Builds MacGesture.app into ./build.
#
#   scripts/build-app.sh            release build, ad-hoc signed
#   scripts/build-app.sh --debug    debug build
#
# Signing: set MACGESTURE_SIGN_IDENTITY to a code-signing identity (for example
# a self-signed "MacGesture Local" certificate) so macOS keeps the Accessibility
# grant across rebuilds. Ad-hoc signatures change every build, and macOS then
# treats each build as a different app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION=release
[[ "${1:-}" == "--debug" ]] && CONFIGURATION=debug

VERSION="${MACGESTURE_VERSION:-0.1.0}"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
IDENTITY="${MACGESTURE_SIGN_IDENTITY:--}"

APP="$ROOT/build/MacGesture.app"
CONTENTS="$APP/Contents"

echo "==> Building ($CONFIGURATION)"
swift build --package-path "$ROOT" -c "$CONFIGURATION" --arch arm64
BINARY="$(swift build --package-path "$ROOT" -c "$CONFIGURATION" --arch arm64 --show-bin-path)/MacGesture"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BINARY" "$CONTENTS/MacOS/MacGesture"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" "$ROOT/Resources/Info.plist" > "$CONTENTS/Info.plist"

ICONSET="$ROOT/build/AppIcon.iconset"
if [[ ! -f "$ROOT/build/AppIcon.icns" ]]; then
    echo "==> Rendering icon"
    swift "$ROOT/scripts/make-icon.swift" "$ICONSET"
    iconutil -c icns "$ICONSET" -o "$ROOT/build/AppIcon.icns"
    rm -rf "$ICONSET"
fi
cp "$ROOT/build/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

echo "==> Signing (identity: $IDENTITY)"
# Not sandboxed: the private multitouch framework, Accessibility control of
# other apps, and user scripts are all incompatible with the App Sandbox.
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "==> Done: $APP"
