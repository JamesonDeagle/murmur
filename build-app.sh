#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP="Murmur.app"
BUILD_DIR=".build/xcode"
PRODUCTS_DIR="$BUILD_DIR/Build/Products/Release"

# We build through `xcodebuild` (not `swift build`) so that mlx-swift's Metal
# shaders get compiled into a real .metallib. CLI `swift build` doesn't
# invoke the Metal toolchain, which makes any MLX-backed model (Voxtral,
# Qwen3) crash at load with "Failed to load the default metallib".
# Metal toolchain is now a separate Xcode component; if you've never built
# Metal code on this machine run once:
#   xcodebuild -downloadComponent MetalToolchain
#
# ARCHS=arm64: whisper.cpp's static libs in lib/ are arm64 only; without
# pinning the architecture xcodebuild tries a universal x86_64+arm64 build
# and the link step fails on missing whisper symbols for x86_64.

echo "Building Murmur via xcodebuild..."
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
    -scheme Murmur \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$BUILD_DIR" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    -quiet

if [ ! -f "$PRODUCTS_DIR/Murmur" ]; then
    echo "ERROR: build succeeded but no Murmur binary at $PRODUCTS_DIR/Murmur"
    exit 1
fi

echo "Creating app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$PRODUCTS_DIR/Murmur" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Assets/AppIcon.icns "$APP/Contents/Resources/"

# Copy every SPM resource bundle (*.bundle) into the .app's Resources.
# MLX runtime searches NS::Bundle::allBundles() looking for default.metallib,
# so as long as mlx-swift_Cmlx.bundle ends up under Contents/Resources/ it
# gets found at first use. Other dependencies (swift-transformers, etc.)
# may also ship bundles; copying them all keeps everything self-contained.
BUNDLE_COUNT=0
for bundle in "$PRODUCTS_DIR"/*.bundle; do
    if [ -d "$bundle" ]; then
        cp -R "$bundle" "$APP/Contents/Resources/"
        BUNDLE_COUNT=$((BUNDLE_COUNT + 1))
    fi
done
echo "Bundled $BUNDLE_COUNT SPM resource bundles"

# Code sign with stable identity so Accessibility permission persists across
# rebuilds. --deep is required because we have nested .bundle resources
# (default.metallib inside mlx-swift_Cmlx.bundle).
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | head -1 | sed 's/.*"\(.*\)".*/\1/')
if [ -n "$IDENTITY" ]; then
    echo "Signing with: $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "Warning: No signing identity found. Accessibility permission will reset on each rebuild."
    codesign --force --deep --sign - "$APP"
fi

echo "Installing to /Applications..."
pkill -f "Murmur.app/Contents/MacOS/Murmur" 2>/dev/null || true
sleep 0.3
rm -rf /Applications/Murmur.app
cp -R "$APP" /Applications/Murmur.app

echo "Done: /Applications/Murmur.app"
echo "Run: open /Applications/Murmur.app"
