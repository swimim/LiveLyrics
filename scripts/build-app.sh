#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
if [[ "$CONFIG" != "release" && "$CONFIG" != "debug" ]]; then echo "Usage: $0 [release|debug]"; exit 2; fi
cmake -S Vendor/mediaremote-adapter -B .build/adapter -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
cmake --build .build/adapter -j 4
swift build -c "$CONFIG" --disable-sandbox
BIN="$(swift build -c "$CONFIG" --show-bin-path --disable-sandbox)"
# Build outside an iCloud Desktop: FileProvider can reattach FinderInfo at any time.
STAGING="$(mktemp -d /private/tmp/livelyrics-build.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/LiveLyrics.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist
cp "$BIN/LiveLyrics" "$APP/Contents/MacOS/LiveLyrics"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ "${GITHUB_REF_TYPE:-}" == "tag" && "${GITHUB_REF_NAME:-}" =~ ^v?([0-9]+\.)*[0-9]+$ ]]; then
  RELEASE_VERSION="${GITHUB_REF_NAME#v}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RELEASE_VERSION" "$APP/Contents/Info.plist"
fi
ICONSET="$STAGING/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" Resources/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" Resources/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl "$APP/Contents/Resources/"
cp Vendor/mediaremote-adapter/LICENSE "$APP/Contents/Resources/MediaRemoteAdapter-LICENSE.txt"
ditto --norsrc --noextattr .build/adapter/MediaRemoteAdapter.framework "$APP/Contents/Resources/MediaRemoteAdapter.framework"
xattr -r -d com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -r -d com.apple.ResourceFork "$APP" 2>/dev/null || true
codesign --force --sign - "$APP/Contents/Resources/MediaRemoteAdapter.framework"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$STAGING/LiveLyrics.zip"
# Verify the deliverable archive, not only the staging bundle.
mkdir "$STAGING/verify"
ditto -x -k "$STAGING/LiveLyrics.zip" "$STAGING/verify"
codesign --verify --deep --strict "$STAGING/verify/LiveLyrics.app"
cp "$STAGING/LiveLyrics.zip" dist/LiveLyrics.zip
# Keep the bundle directory stable for Finder/FileProvider. rsync replaces changed
# files by rename (never --inplace), preserving a running executable's mapped inode.
mkdir -p dist/LiveLyrics.app
rsync -a --delete --delay-updates "$APP/" dist/LiveLyrics.app/
xattr -r -d com.apple.FinderInfo dist/LiveLyrics.app 2>/dev/null || true
xattr -r -d com.apple.ResourceFork dist/LiveLyrics.app 2>/dev/null || true
echo "Built: $PWD/dist/LiveLyrics.app"
echo "Verified archive: $PWD/dist/LiveLyrics.zip"
