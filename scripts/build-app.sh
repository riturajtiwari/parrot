#!/usr/bin/env bash
# Builds the release binary and wraps it in a signed Parrot.app.
#   scripts/build-app.sh [version]        → build/Parrot.app
#
# The version (a tag such as v0.1.0 or 0.1.0) goes into
# CFBundleShortVersionString and CFBundleVersion. Without one it comes from
# the latest tag, or 0.0.0.
#
# Embeds Sparkle.framework (in-app updates, #50) in Contents/Frameworks and
# signs it inside-out before the app: its XPC services, Autoupdate, and
# Updater.app, then the framework, all with the same identity and the
# hardened runtime, as notarization requires.
#
# Signs with the first "Developer ID Application" identity in the keychain,
# else the first "Apple Development" one (free with an Apple ID in Xcode),
# with the hardened runtime and packaging/Parrot.entitlements. The
# designated requirement then names the bundle ID and the team, not a
# cdhash, so macOS keeps the Microphone and Accessibility grants across
# builds. Without an identity the app is ad-hoc signed and every build is a
# new identity; the script says so.
#
#   PARROT_SIGN_IDENTITY   signing identity (default: the keychain's Developer
#                          ID, else its Apple Development identity)
#   PARROT_TIMESTAMP=none  skip the secure timestamp (local builds, offline);
#                          notarization needs it, so releases leave this unset
#   PARROT_BUILD_DIR       output directory (default: build)

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)}"
VERSION="${VERSION#v}"
OUT="${PARROT_BUILD_DIR:-build}"
APP="$OUT/Parrot.app"

IDENTITY="${PARROT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
fi

echo "→ building parrot $VERSION (release, arm64)"
# --disable-keychain: every dependency is public, and SwiftPM otherwise asks
# the login Keychain for github.com credentials, which can wait forever on
# a hidden access prompt.
swift build -c release --arch arm64 --disable-keychain --product parrot
BIN="$(swift build -c release --arch arm64 --disable-keychain --show-bin-path)/parrot"

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/parrot"
# SwiftPM links Sparkle through @rpath and puts the framework beside the
# binary; in the bundle it lives in Contents/Frameworks.
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/parrot"
strip -x "$APP/Contents/MacOS/parrot"
mkdir -p "$APP/Contents/Frameworks"
ditto "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp packaging/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# SwiftPM's resource bundles (swift-transformers' fallback tokenizer
# configs, swift-crypto's privacy manifest) are left out, as they were from
# the bare binary: their accessors look beside the .app, where a signed
# bundle can't hold anything.

# docs/assets/app-icon.png is the bird on a white rounded square, drawn by
# scripts/make-app-icon.swift from docs/assets/icon.png.
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" docs/assets/app-icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" docs/assets/app-icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

TIMESTAMP="--timestamp"
[ "${PARROT_TIMESTAMP:-}" = "none" ] && TIMESTAMP="--timestamp=none"

if [ -n "$IDENTITY" ]; then
    echo "→ signing as $IDENTITY"
    SIGN_AS="$IDENTITY"
else
    echo "! no Developer ID Application or Apple Development identity; ad-hoc signing."
    echo "  Permissions will not survive the next build, and the app can't be notarized."
    SIGN_AS="-"
    TIMESTAMP="--timestamp=none"
fi

# Inside-out: each nested bundle before the one that contains it, as in
# Sparkle's documentation. Downloader.xpc keeps its entitlements.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for nested in \
    "$SPARKLE/XPCServices/Installer.xpc" \
    "$SPARKLE/XPCServices/Downloader.xpc" \
    "$SPARKLE/Autoupdate" \
    "$SPARKLE/Updater.app" \
    "$APP/Contents/Frameworks/Sparkle.framework"; do
    codesign --force --options runtime $TIMESTAMP --preserve-metadata=entitlements \
        --sign "$SIGN_AS" "$nested"
done
codesign --force --options runtime $TIMESTAMP \
    --entitlements packaging/Parrot.entitlements \
    --sign "$SIGN_AS" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
echo "  designated requirement: $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
echo "$APP"
