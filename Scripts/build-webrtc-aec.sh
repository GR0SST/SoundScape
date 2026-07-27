#!/bin/sh

set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/soundscape-webrtc-build.XXXXXX)
SOURCE_DIR="$WORK_DIR/webrtc-audio-processing"
ARM_BUILD="$SOURCE_DIR/build-arm64"
X86_BUILD="$SOURCE_DIR/build-x86_64"
BRIDGE_DIR="$PROJECT_DIR/Vendor/WebRTCAECBridge"
OUTPUT_DIR="$PROJECT_DIR/Vendor/WebRTCAECBridge.xcframework"
WEBRTC_COMMIT=846fe90a289f58b7c9303a635142aa2c7caa93e5
export MACOSX_DEPLOYMENT_TARGET=14.0

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

git clone \
    https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git \
    "$SOURCE_DIR"
git -C "$SOURCE_DIR" checkout "$WEBRTC_COMMIT"

meson setup \
    "$ARM_BUILD" \
    "$SOURCE_DIR" \
    --default-library=static \
    --buildtype=release
ninja \
    -C "$ARM_BUILD" \
    webrtc/modules/audio_processing/libwebrtc-audio-processing-2.a

meson setup \
    "$X86_BUILD" \
    "$SOURCE_DIR" \
    --cross-file "$BRIDGE_DIR/x86_64.ini" \
    --default-library=static \
    --buildtype=release
ninja \
    -C "$X86_BUILD" \
    webrtc/modules/audio_processing/libwebrtc-audio-processing-2.a

compile_bridge() {
    architecture=$1
    build_dir=$2
    output=$3
    extra_defines=$4

    xcrun clang++ \
        -arch "$architecture" \
        -std=c++17 \
        -O3 \
        -DNDEBUG \
        -DWEBRTC_LIBRARY_IMPL \
        -DWEBRTC_MAC \
        -DWEBRTC_POSIX \
        $extra_defines \
        -I"$BRIDGE_DIR" \
        -I"$SOURCE_DIR/webrtc" \
        -I"$build_dir/subprojects/abseil-cpp-20240722.0" \
        -I"$SOURCE_DIR/subprojects/abseil-cpp-20240722.0" \
        -c "$BRIDGE_DIR/WebRTCAECBridge.cpp" \
        -o "$output"
}

compile_bridge \
    arm64 \
    "$ARM_BUILD" \
    "$WORK_DIR/bridge-arm64.o" \
    "-DWEBRTC_ARCH_ARM64 -DWEBRTC_HAS_NEON"
compile_bridge \
    x86_64 \
    "$X86_BUILD" \
    "$WORK_DIR/bridge-x86_64.o" \
    "-DWEBRTC_ENABLE_AVX2"

libtool -static \
    -o "$WORK_DIR/libWebRTCAEC-arm64.a" \
    "$WORK_DIR/bridge-arm64.o" \
    "$ARM_BUILD/webrtc/modules/audio_processing/libwebrtc-audio-processing-2.a"
libtool -static \
    -o "$WORK_DIR/libWebRTCAEC-x86_64.a" \
    "$WORK_DIR/bridge-x86_64.o" \
    "$X86_BUILD/webrtc/modules/audio_processing/libwebrtc-audio-processing-2.a"
lipo -create \
    "$WORK_DIR/libWebRTCAEC-arm64.a" \
    "$WORK_DIR/libWebRTCAEC-x86_64.a" \
    -output "$WORK_DIR/libWebRTCAEC.a"

mkdir -p "$WORK_DIR/Headers"
cp "$BRIDGE_DIR/WebRTCAECBridge.h" "$WORK_DIR/Headers/"
cp "$BRIDGE_DIR/module.modulemap" "$WORK_DIR/Headers/"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/macos-arm64_x86_64/Headers"
cp \
    "$WORK_DIR/libWebRTCAEC.a" \
    "$OUTPUT_DIR/macos-arm64_x86_64/libWebRTCAEC.a"
cp \
    "$WORK_DIR/Headers/WebRTCAECBridge.h" \
    "$OUTPUT_DIR/macos-arm64_x86_64/Headers/"
cp \
    "$WORK_DIR/Headers/module.modulemap" \
    "$OUTPUT_DIR/macos-arm64_x86_64/Headers/"
cp "$BRIDGE_DIR/Info.plist" "$OUTPUT_DIR/Info.plist"
