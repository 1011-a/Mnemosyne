#!/bin/bash
# Build Mnemosyne and wrap the SwiftPM binary into a double-clickable .app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Mnemosyne.app"
CONTENTS="$APP/Contents"
BUNDLE_ID="${MNEMOSYNE_BUNDLE_ID:-com.mnemosyne.app}"
VERSION="${MNEMOSYNE_VERSION:-0.7.0}"

echo "▸ Building release…"
cd "$ROOT"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/Mnemosyne"
[ -x "$BIN" ] || { echo "✗ binary not found at $BIN"; exit 1; }

echo "▸ Assembling bundle at $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/Mnemosyne"

echo "▸ Generating app icon…"
ICNS="$ROOT/build/Mnemosyne.icns"
swift "$ROOT/scripts/generate-icon.swift" "$ICNS" >/dev/null 2>&1 || echo "  (icon generation skipped)"
[ -f "$ICNS" ] && cp "$ICNS" "$CONTENTS/Resources/Mnemosyne.icns"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Mnemosyne</string>
  <key>CFBundleDisplayName</key>     <string>Mnemosyne</string>
  <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key>         <string>${VERSION}</string>
  <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
  <key>CFBundleExecutable</key>      <string>Mnemosyne</string>
  <key>CFBundleIconFile</key>        <string>Mnemosyne</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
  <key>LSApplicationCategoryType</key> <string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key> <true/>
  <key>NSHumanReadableCopyright</key> <string>© 2026 Mnemosyne contributors.</string>
  <key>NSSpeechRecognitionUsageDescription</key> <string>Mnemosyne transcribes your audio files on-device to make them searchable.</string>
  <key>NSMicrophoneUsageDescription</key> <string>Mnemosyne uses the microphone for voice input in the Ask box.</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSExceptionDomains</key>
    <dict>
      <key>127.0.0.1</key>
      <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
      </dict>
      <key>localhost</key>
      <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
      </dict>
    </dict>
  </dict>
</dict>
</plist>
PLIST

# Ad-hoc codesign so Gatekeeper lets it run locally.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo "✓ Built $APP"
echo "  Launch with: open \"$APP\"   (Network access for DeepSeek; local Ollama for Gemma)"
