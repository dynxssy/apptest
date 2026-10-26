#!/bin/bash
# Self-hosted WireGuard so your iPhone can reach this Mac from anywhere (mobile data, work Wi-Fi),
# with no cloud service in the middle. The Mac is the WireGuard server; your router forwards one
# UDP port to it. Only traffic for the Mac goes through the tunnel; the phone's normal internet
# use is untouched.
#
#   ./setup-wireguard.sh                 first-time setup + first phone
#   ./setup-wireguard.sh add-phone NAME  add another phone or tablet
#   ./setup-wireguard.sh show NAME       show a phone's QR code again
#   ./setup-wireguard.sh status          tunnel status
#   ./setup-wireguard.sh uninstall       remove the tunnel and its boot service
#
# Keys stay on this Mac: the server config is root-only in $(brew --prefix)/etc/wireguard, phone
# configs in ~/Library/Application Support/RemoteMac/wireguard. Delete a phone config after
# scanning it if you like (./setup-wireguard.sh show needs it, though).
set -euo pipefail

IFACE=remotemac
SUBNET=10.66.0
PORT=${WG_PORT:-51820}
LABEL=local.remotemac.wireguard
PLIST=/Library/LaunchDaemons/$LABEL.plist
USER_DIR="$HOME/Library/Application Support/RemoteMac/wireguard"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname)" = Darwin ] || die "Run this on the Mac."
command -v brew >/dev/null || die "Homebrew is needed: https://brew.sh (then run this again)."
BREW=$(brew --prefix)
CONF_DIR="$BREW/etc/wireguard"
CONF="$CONF_DIR/$IFACE.conf"
mkdir -p "$USER_DIR"
chmod 700 "$USER_DIR"

install_tools() {
  local missing=()
  for f in wireguard-tools qrencode bash; do brew list --formula "$f" >/dev/null 2>&1 || missing+=("$f"); done
  if [ ${#missing[@]} -gt 0 ]; then
    say "Installing ${missing[*]} with Homebrew…"
    brew install "${missing[@]}"
  fi
}

public_endpoint() {
  local saved="$USER_DIR/endpoint"
  if [ -f "$saved" ]; then cat "$saved"; return; fi
  echo >&2
  echo "Your phone needs your home's public address to find the Mac." >&2
  echo "Enter your public IP (or a DNS name for it). Leave empty to look it up now." >&2
  echo "(Looking it up asks OpenDNS, or api.ipify.org if that fails, what your IP is; nothing else is sent.)" >&2
  read -r -p "Public address: " ep
  if [ -z "$ep" ]; then
    ep=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | tail -1)
    # Some networks block outside DNS servers; fall back to a plain HTTPS lookup.
    [ -n "$ep" ] || ep=$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || true)
    [ -n "$ep" ] || die "Couldn't detect it. Find it in your router's status page and run again."
    echo "Detected $ep" >&2
  fi
  echo "$ep" > "$saved"
  echo "$ep"
}

next_ip() {
  local n=2
  while sudo grep -q "AllowedIPs = $SUBNET.$n/32" "$CONF" 2>/dev/null; do n=$((n + 1)); done
  [ $n -lt 255 ] || die "No free addresses left."
  echo "$SUBNET.$n"
}

add_phone() {
  local name=$1
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "Use letters, numbers, - or _ for the phone name."
  local file="$USER_DIR/$name.conf"
  [ -f "$file" ] && die "A phone called $name already exists ($file)."
  local ip key pub server_pub endpoint
  ip=$(next_ip)
  key=$(wg genkey)
  pub=$(echo "$key" | wg pubkey)
  server_pub=$(sudo awk -F' = ' '/^PrivateKey/{print $2}' "$CONF" | wg pubkey)
  endpoint=$(public_endpoint)

  sudo tee -a "$CONF" >/dev/null <<EOF

[Peer]
# $name
PublicKey = $pub
AllowedIPs = $ip/32
EOF

  umask 077
  cat > "$file" <<EOF
[Interface]
PrivateKey = $key
Address = $ip/32

[Peer]
PublicKey = $server_pub
Endpoint = $endpoint:$PORT
AllowedIPs = $SUBNET.1/32
PersistentKeepalive = 25
EOF
  reload
  show "$name"
}

show() {
  local file="$USER_DIR/$1.conf"
  [ -f "$file" ] || die "No phone called $1."
  say "On the iPhone: install the WireGuard app (App Store, free, made by the WireGuard project),"
  echo "tap + > Create from QR code, and scan this:"
  qrencode -t ansiutf8 < "$file"
  qrencode -o "$USER_DIR/$1-qr.png" -s 8 < "$file"
  echo "(Also saved as $USER_DIR/$1-qr.png)"
  echo
  echo "Then in WireGuard, open the tunnel > Edit > On-Demand Activation: turn on Cellular and Wi-Fi."
  echo "RemoteMac's address through the tunnel is: https://$SUBNET.1:8443"
}

reload() {
  if sudo "$BREW/bin/wg" show "$IFACE" >/dev/null 2>&1 || ifconfig | grep -q "inet $SUBNET.1 "; then
    # Apply peer changes without dropping the tunnel.
    sudo bash -c "PATH=$BREW/bin:\$PATH wg syncconf $IFACE <(wg-quick strip '$CONF')" 2>/dev/null ||
      { sudo env PATH="$BREW/bin:$PATH" wg-quick down "$CONF" || true; sudo env PATH="$BREW/bin:$PATH" wg-quick up "$CONF"; }
  else
    sudo env PATH="$BREW/bin:$PATH" wg-quick up "$CONF"
  fi
}

install_service() {
  local runner="$CONF_DIR/remotemac-up.sh"
  sudo tee "$runner" >/dev/null <<EOF
#!/bin/bash
# Started at boot by launchd. Waits for the network, then brings the tunnel up.
export PATH="$BREW/bin:/usr/bin:/bin:/usr/sbin:/sbin"
for i in \$(seq 1 60); do
  if wg show $IFACE >/dev/null 2>&1; then exit 0; fi
  wg-quick up "$CONF" && exit 0
  sleep 5
done
exit 1
EOF
  sudo chmod 755 "$runner"
  sudo tee "$PLIST" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$runner</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>300</integer>
  <key>StandardErrorPath</key><string>/var/log/remotemac-wireguard.log</string>
  <key>StandardOutPath</key><string>/var/log/remotemac-wireguard.log</string>
</dict>
</plist>
EOF
  sudo launchctl bootout system "$PLIST" 2>/dev/null || true
  sudo launchctl bootstrap system "$PLIST"
}

allow_firewall() {
  local fw=/usr/libexec/ApplicationFirewall/socketfilterfw
  local bin
  bin=$(readlink -f "$BREW/bin/wireguard-go" 2>/dev/null || echo "$BREW/bin/wireguard-go")
  if sudo "$fw" --getglobalstate 2>/dev/null | grep -qi enabled; then
    sudo "$fw" --add "$bin" >/dev/null || true
    sudo "$fw" --unblockapp "$bin" >/dev/null || true
  fi
}

setup() {
  install_tools
  if sudo test -f "$CONF"; then
    say "WireGuard for RemoteMac is already set up. Adding a phone instead."
  else
    say "Creating the tunnel ($SUBNET.1 is the Mac, phones get $SUBNET.2 and up)…"
    sudo mkdir -p "$CONF_DIR"
    local key
    key=$(wg genkey)
    sudo bash -c "umask 077; cat > '$CONF'" <<EOF
[Interface]
# RemoteMac: the Mac's end of the tunnel
Address = $SUBNET.1/24
ListenPort = $PORT
PrivateKey = $key
EOF
    sudo chmod 600 "$CONF"
    install_service
    allow_firewall
  fi
  read -r -p "Name for this phone [iphone]: " name
  add_phone "${name:-iphone}"
  local lan
  lan=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "this Mac's IP")
  say "One thing on your router (once):"
  echo "  Forward UDP port $PORT to $lan (this Mac)."
  echo "  Also reserve $lan for this Mac in the router's DHCP settings so it doesn't change."
  echo "  Only this one UDP port is opened; RemoteMac's own ports stay closed to the internet."
}

case "${1:-setup}" in
  setup) setup ;;
  add-phone) install_tools; add_phone "${2:?usage: $0 add-phone NAME}" ;;
  show) show "${2:?usage: $0 show NAME}" ;;
  status) sudo env PATH="$BREW/bin:$PATH" wg show "$IFACE" 2>/dev/null || sudo env PATH="$BREW/bin:$PATH" wg show ;;
  uninstall)
    sudo launchctl bootout system "$PLIST" 2>/dev/null || true
    sudo rm -f "$PLIST" "$CONF_DIR/remotemac-up.sh"
    sudo env PATH="$BREW/bin:$PATH" wg-quick down "$CONF" 2>/dev/null || true
    read -r -p "Also delete the keys and phone configs? [y/N] " yn
    if [ "$yn" = y ]; then sudo rm -f "$CONF"; rm -rf "$USER_DIR"; fi
    say "Removed."
    ;;
  *) die "Unknown command $1" ;;
esac
