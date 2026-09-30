#!/usr/bin/env bash
# Build, sign, and install a local Parrot.app for testing.
#   scripts/dev-install.sh
#
# macOS keys the Accessibility and Microphone grants to the app's code
# identity. An ad-hoc signature changes on every build, so each rebuild
# silently loses the grants. Signing with a Developer ID or Apple Development
# certificate and the fixed bundle ID in packaging/Info.plist keeps one
# identity across rebuilds and releases.
#
# The fork has its own bundle ID, so it refuses to replace a Parrot.app with
# another one, such as upstream's release. Remove that app first.
#
# Installs to /Applications, or ~/Applications when /Applications is not
# writable, and links /usr/local/bin/parrot to the app's executable. A plain
# binary already at that path (an old CLI install) is only replaced after you
# say yes. A running copy is quit and reopened.
#
#   PARROT_SIGN_IDENTITY  signing identity (default: the keychain's Developer ID)
#   PARROT_INSTALL_DIR    where Parrot.app goes
#   PARROT_LINK_DIR       where the parrot link goes (default /usr/local/bin;
#                         set it empty to skip the link)
#   PARROT_NO_RESTART=1   don't quit and reopen a running copy

set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${PARROT_INSTALL_DIR:-}" ]; then
    if [ -w /Applications ]; then
        PARROT_INSTALL_DIR=/Applications
    else
        PARROT_INSTALL_DIR="$HOME/Applications"
    fi
fi
LINK_DIR="${PARROT_LINK_DIR-/usr/local/bin}"
BUILD="${PARROT_BUILD_DIR:-build}"
DEST="$PARROT_INSTALL_DIR/Parrot.app"
EXE="$DEST/Contents/MacOS/parrot"

WANT_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' packaging/Info.plist)"
if [ -d "$DEST" ]; then
    HAVE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || echo unknown)"
    if [ "$HAVE_ID" != "$WANT_ID" ]; then
        echo "! $DEST is $HAVE_ID, not $WANT_ID."
        echo "  Quit it, turn off its login item, and move it to the Trash first."
        exit 1
    fi
fi

VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo 0.0.0)"
PARROT_TIMESTAMP=none PARROT_BUILD_DIR="$BUILD" scripts/build-app.sh "${VERSION#v}"

WAS_RUNNING=0
if [ -z "${PARROT_NO_RESTART:-}" ] && pgrep -f "^$EXE" >/dev/null 2>&1; then
    WAS_RUNNING=1
    echo "→ quitting the running Parrot"
    pkill -TERM -f "^$EXE" || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "^$EXE" >/dev/null 2>&1 || break
        sleep 0.5
    done
fi

echo "→ installing to $DEST"
mkdir -p "$PARROT_INSTALL_DIR"
rm -rf "$DEST"
ditto "$BUILD/Parrot.app" "$DEST"

if [ -n "$LINK_DIR" ]; then
    LINK="$LINK_DIR/parrot"
    REPLACE=1
    if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
        REPLACE=0
        if [ -t 0 ]; then
            printf '%s is a separate parrot binary (an old CLI install). Replace it with a link to %s? [y/N] ' "$LINK" "$EXE"
            read -r answer
            case "$answer" in y|Y|yes) REPLACE=1 ;; esac
        fi
        [ "$REPLACE" = 1 ] || echo "  left $LINK as it was"
    fi
    if [ "$REPLACE" = 1 ]; then
        echo "→ linking $LINK"
        mkdir -p "$LINK_DIR" 2>/dev/null || sudo mkdir -p "$LINK_DIR"
        SUDO=""
        [ -w "$LINK_DIR" ] || SUDO="sudo"
        $SUDO ln -sfn "$EXE" "$LINK"
    fi
fi

if [ "$WAS_RUNNING" = 1 ]; then
    echo "→ reopening Parrot"
    open "$DEST"
fi

if [ -f "$HOME/Library/LaunchAgents/com.digimata.parrot.plist" ]; then
    echo "note: the old LaunchAgent is still installed. Open $DEST once; it removes the agent."
fi

echo "✓ installed Parrot $("$EXE" --version 2>/dev/null || echo "$VERSION") at $DEST"
