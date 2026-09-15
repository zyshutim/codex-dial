#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$(dirname "$SOURCE_DIR")"
BUILD_DIR="${CODEXDIAL_BUILD_DIR:-$SOURCE_DIR/.build}"
APP_DIR="${CODEXDIAL_APP_DIR:-$OUTPUT_DIR/Codex Dial.app}"
/Library/Developer/CommandLineTools/usr/bin/swift build --package-path "$SOURCE_DIR" --scratch-path "$BUILD_DIR" -c release
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/release/CodexDial" "$APP_DIR/Contents/MacOS/CodexDial"
cp "$SOURCE_DIR/Resources/"*.py "$APP_DIR/Contents/Resources/"
cp "$SOURCE_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Codex Dial</string>
<key>CFBundleDisplayName</key><string>Codex Dial</string>
<key>CFBundleExecutable</key><string>CodexDial</string>
<key>CFBundleIdentifier</key><string>dev.local.codexdial</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.10</string>
<key>CFBundleVersion</key><string>15</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAccessibilityUsageDescription</key><string>通过当前 Codex 窗口的会话链接识别目标，切换你保存的模型和思考深度。</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - --identifier dev.local.codexdial "$APP_DIR"
echo "Built: $APP_DIR"
