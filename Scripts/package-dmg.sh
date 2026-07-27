#!/bin/sh

set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_DIR="$PROJECT_DIR/.build/SoundScape.app"
DIST_DIR="$PROJECT_DIR/dist"
DMG_PATH="$DIST_DIR/SoundScape.dmg"
CONFIGURATION=${1:-release}

sh "$PROJECT_DIR/Scripts/package-app.sh" "$CONFIGURATION"

mkdir -p "$DIST_DIR"
STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/SoundScape-dmg.XXXXXX")

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT INT TERM

cp -R "$APP_DIR" "$STAGING_DIR/SoundScape.app"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
    -volname "SoundScape" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

echo "$DMG_PATH"
