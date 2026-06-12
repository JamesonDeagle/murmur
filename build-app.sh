#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP="Murmur.app"

# Plain SPM release build. After the whisper-only strip there are no MLX
# dependencies left, so we no longer need xcodebuild to compile a Metal
# metallib (whisper.cpp's Metal shaders are pre-compiled into the static
# libs in lib/ via lib/ggml-metal-embed.metal). swift build is faster and
# matches what build-mas.sh does.
echo "Building Murmur via swift build..."
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release

BIN=".build/release/Murmur"
if [ ! -f "$BIN" ]; then
    echo "ERROR: build succeeded but no Murmur binary at $BIN"
    exit 1
fi

echo "Creating app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN"                          "$APP/Contents/MacOS/"
cp Info.plist                      "$APP/Contents/"
cp Assets/AppIcon.icns             "$APP/Contents/Resources/"
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"
# License + third-party attribution (whisper.cpp / ggml are MIT — their
# notices ship next to the binary that statically links them).
cp LICENSE                         "$APP/Contents/Resources/"
cp THIRD-PARTY-LICENSES.md         "$APP/Contents/Resources/"

# Glow shader (v3.23): compile GlowField.metal → default.metallib and drop
# it into the app's Resources. `swift build` does NOT run the Metal
# compiler, so the .metal source alone gives no runtime shader — the app
# would silently fall back to the old FlowingGradient. We compile it
# explicitly with the Metal toolchain (installed since v3.10). The runtime
# loader (GlowShaderSupport) probes Bundle.main for any *.metallib first, so
# `ShaderLibrary.default` resolves `glowField` from this file. If
# compilation fails for any reason we DON'T abort the build — the app still
# works via the gradient fallback — but we shout about it.
METAL_SRC="Sources/Murmur/Shaders/GlowField.metal"
METALLIB_OUT="$APP/Contents/Resources/default.metallib"
echo "Compiling glow shader -> $METALLIB_OUT"
if xcrun -sdk macosx metal -std=metal3.0 -c "$METAL_SRC" -o /tmp/glowfield.air 2>/tmp/glowfield.metal.log \
   && xcrun -sdk macosx metallib /tmp/glowfield.air -o "$METALLIB_OUT" 2>>/tmp/glowfield.metal.log; then
    echo "  metallib OK ($(du -h "$METALLIB_OUT" | cut -f1))"
else
    echo "  WARNING: metallib compile failed — app will use FlowingGradient fallback."
    echo "  See /tmp/glowfield.metal.log"
    rm -f "$METALLIB_OUT"
fi

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
# (Apple Development), so Accessibility / post-event permission persists
# across local rebuilds.
#
# This is the GitHub/DMG path. The Mac App Store build goes through
# build-mas.sh (3rd Party Mac Developer certs + entitlements + .pkg).
if [ "${MURMUR_RELEASE:-0}" = "1" ]; then
    echo "Signing ad-hoc (RELEASE build for GitHub distribution)"
    codesign --force --sign - "$APP"
    # Strip any quarantine attribute the build process may have picked
    # up — the DMG we ship should be as clean as we can make it. Mac
    # users will still get a quarantine attr from their browser on
    # download, that's macOS adding it, not us.
    xattr -cr "$APP" 2>/dev/null || true
else
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | head -1 | sed 's/.*"\(.*\)".*/\1/')
    if [ -n "$IDENTITY" ]; then
        echo "Signing with: $IDENTITY  (dev build — set MURMUR_RELEASE=1 for ad-hoc)"
        codesign --force --sign "$IDENTITY" "$APP"
    else
        echo "Warning: No signing identity found. Permissions will reset on each rebuild."
        codesign --force --sign - "$APP"
    fi
fi

echo "Installing to /Applications..."
pkill -f "Murmur.app/Contents/MacOS/Murmur" 2>/dev/null || true
sleep 0.3
rm -rf /Applications/Murmur.app
cp -R "$APP" /Applications/Murmur.app

echo "Done: /Applications/Murmur.app"
echo "Run: open /Applications/Murmur.app"
