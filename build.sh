#!/usr/bin/env bash
#
# build.sh — Build Hyperglyph and assemble a runnable, ad-hoc-signed Hyperglyph.app.
#
# Usage:  ./build.sh
#
# Idempotent: safe to re-run. Kills any running instance first so the copy and
# codesign steps don't fight a live binary.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP="$ROOT/Hyperglyph.app"

# Stop any running instance so we can safely replace and re-sign the bundle.
pkill -x Hyperglyph || true

echo "==> Building Hyperglyph (release)..."
swift build -c release --product Hyperglyph

BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/Hyperglyph"

if [[ ! -x "$BIN" ]]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

echo "==> Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hyperglyph"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Bundle the OpenMultitouchSupport framework/dylib if the binary links it
# dynamically (via @rpath). If it was linked statically, skip silently.
if otool -L "$BIN" | grep -qi 'OpenMultitouchSupport'; then
    echo "==> Binary links OpenMultitouchSupport dynamically; bundling it..."
    mkdir -p "$APP/Contents/Frameworks"

    FOUND=""
    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        cp -R "$item" "$APP/Contents/Frameworks/"
        FOUND="yes"
    done < <(find "$BIN_DIR" \( -name "*.framework" -o -name "*.dylib" \) -prune 2>/dev/null | grep -i multitouch || true)

    if [[ -z "$FOUND" ]]; then
        echo "warning: binary references OpenMultitouchSupport but no framework/dylib was found under $BIN_DIR" >&2
        echo "         the app may fail to launch; check the SPM build output." >&2
    else
        # Make sure the executable can resolve @rpath references from the bundle.
        install_name_tool -add_rpath @executable_path/../Frameworks \
            "$APP/Contents/MacOS/Hyperglyph" 2>/dev/null || true
    fi
else
    echo "==> OpenMultitouchSupport is statically linked; nothing extra to bundle."
fi

# Sign with a stable identity when possible. Ad-hoc signing ("-") mints a new
# CDHash on every build, and TCC keys the Accessibility grant to that CDHash —
# so each rebuild silently invalidates the permission (the app still shows as
# enabled, but AXIsProcessTrusted() returns false and macOS never re-prompts).
# An "Apple Development" identity keeps the code identity stable across builds.
SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Apple Development' | head -n 1 | awk '{print $2}' || true)"

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> Code signing with Apple Development identity ($SIGN_IDENTITY)..."
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
else
    echo "==> No Apple Development identity found; code signing ad hoc..."
    codesign --force --deep --sign - "$APP"
fi

echo ""
echo "Done. App bundle: $APP"
echo "Launch it with:   open \"$APP\""
echo ""
if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "Note: macOS will ask for Accessibility permission the first time —"
    echo "Hyperglyph needs it to send keyboard shortcuts and block scrolling"
    echo "while you draw. Grant it in System Settings > Privacy & Security >"
    echo "Accessibility, then relaunch if needed."
else
    echo "WARNING: signed ad hoc (no Apple Development identity available)."
    echo "Ad-hoc signatures change on every build, which silently invalidates"
    echo "the Accessibility grant: the app still shows as enabled in System"
    echo "Settings, but hotkeys and scroll suppression will not work."
    echo ""
    echo "After EACH rebuild, remove Hyperglyph from System Settings >"
    echo "Privacy & Security > Accessibility (select it, press '-'), then"
    echo "re-add it (press '+') and relaunch the app."
fi
