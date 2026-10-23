#!/usr/bin/env bash
# Builds build/DictFlow.app (Command Line Tools only). Set DICTFLOW_SIGN_IDENTITY for a stable self-signed cert.
# ./build.sh --install also copies it to /Applications/DictFlow.app (so Spotlight finds it).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/DictFlow.app"

swift build -c release --package-path "$ROOT/app"
BIN="$(swift build -c release --package-path "$ROOT/app" --show-bin-path)/DictFlow"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/DictFlow"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>pt.franciscoribeiro.dictflow</string>
  <key>CFBundleName</key><string>DictFlow</string>
  <key>CFBundleExecutable</key><string>DictFlow</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>O DictFlow precisa do microfone para ouvir o que ditas e transcrever.</string>
  <key>DictFlowProjectDir</key><string>$ROOT</string>
</dict>
</plist>
PLIST

codesign --force --sign "${DICTFLOW_SIGN_IDENTITY:--}" "$APP"
echo "built $APP"

if [ "${1:-}" = "--install" ]; then
  DEST="/Applications/DictFlow.app"
  TMP="/Applications/.DictFlow.app.new"
  rm -rf "$TMP"
  ditto "$APP" "$TMP"   # ditto keeps the bundle and its signature intact
  codesign --verify --deep --strict "$TMP"
  if [ -n "${DICTFLOW_SIGN_IDENTITY:-}" ]; then
    INFO="$(codesign -dvv "$TMP" 2>&1)"   # not piped into grep -q: SIGPIPE would trip pipefail
    grep -qx "Authority=$DICTFLOW_SIGN_IDENTITY" <<<"$INFO" \
      || { rm -rf "$TMP"; echo "copy is not signed by '$DICTFLOW_SIGN_IDENTITY'; $DEST left untouched" >&2; exit 1; }
  else
    echo "warning: ad-hoc signature; macOS will ask for the permissions again" >&2
  fi
  if [ -e "$DEST" ]; then mv "$DEST" "/Applications/.DictFlow.app.old"; fi
  mv "$TMP" "$DEST"
  rm -rf "/Applications/.DictFlow.app.old"
  echo "installed $DEST"
fi
