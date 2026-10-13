#!/usr/bin/env bash
#
# One-command installer for the Griffith Attendance desktop app.
#
#   curl -fsSL https://raw.githubusercontent.com/dynxssy/apptest/claude/awesome-hawking-2lsuwj/griffith-attend-desktop/install.sh | bash
#
# It detects and (where possible) installs everything needed — Rust, the
# platform build tools, the Bluetooth/GUI libraries — fetches the source,
# builds a release binary, and places the app on your Desktop. Safe to re-run.
#
# Overridable with env vars: GRIFFITH_REPO, GRIFFITH_BRANCH, GRIFFITH_SRC.
set -euo pipefail

REPO="${GRIFFITH_REPO:-https://github.com/dynxssy/apptest}"
BRANCH="${GRIFFITH_BRANCH:-claude/awesome-hawking-2lsuwj}"
SUBDIR="griffith-attend-desktop"
SRC_DIR="${GRIFFITH_SRC:-$HOME/.griffith-attend/src}"
DESKTOP="${HOME}/Desktop"
APP_NAME="Griffith Attendance"
GUI_BIN="griffith-attend-gui"
CLI_BIN="griffith-attend"

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

OS="$(uname -s)"

# ---------------------------------------------------------------------------
# sudo helper (no-op when already root)
# ---------------------------------------------------------------------------
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi
fi

# ---------------------------------------------------------------------------
# 1. Build tools (compiler, git) and platform libraries
# ---------------------------------------------------------------------------
install_system_deps() {
  log "Checking system build tools"
  case "$OS" in
    Darwin)
      if ! xcode-select -p >/dev/null 2>&1 || ! command -v cc >/dev/null 2>&1; then
        warn "Xcode Command Line Tools are needed (compiler + git)."
        warn "A system dialog will open — click Install and let it finish."
        xcode-select --install >/dev/null 2>&1 || true
        printf '  Waiting for the Command Line Tools to finish installing'
        for _ in $(seq 1 180); do
          if xcode-select -p >/dev/null 2>&1 && command -v cc >/dev/null 2>&1; then break; fi
          printf '.'; sleep 10
        done
        printf '\n'
        command -v cc >/dev/null 2>&1 || die "Command Line Tools not detected. Re-run this command once the installer finishes."
      fi
      ok "Build tools present (macOS uses the system Core Bluetooth; no extra libs)."
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        log "Installing build libraries with apt"
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -y
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
          build-essential pkg-config git \
          libdbus-1-dev libxkbcommon-dev libgl1-mesa-dev
      elif command -v dnf >/dev/null 2>&1; then
        log "Installing build libraries with dnf"
        $SUDO dnf install -y gcc gcc-c++ make pkgconf-pkg-config git \
          dbus-devel libxkbcommon-devel mesa-libGL-devel
      elif command -v pacman >/dev/null 2>&1; then
        log "Installing build libraries with pacman"
        $SUDO pacman -S --needed --noconfirm base-devel pkgconf git \
          dbus libxkbcommon mesa
      elif command -v zypper >/dev/null 2>&1; then
        log "Installing build libraries with zypper"
        $SUDO zypper install -y -t pattern devel_basis || true
        $SUDO zypper install -y pkgconf git dbus-1-devel libxkbcommon-devel Mesa-libGL-devel
      else
        warn "Unknown Linux distro — install these yourself: a C toolchain, pkg-config, git,"
        warn "dbus dev headers, libxkbcommon dev, and an OpenGL (mesa) dev package."
      fi
      ok "System libraries ready."
      ;;
    *)
      die "Unsupported OS: $OS (this installer handles macOS and Linux)."
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 2. Rust toolchain
# ---------------------------------------------------------------------------
install_rust() {
  log "Checking Rust"
  if ! command -v cargo >/dev/null 2>&1; then
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env" || true
  fi
  if ! command -v cargo >/dev/null 2>&1; then
    log "Installing Rust via rustup (non-interactive)"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
    . "$HOME/.cargo/env"
  fi
  command -v cargo >/dev/null 2>&1 || die "cargo still not found after install."
  ok "Rust $(rustc --version | awk '{print $2}') ready."
}

# ---------------------------------------------------------------------------
# 3. Fetch source
# ---------------------------------------------------------------------------
fetch_source() {
  log "Fetching source ($BRANCH)"
  if [ -d "$SRC_DIR/.git" ]; then
    git -C "$SRC_DIR" fetch --depth 1 origin "$BRANCH"
    git -C "$SRC_DIR" checkout -q "$BRANCH"
    git -C "$SRC_DIR" reset --hard -q "origin/$BRANCH"
  else
    mkdir -p "$(dirname "$SRC_DIR")"
    rm -rf "$SRC_DIR"
    git clone --depth 1 --branch "$BRANCH" "$REPO" "$SRC_DIR"
  fi
  [ -d "$SRC_DIR/$SUBDIR" ] || die "Project directory $SUBDIR not found in the repo."
  ok "Source at $SRC_DIR/$SUBDIR"
}

# ---------------------------------------------------------------------------
# 4. Build
# ---------------------------------------------------------------------------
build_app() {
  log "Building (release) — this takes a few minutes the first time"
  ( cd "$SRC_DIR/$SUBDIR" && cargo build --release --bin "$GUI_BIN" --bin "$CLI_BIN" )
  ok "Build complete."
}

# ---------------------------------------------------------------------------
# 5. Install to Desktop
# ---------------------------------------------------------------------------
install_desktop() {
  mkdir -p "$DESKTOP"
  local rel="$SRC_DIR/$SUBDIR/target/release"
  case "$OS" in
    Darwin)
      log "Assembling the app bundle onto your Desktop"
      local app="$DESKTOP/$APP_NAME.app"
      rm -rf "$app"
      mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
      cp "$rel/$GUI_BIN" "$app/Contents/MacOS/$GUI_BIN"
      chmod +x "$app/Contents/MacOS/$GUI_BIN"
      local ver
      ver="$(grep -m1 '^version' "$SRC_DIR/$SUBDIR/Cargo.toml" | sed -E 's/.*"(.*)".*/\1/')"
      cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>ie.griffith.attendance.desktop</string>
  <key>CFBundleVersion</key><string>$ver</string>
  <key>CFBundleShortVersionString</key><string>$ver</string>
  <key>CFBundleExecutable</key><string>$GUI_BIN</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Detects your classroom's beacon to confirm you are present before checking in.</string>
</dict></plist>
PLIST
      command -v codesign >/dev/null 2>&1 && codesign --force --deep --sign - "$app" >/dev/null 2>&1 || true
      ok "Installed: $app"
      echo
      log "Done! Double-click \"$APP_NAME\" on your Desktop to launch it."
      warn "First launch: right-click the app → Open (to get past Gatekeeper the first time),"
      warn "and allow the Bluetooth permission prompt."
      ;;
    Linux)
      log "Placing the app on your Desktop"
      cp "$rel/$GUI_BIN" "$DESKTOP/$GUI_BIN"
      cp "$rel/$CLI_BIN" "$DESKTOP/$CLI_BIN" 2>/dev/null || true
      chmod +x "$DESKTOP/$GUI_BIN" "$DESKTOP/$CLI_BIN" 2>/dev/null || true
      cat > "$DESKTOP/GriffithAttendance.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=$APP_NAME
Comment=Beacon-gated attendance check-in
Exec=$DESKTOP/$GUI_BIN
Terminal=false
Categories=Education;
DESK
      chmod +x "$DESKTOP/GriffithAttendance.desktop"
      ok "Installed: $DESKTOP/$GUI_BIN and a launcher."
      echo
      log "Done! Launch it with the Desktop launcher, or run: $DESKTOP/$GUI_BIN"
      warn "Make sure Bluetooth is on and the 'bluetooth' service is running."
      ;;
  esac
}

main() {
  printf '\033[1m%s installer\033[0m\n' "$APP_NAME"
  install_system_deps
  install_rust
  # Make sure cargo is on PATH for the rest of this script.
  command -v cargo >/dev/null 2>&1 || { [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"; }
  fetch_source
  build_app
  install_desktop
}

main "$@"
