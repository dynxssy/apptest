# RemoteMac

Control your Mac from your iPhone, at home or away: live screen with sound, mouse and keyboard,
the Mac's camera, and a built-in keep-awake (caffeinate). Nothing runs in the cloud: the phone talks
straight to the Mac, over your Wi-Fi at home or a WireGuard tunnel to your home connection everywhere else.

```
iPhone (home-screen web app)                         Mac (menu bar app)
  Safari / WebCodecs  ── wss://10.66.0.1:8443 ──►  RemoteMac.app
        │                                            ├ ScreenCaptureKit → H.264 (hardware) + system audio
   WireGuard app  ══ UDP 51820 via your router ══►   ├ CGEvent mouse & keyboard
                                                     ├ AVFoundation camera → H.264
                                                     └ IOKit power assertions (keep awake)
```

## What you get

- **Screen + sound**: hardware H.264 at up to 2560 px / 60 fps, plus the Mac's audio. Quality adapts
  when mobile data gets slow (Auto, Data saver, Balanced, Best).
- **Control**: trackpad mode (drag moves the pointer, tap clicks, two-finger tap right-clicks,
  press-and-hold then drag to drag, two fingers scroll) or touch mode (tap exactly where you want).
  Pinch to zoom in on any part of the screen.
- **Keyboard**: the iPhone keyboard types on the Mac, plus a key bar with esc, tab, arrows, ⌘ ⌥ ⌃ ⇧
  (tap to hold for the next key, double-tap to lock), and shortcuts like ⌘C, ⌘V, ⌘Tab, Spotlight,
  Mission Control.
- **Camera**: watch the Mac's camera (built-in, external or Continuity Camera), mirror it, save a photo.
- **Keep awake**: Off, while a phone is connected, always, or for 1/4/12 hours. Optionally keeps the
  display on too. Set it from the phone or the menu bar.
- **Extras**: clipboard both ways, volume up/down/mute, screen off, lock, multiple displays.

## Setup

### 1. Get the Mac app

Either download the build from GitHub: **Actions** tab > latest **build** run > **RemoteMac-app**
artifact, unzip, move `RemoteMac.app` to Applications, then right-click it > **Open** the first time
(it's not notarized).

Or build it yourself (needs Xcode or `xcode-select --install`, macOS 13 or newer):

```sh
git clone -b remote-mac https://github.com/dynxssy/apptest.git remote-mac
cd remote-mac/mac
./build-app.sh --install
```

On first launch macOS asks for **Screen Recording**, **Accessibility** and **Camera**. Allow all
three (System Settings > Privacy & Security). The menu bar icon > **Permissions** shows what's on.

> Rebuilding with the default ad-hoc signature makes macOS forget those permissions. See the top of
> `mac/build-app.sh` for how to sign with a stable local certificate.

### 2. Set up access from anywhere (WireGuard)

```sh
./wireguard/setup-wireguard.sh
```

It installs `wireguard-tools` with Homebrew, makes the keys on the Mac, starts the tunnel at boot,
and prints a QR code. On the iPhone, install **WireGuard** from the App Store, tap **+ > Create from
QR code**, scan it, then turn on **On-Demand** for Cellular and Wi-Fi so it's always connected.

On your router, forward **UDP 51820** to the Mac and give the Mac a fixed (reserved) IP. That's the
only port opened to the internet; RemoteMac itself is only reachable through the tunnel or your
home network.

If your home IP changes now and then, re-run with a new address (delete
`~/Library/Application Support/RemoteMac/wireguard/endpoint` first), or use a DNS name for it.

### 3. Pair the iPhone

1. Click the menu bar icon > **Pair a Phone**.
2. With WireGuard on, open `http://10.66.0.1:8080` in Safari on the iPhone and install the certificate:
   **Settings > Profile Downloaded > Install**, then **Settings > General > About > Certificate Trust
   Settings** and switch on **RemoteMac Local CA**. (The certificate is made on your Mac; it lets the
   phone open the app over HTTPS, which the video decoder requires.)
3. Scan the pairing QR code with the iPhone camera.
4. In Safari tap **Share > Add to Home Screen**. Open RemoteMac from the home screen from now on.

### Keeping the Mac reachable

RemoteMac's keep-awake stops idle sleep. A few macOS settings make it sturdier:

```sh
sudo pmset -a womp 1          # wake for network access
sudo pmset -a autorestart 1   # turn back on after a power cut
sudo pmset -c sleep 0         # never sleep on the charger
```

Closing a MacBook's lid still sleeps it unless it's on power with an external display. If the Mac
locks, you'll see and can use the lock screen picture, but typing the password into the login window
from the phone may not work (macOS restricts it), so set **Require password after screen saver**
to a long delay if you rely on this.

## Security

- The phone needs the pairing token (in the QR code) to do anything. Wrong tokens are throttled.
  **Menu bar > New Pairing Code** revokes every paired phone.
- All traffic is encrypted twice from outside: WireGuard, then TLS to the app.
- Keys, the token and tunnel configs live only in `~/Library/Application Support/RemoteMac` and
  `$(brew --prefix)/etc/wireguard`. `.gitignore` blocks them from this repo.
- No third-party servers. The only outside lookup is the optional public-IP check in the WireGuard
  script (it asks OpenDNS), and you can type the IP in instead.

## Project layout

| Path | What |
|---|---|
| `mac/` | Swift menu bar app (Swift Package, `build-app.sh` makes the .app) |
| `web/` | Phone web app, plain HTML/CSS/JS, served by the Mac app |
| `wireguard/setup-wireguard.sh` | Tunnel setup, add phones, status, uninstall |
| `tools/mock-server.mjs` | Fake Mac (test pattern video + tone) for working on the web app anywhere |
| `tools/test-web.cjs` | End-to-end test of the web app in an emulated iPhone |
| `docs/PROTOCOL.md` | WebSocket protocol between phone and Mac |

Work on the web app without a Mac:

```sh
node tools/mock-server.mjs        # then open http://localhost:8090/#t=testtoken
node tools/test-web.cjs           # needs ffmpeg and Playwright
```

## Status

Written in a Linux cloud session, so the macOS parts have **not been run yet**:

| Part | State |
|---|---|
| Phone web app (video decode, audio, gestures, keyboard, settings, camera view, reconnect) | Tested against the mock server in emulated iPhone Chromium (35 checks). Not yet on a real iPhone/Safari. |
| TLS certificate commands | Tested with OpenSSL on Linux (chain verifies, SANs correct). |
| Mac app compile | Checked by the GitHub Actions `build` job on a macOS runner. |
| Screen/audio capture, input, camera, keep-awake, menu bar | Not run yet. Needs a test on the Mac. |
| WireGuard script | Syntax and shellcheck clean. Not run yet. |
