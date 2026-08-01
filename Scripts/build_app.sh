#!/bin/bash
# Builds InputMethodAutoChange and wraps it into a proper .app bundle.
#
# This step matters beyond packaging convenience: Accessibility and Input
# Monitoring permissions (TCC) are granted per app bundle/executable
# identity, and several system APIs this app relies on behave more
# predictably when run from a real .app rather than a bare CLI binary from
# `swift build`.
#
# Signing identity: sign with a stable local certificate if one is
# installed (see below), otherwise fall back to ad-hoc (`codesign -s -`).
#
# Ad-hoc's identity is derived from the binary's own hash, so it changes on
# every rebuild — macOS treats each build as a brand new app and TCC
# (Accessibility/Input Monitoring) permission has to be re-granted every
# time. A locally self-signed code-signing certificate has a *stable*
# identity independent of the binary's content, so TCC grants survive
# rebuilds once you're signing with one.
#
# One-time setup: Keychain Access → Certificate Assistant → Create a
# Certificate… → Identity Type: Self Signed Root, Certificate Type: Code
# Signing → name it (default below expects "InputMethodAutoChange Local
# Signing"). After switching to it you'll need to re-grant Accessibility
# once more (the identity changed from ad-hoc to the cert) — after that it
# should persist across rebuilds.
SIGNING_IDENTITY="${SIGNING_IDENTITY:-InputMethodAutoChange Local Signing}"

set -euo pipefail

CONFIG="${1:-debug}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="InputMethodAutoChange"
APP_BUNDLE="$ROOT_DIR/.build/$APP_NAME.app"

echo "Building (${CONFIG})..."
swift build -c "$CONFIG" --package-path "$ROOT_DIR"

BIN_PATH="$ROOT_DIR/.build/$CONFIG/$APP_NAME"
if [ ! -f "$BIN_PATH" ]; then
	echo "error: built binary not found at $BIN_PATH" >&2
	exit 1
fi

echo "Assembling ${APP_BUNDLE}..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

if security find-certificate -c "$SIGNING_IDENTITY" >/dev/null 2>&1; then
	echo "Codesigning with \"$SIGNING_IDENTITY\"..."
	codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
else
	echo "Codesigning ad-hoc (no \"$SIGNING_IDENTITY\" certificate found -- Accessibility will need re-granting after every rebuild; see the note above to fix that)..."
	codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "Done: $APP_BUNDLE"
echo "Run with: open \"$APP_BUNDLE\""
