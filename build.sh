#!/usr/bin/env bash
set -e

echo "Building InstagramCameraControlScroll and CameraControlSystemProbe for arm64/arm64e iOS..."

SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || echo "")

FRAMEWORKS="-framework Foundation -framework UIKit -framework AVFoundation -framework CoreGraphics -framework QuartzCore"
PROBE_FRAMEWORKS="-framework Foundation -framework UIKit"

if [ -n "$SDK_PATH" ]; then
    xcrun -sdk iphoneos clang++ -dynamiclib -arch arm64 -arch arm64e \
        -miphoneos-version-min=14.0 \
        -isysroot "$SDK_PATH" \
        $FRAMEWORKS \
        -O3 -fobjc-arc -std=c++17 \
        InstagramCameraControlScroll.mm -lc++ \
        -o InstagramCameraControlScroll.dylib

    xcrun -sdk iphoneos clang++ -dynamiclib -arch arm64 -arch arm64e \
        -miphoneos-version-min=14.0 \
        -isysroot "$SDK_PATH" \
        $PROBE_FRAMEWORKS \
        -O0 -fobjc-arc -std=c++17 \
        CameraControlSystemProbe.mm -lc++ \
        -o CameraControlSystemProbe.dylib
else
    echo "Using direct clang++..."
    clang++ -dynamiclib -target arm64-apple-ios14.0 \
        $FRAMEWORKS \
        -O3 -fobjc-arc -std=c++17 \
        InstagramCameraControlScroll.mm -lc++ \
        -o InstagramCameraControlScroll.dylib

    clang++ -dynamiclib -target arm64-apple-ios14.0 \
        $PROBE_FRAMEWORKS \
        -O0 -fobjc-arc -std=c++17 \
        CameraControlSystemProbe.mm -lc++ \
        -o CameraControlSystemProbe.dylib
fi

echo "Successfully built InstagramCameraControlScroll.dylib and CameraControlSystemProbe.dylib!"
