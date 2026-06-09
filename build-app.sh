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

# Code-signing strategy depends on what the build is for.
#
# MURMUR_RELEASE=1 → ad-hoc signature (`codesign --sign -`). Use this
# for the DMG you upload to GitHub Releases. An Apple Development
# identity is tied to YOUR Apple ID + a registered provisioning profile,
# so on any other Mac Gatekeeper rejects the bundle as "damaged" — the
# user can't even Right-click → Open out of it. Ad-hoc means "anonymous,
# unverified" — Gatekeeper still shows a "macOS cannot verify…" prompt,
# but the user can dismiss it via Right-click → Open → Open. That is
# the standard friction for any unsigned open-source macOS app and
# users know the workflow.
#
# (no env var, default) → sign with whatever real identity is available
# (Apple Development), so Accessibility permission persists across local
# rebuilds. --deep is required because of nested .bundle resources
# (default.metallib inside mlx-swift_Cmlx.bundle).
#
# Proper Developer-ID-Application + notarization would remove the prompt
# entirely, but that needs a paid Apple Developer Program membership.
if [ "${MURMUR_RELEASE:-0}" = "1" ]; then
    echo "Signing ad-hoc (RELEASE build for GitHub distribution)"
    codesign --force --deep --sign - "$APP"
    # Strip any quarantine attribute the build process may have picked
    # up — the DMG we ship should be as clean as we can make it. Mac
    # users will still get a quarantine attr from their browser on
    # download, that's macOS adding it, not us.
    xattr -cr "$APP" 2>/dev/null || true
else
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | head -1 | sed 's/.*"\(.*\)".*/\1/')
    if [ -n "$IDENTITY" ]; then
        echo "Signing with: $IDENTITY  (dev build — set MURMUR_RELEASE=1 for ad-hoc)"
        codesign --force --deep --sign "$IDENTITY" "$APP"
    else
        echo "Warning: No signing identity found. Accessibility permission will reset on each rebuild."
        codesign --force --deep --sign - "$APP"
    fi
fi

echo "Installing to /Applications..."
pkill -f "Murmur.app/Contents/MacOS/Murmur" 2>/dev/null || true
sleep 0.3
rm -rf /Applications/Murmur.app
cp -R "$APP" /Applications/Murmur.app

echo "Done: /Applications/Murmur.app"
echo "Run: open /Applications/Murmur.app"
