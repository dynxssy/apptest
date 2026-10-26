#!/bin/bash
# Builds RemoteMac.app on a Mac (needs Xcode or the Command Line Tools, macOS 13+).
#   ./build-app.sh            build into ./build/RemoteMac.app
#   ./build-app.sh --install  also copy to /Applications and launch it
#
# macOS ties Screen Recording / Accessibility permission to the app's signature. With the default
# ad-hoc signature you have to re-grant them after every rebuild. To avoid that, create a
# "Code Signing" certificate once in Keychain Access (Certificate Assistant > Create a Certificate,
# type: Code Signing) and run:  SIGN_IDENTITY="That Certificate Name" ./build-app.sh
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/RemoteMac"

APP=build/RemoteMac.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RemoteMac"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R ../web "$APP/Contents/Resources/web"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

codesign --force --deep --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  osascript -e 'quit app "RemoteMac"' 2>/dev/null || true
  # Wait for the old copy to exit, or `open` fails with error -600.
  for _ in $(seq 50); do pgrep -xq RemoteMac || break; sleep 0.1; done
  rm -rf /Applications/RemoteMac.app
  cp -R "$APP" /Applications/
  open /Applications/RemoteMac.app
  echo "Installed and launched /Applications/RemoteMac.app"
fi
