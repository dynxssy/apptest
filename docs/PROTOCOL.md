# RemoteMac wire protocol

One WebSocket at `wss://<mac>:8443/ws`. Text messages are JSON objects with a `t` field;
binary messages are media. The phone must send `auth` first (within 10 s) or it's disconnected.
`tools/mock-server.mjs` implements the Mac side of this for testing.

## Phone → Mac

| `t` | fields | effect |
|---|---|---|
| `auth` | `token` | log in; answered by `hello` or `denied` (5 wrong tries locks that IP for 5 min) |
| `ping` | `ts` | answered by `pong` with the same `ts` |
| `screen` | `on`, `display` (index), `quality` (`low`/`medium`/`high`), `audio` (bool) | start/stop the screen stream |
| `audio` | `on` | system sound on/off |
| `camera` | `on`, `id` (optional camera id from `hello`) | start/stop a Mac camera |
| `keyframe` | `s` (stream id) | ask for a fresh keyframe |
| `move` | `x`, `y` (0..1 on the streamed display) | move the pointer there |
| `rel` | `dx`, `dy` (points) | move the pointer by an offset; answered by `cursor` |
| `button` | `b` (0 left, 1 right, 2 middle), `down` | press/release (drags happen between the two) |
| `click` | `b`, `n` (click count) | click |
| `scroll` | `dx`, `dy` (pixels) | scroll |
| `text` | `s` | type Unicode text (newlines press Return) |
| `key` | `k` (`enter`, `left`, `f5`, `c`…), `mods` (`cmd`,`shift`,`alt`,`ctrl`,`fn`) | press a key |
| `mod` | `k`, `down` | hold or release a modifier (for ⌘Tab style combos) |
| `keepAwake` | `mode` (`off`/`connected`/`always`), optional `display` (bool), optional `hours` | keep-awake setting; `hours` keeps the Mac awake for that long then returns to the mode |
| `clipboard` | `a` (`get`/`set`), `text` | read or set the Mac clipboard |
| `action` | `name`: `lock`, `displaySleep`, `volumeUp`, `volumeDown`, `mute`, `missionControl`, `spotlight`, `appSwitcher`, `showDesktop` | quick actions |

## Mac → phone (JSON)

| `t` | fields |
|---|---|
| `hello` | `name`, `displays` [{index,name,w,h}], `cameras` [{id,name}], `perms` {screen,accessibility,camera}, `keepAwake`, `error` |
| `denied` | `reason` |
| `vconfig` | `s` stream, `codec` (e.g. `avc1.640028`), `w`, `h`, `desc` (base64 avcC) — configure a WebCodecs `VideoDecoder` |
| `pong` | `ts` |
| `cursor` | `x`, `y` normalized pointer position |
| `state` | `keepAwake` {mode, display, active, until?} |
| `clipboard` | `text` |
| `congested` | the link can't keep up; video frames are being skipped |
| `error` | `msg` |

## Binary (Mac → phone)

Video: `[0x01][stream u8: 0 screen, 1 camera][flags u8: bit0 keyframe][timestamp u64 BE, µs][H.264 AVCC data]`

Audio: `[0x02][channels u8][sample rate u32 BE][int16 little-endian interleaved PCM]`

The Mac skips video (never audio) while more than ~768 KB is waiting to be sent, then resumes
at the next keyframe, so a slow mobile link drops frames instead of building up delay.
