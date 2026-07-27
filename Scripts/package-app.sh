#!/bin/sh

set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="$PROJECT_DIR/.build"
APP_DIR="$BUILD_DIR/SoundScape.app"

swift build --package-path "$PROJECT_DIR"
BIN_DIR=$(swift build --package-path "$PROJECT_DIR" --show-bin-path)
EXECUTABLE="$BIN_DIR/SoundScape"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/SoundScape"
cp "$PROJECT_DIR/Support/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/SoundScape.icns" \
    "$APP_DIR/Contents/Resources/SoundScape.icns"
codesign \
    --force \
    --deep \
    --sign - \
    --entitlements "$PROJECT_DIR/Support/SoundScape.entitlements" \
    "$APP_DIR"

echo "$APP_DIR"
