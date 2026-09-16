#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$(dirname "$SOURCE_DIR")"
APP_DIR="${CODEXDIAL_APP_DIR:-$OUTPUT_DIR/Codex Dial.app}"
bash "$SOURCE_DIR/build.sh"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")
ARCHIVE="${CODEXDIAL_ARCHIVE:-$OUTPUT_DIR/Codex-Dial-$VERSION-arm64.zip}"
/usr/bin/python3 "$SOURCE_DIR/Scripts/package_release.py" "$APP_DIR" "$ARCHIVE"
