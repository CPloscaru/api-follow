#!/bin/bash
# Packages the SPM-built executable into a real .app bundle and launches
# it via `open`. `swift run` runs a bare Mach-O executable, not a proper
# app bundle — macOS's Dock/menu-bar/activation-policy machinery is
# unreliable for GUI apps run that way (documented gotcha, not specific
# to this project). This script is the workaround: same binary, real
# bundle structure, launched the way LaunchServices expects.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP_NAME="APIFollow"
BUNDLE_DIR=".build/${APP_NAME}.app"

echo "Building ($CONFIG)..."
swift build --configuration "$CONFIG"

BIN_PATH="$(swift build --configuration "$CONFIG" --show-bin-path)/${APP_NAME}"

echo "Packaging ${BUNDLE_DIR}..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
cp "$BIN_PATH" "$BUNDLE_DIR/Contents/MacOS/${APP_NAME}"
cp "Sources/${APP_NAME}/Info.plist" "$BUNDLE_DIR/Contents/Info.plist"

# Ad-hoc sign — gives the bundle a stable identity so macOS Keychain
# access (which is identity-scoped) behaves consistently across runs,
# and some GUI/LaunchServices behavior is more reliable for signed
# (even ad-hoc) bundles than fully unsigned ones.
codesign --force --deep --sign - "$BUNDLE_DIR" 2>&1 || echo "Warning: codesign failed, continuing unsigned"

echo "Launching ${BUNDLE_DIR}..."
open "$BUNDLE_DIR"

echo "Done. Look for the dollar-sign icon in your menu bar."
echo "To quit: find the process (ps aux | grep ${APP_NAME}) or Activity Monitor, or Cmd-Q if it has focus."
