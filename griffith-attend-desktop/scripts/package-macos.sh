#!/usr/bin/env bash
#
# Build a macOS .app bundle and a .dmg for the GUI client.
#
# Run this ON a Mac (it uses macOS-only tools: hdiutil, and optionally
# codesign). It cannot run on Linux. From the project root:
#
#     ./scripts/package-macos.sh
#
# Output:
#     dist/Griffith Attendance.app
#     dist/GriffithAttendance.dmg
#
set -euo pipefail

APP_NAME="Griffith Attendance"
BIN_NAME="griffith-attend-gui"
BUNDLE_ID="ie.griffith.attendance.desktop"
VERSION="$(grep -m1 '^version' Cargo.toml | sed -E 's/.*"(.*)".*/\1/')"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "This script must run on macOS (needs hdiutil)." >&2
  exit 1
fi

echo "==> Building universal release binary"
# Build for both Apple architectures and merge, so the .app runs on Intel and
# Apple Silicon. If you only need your own machine, a single `cargo build
# --release` and copying target/release/$BIN_NAME also works.
rustup target add x86_64-apple-darwin aarch64-apple-darwin >/dev/null 2>&1 || true
cargo build --release --bin "$BIN_NAME" --target x86_64-apple-darwin
cargo build --release --bin "$BIN_NAME" --target aarch64-apple-darwin

BIN="target/universal-$BIN_NAME"
lipo -create -output "$BIN" \
  "target/x86_64-apple-darwin/release/$BIN_NAME" \
  "target/aarch64-apple-darwin/release/$BIN_NAME"

echo "==> Assembling .app bundle"
rm -rf dist
APP_DIR="dist/$APP_NAME.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/$BIN_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$BIN_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>$BIN_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Required so macOS lets the app use Bluetooth (the presence check). -->
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Detects your classroom's beacon to confirm you are present before checking in.</string>
</dict>
</plist>
PLIST

# Optional ad-hoc signature so Gatekeeper is less noisy on your own machine.
# For distribution to others you need a Developer ID cert + notarization.
if command -v codesign >/dev/null 2>&1; then
  echo "==> Ad-hoc signing"
  codesign --force --deep --sign - "$APP_DIR" || echo "   (ad-hoc signing skipped)"
fi

echo "==> Creating .dmg"
hdiutil create -volname "$APP_NAME" \
  -srcfolder "$APP_DIR" \
  -ov -format UDZO \
  "dist/GriffithAttendance.dmg"

echo "==> Done:"
echo "    $APP_DIR"
echo "    dist/GriffithAttendance.dmg"
