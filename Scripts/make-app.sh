#!/bin/zsh
# Builds SimpleWhisper in release mode and wraps it in a .app bundle (needed for the
# microphone / Input Monitoring / Accessibility permission prompts), then launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/SimpleWhisper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/SimpleWhisper" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

# SwiftPM resource bundles and dynamic frameworks, if any.
for bundle in "$BIN_DIR"/*.bundle(N); do cp -R "$bundle" "$APP/Contents/Resources/"; done
for framework in "$BIN_DIR"/*.framework(N); do cp -R "$framework" "$APP/Contents/Frameworks/"; done
for dylib in "$BIN_DIR"/*.dylib(N); do cp -R "$dylib" "$APP/Contents/Frameworks/"; done

# Ad-hoc signature with an explicit designated requirement based only on the bundle identifier.
# TCC stores that requirement when you grant Accessibility / Input Monitoring / Microphone, so the
# grants survive rebuilds (a plain ad-hoc signature is keyed to the binary hash and breaks every build).
codesign --force --deep --sign - --identifier pl.wojas.SimpleWhisper \
  -r='designated => identifier "pl.wojas.SimpleWhisper"' "$APP"

echo "Built $APP"
if [[ "${2:-open}" == "open" ]]; then
  pkill -x SimpleWhisper 2>/dev/null && sleep 1 || true
  open "$APP"
fi
