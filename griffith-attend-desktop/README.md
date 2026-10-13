# Griffith College Attendance — Desktop client (unofficial)

A Rust port of the Griffith College attendance mobile client for **Linux and
macOS laptops**. It reproduces the app's legitimate behaviour — SSO login,
timetable, attendance report, token refresh, and **beacon-gated check-in** — so
you can check in from a laptop *when you are physically in the room*.

It ships as two binaries that share all the same logic:

* **`griffith-attend-gui`** — a graphical app window (egui/eframe). Start here.
* **`griffith-attend`** — the same features as a terminal menu.

> Unofficial. Use it only with your own account and only where your institution
> permits a desktop/laptop client. It talks to the same API as the official app
> using your own SSO session; it does not bypass any server-side rule.

## The presence safeguard is kept, not removed

Check-in happens **only** when all of these are true:

1. the lesson is in progress (per the server timetable),
2. the lesson has mobile check-in enabled,
3. your laptop's Bluetooth **physically detects** the room's iBeacon whose
   `major` equals the lesson's `bluetooth_id`, and
4. that beacon's signal is at least the proximity threshold (default
   `-80 dBm`, configurable).

There is **no** simulated/mock beacon mode and **no** manual "force check-in"
override. Presence is required and enforced in the scanner
(`src/beacon.rs`) and the check-in gate (`src/checkin.rs`). If you are not in the
room with Bluetooth on, nothing is submitted.

## Build

Requires a recent stable Rust toolchain.

### Linux
```bash
# Debian/Ubuntu build deps: BlueZ (D-Bus) backend + GUI windowing
sudo apt install libdbus-1-dev pkg-config \
     libxkbcommon-dev libgl1-mesa-dev
cargo build --release
```
Bluetooth is accessed through BlueZ over D-Bus; make sure the `bluetooth`
service is running and your user may use the adapter.

### macOS
```bash
cargo build --release
```
Uses Core Bluetooth. On first run macOS will prompt for Bluetooth permission —
allow it (System Settings → Privacy & Security → Bluetooth).

The built binaries are `target/release/griffith-attend-gui` and
`target/release/griffith-attend`.

## Run

Graphical app:
```bash
./target/release/griffith-attend-gui
```
A window with a sidebar: Timetable, Attendance report, Check-in, plus
Start/Stop auto check-in, Refresh token and Log out. The bottom bar shows live
status (fetching, scanning, idle); the top bar shows who you are and how long
the session is valid.

Terminal version (same features, numbered menu):
```bash
./target/release/griffith-attend
```

## macOS: build a .app / .dmg

On a Mac, from the project root:
```bash
./scripts/package-macos.sh
```
This builds a universal (Intel + Apple Silicon) release of the GUI, wraps it in
`dist/Griffith Attendance.app` (with the Bluetooth usage description macOS
requires), and produces `dist/GriffithAttendance.dmg`. It ad-hoc-signs the app
so it runs on your own machine; sharing it with other people additionally needs
an Apple Developer ID certificate and notarization.

> The `.dmg` has to be built on macOS (it uses `hdiutil`), so it is not produced
> in this Linux repo — run the script on your Mac to get it.

### Login

On first run it opens the real SSO URL in your browser. Complete the Microsoft
login + MFA yourself, then copy the auth JSON the page produces (Network tab →
the `logging_in`/`token` response, or the console `message` event) and paste it
once. Your Microsoft credentials are never seen by this program — you
authenticate directly with Microsoft in your own browser.

### Staying logged in

The session is saved to `~/.griffith_attendance_session.json`. On every launch
the client resumes that session instead of making you log in again:

* if the saved access token is still valid, it just continues;
* if the access token has expired but the **refresh token** is still good, it
  refreshes silently in the background (one API call, no browser);
* only when the refresh token itself has expired does it send you back to the
  Microsoft login.

So you re-do the full SSO login only when your refresh token has genuinely
lapsed — not every time you open the app. (This uses the refresh token exactly
as the API intends; it does not weaken or skip MFA, which happens at the real
login.)

## Configuration (environment variables)

| Variable             | Default                     | Meaning                                   |
| -------------------- | --------------------------- | ----------------------------------------- |
| `GRIFFITH_BASE_URL`  | `https://attend.griffith.ie`| API base URL                              |
| `GRIFFITH_MIN_RSSI`  | `-80`                       | Minimum beacon signal (dBm) to check in   |

Raise `GRIFFITH_MIN_RSSI` (e.g. `-70`) to require being closer to the beacon.

## Layout

| File            | Role                                                        |
| --------------- | ----------------------------------------------------------- |
| `config.rs`     | Endpoints, beacon UUID, thresholds, env overrides           |
| `auth.rs`       | SSO session (manual token paste), persistence, refresh      |
| `attendance.rs` | Timetable / attendance / report REST client                 |
| `beacon.rs`     | Cross-platform iBeacon scanner (live detections only)       |
| `checkin.rs`    | Presence-gated check-in orchestration                       |
| `lib.rs`        | Re-exports the modules shared by both binaries              |
| `main.rs`       | Interactive terminal front-end (`griffith-attend`)          |
| `bin/gui.rs`    | Graphical front-end (`griffith-attend-gui`, egui/eframe)    |
| `scripts/package-macos.sh` | Builds the macOS `.app` + `.dmg`                 |

## License

MIT.
