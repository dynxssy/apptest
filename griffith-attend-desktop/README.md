# Griffith College Attendance — Desktop client (unofficial)

A Rust port of the Griffith College attendance mobile client for **Linux and
macOS laptops**. It reproduces the app's legitimate behaviour — SSO login,
timetable, attendance report, token refresh, and **beacon-gated check-in** — so
you can check in from a laptop *when you are physically in the room*.

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
# Debian/Ubuntu build + runtime deps for the BlueZ (D-Bus) backend
sudo apt install libdbus-1-dev pkg-config
cargo build --release
```
Bluetooth is accessed through BlueZ over D-Bus; make sure the `bluetooth`
service is running and your user may use the adapter.

### macOS
```bash
cargo build --release
```
Uses Core Bluetooth. On first run macOS will prompt for Bluetooth permission —
allow it (Terminal/your app needs Bluetooth access in
System Settings → Privacy & Security → Bluetooth).

The binary is `target/release/griffith-attend`.

## Run

```bash
./target/release/griffith-attend
```

A text menu offers: today's timetable, full timetable, attendance report,
a single live-scan check-in, a continuous auto check-in loop, token refresh,
and logout.

### Login

On first run it opens the real SSO URL in your browser. Complete the Microsoft
login + MFA yourself, then copy the auth JSON the page produces (Network tab →
the `logging_in`/`token` response, or the console `message` event) and paste it
once. The session is saved to `~/.griffith_attendance_session.json` and the JWT
is refreshed automatically. Your Microsoft credentials are never seen by this
program — you authenticate directly with Microsoft in your own browser.

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
| `main.rs`       | Interactive CLI                                             |

## License

MIT.
