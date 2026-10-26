// Stand-in for the Mac app, for developing and testing the phone web app on any machine.
// Speaks the same protocol (docs/PROTOCOL.md): serves web/, accepts the WebSocket login,
// streams a real H.264 test pattern (via ffmpeg) plus a test tone, and records input events.
//
//   node tools/mock-server.mjs [--port 8090] [--token testtoken]
//   GET /__events returns the control messages received so far (for tests).
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const args = Object.fromEntries(process.argv.slice(2).join(' ').split('--').filter(Boolean)
  .map((s) => s.trim().split(/\s+/)).map(([k, v]) => [k, v ?? true]));
const PORT = Number(args.port || 8090);
const TOKEN = args.token || 'testtoken';
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'web');
const TYPES = { html: 'text/html; charset=utf-8', js: 'text/javascript', css: 'text/css', png: 'image/png',
  webmanifest: 'application/manifest+json', json: 'application/json', svg: 'image/svg+xml' };

const events = [];

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  if (url.pathname === '/__events') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify(events));
  }
  const rel = url.pathname === '/' ? 'index.html' : decodeURIComponent(url.pathname).replace(/^\/+/, '');
  const file = path.resolve(ROOT, rel);
  if (!file.startsWith(ROOT + path.sep)) { res.writeHead(404); return res.end(); }
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); return res.end('Not found'); }
    res.writeHead(200, { 'Content-Type': TYPES[path.extname(file).slice(1)] || 'application/octet-stream', 'Cache-Control': 'no-cache' });
    res.end(data);
  });
});

// ---------- minimal WebSocket (RFC 6455) ----------
server.on('upgrade', (req, socket) => {
  if (new URL(req.url, 'http://x').pathname !== '/ws') return socket.destroy();
  const accept = crypto.createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  socket.setNoDelay(true);
  new Client(socket);
});

function frame(opcode, payload) {
  const n = payload.length;
  let head;
  if (n < 126) head = Buffer.from([0x80 | opcode, n]);
  else if (n < 65536) { head = Buffer.alloc(4); head[0] = 0x80 | opcode; head[1] = 126; head.writeUInt16BE(n, 2); }
  else { head = Buffer.alloc(10); head[0] = 0x80 | opcode; head[1] = 127; head.writeBigUInt64BE(BigInt(n), 2); }
  return Buffer.concat([head, payload]);
}

const clients = new Set();

class Client {
  constructor(socket) {
    this.socket = socket;
    this.buf = Buffer.alloc(0);
    this.authed = false;
    this.watching = new Set();
    this.audio = false;
    this.waitKey = { 0: true, 1: true };
    socket.on('data', (d) => this.onData(d));
    socket.on('close', () => { clients.delete(this); updateSources(); });
    socket.on('error', () => {});
  }

  onData(d) {
    this.buf = Buffer.concat([this.buf, d]);
    while (this.buf.length >= 2) {
      const op = this.buf[0] & 0x0f;
      let len = this.buf[1] & 0x7f, off = 2;
      if (len === 126) { if (this.buf.length < 4) return; len = this.buf.readUInt16BE(2); off = 4; }
      else if (len === 127) { if (this.buf.length < 10) return; len = Number(this.buf.readBigUInt64BE(2)); off = 10; }
      if (this.buf.length < off + 4 + len) return;
      const mask = this.buf.subarray(off, off + 4);
      const p = Buffer.from(this.buf.subarray(off + 4, off + 4 + len));
      for (let i = 0; i < p.length; i++) p[i] ^= mask[i & 3];
      this.buf = this.buf.subarray(off + 4 + len);
      if (op === 8) return this.socket.end();
      if (op === 9) this.socket.write(frame(10, p));
      if (op === 1) this.onText(p.toString('utf8'));
    }
  }

  sendJSON(o) { this.socket.write(frame(1, Buffer.from(JSON.stringify(o)))); }
  sendBin(b) { this.socket.write(frame(2, b)); }

  onText(text) {
    const m = JSON.parse(text);
    if (!this.authed) {
      if (m.t !== 'auth' || m.token !== TOKEN) {
        this.sendJSON({ t: 'denied', reason: 'Wrong pairing code.' });
        return this.socket.end();
      }
      this.authed = true;
      clients.add(this);
      return this.sendJSON({
        t: 'hello', name: 'Mock Mac',
        displays: [{ index: 0, name: 'Built-in Display', w: 1512, h: 982 }, { index: 1, name: 'Studio Display', w: 2560, h: 1440 }],
        cameras: [{ id: 'cam-1', name: 'FaceTime HD Camera' }],
        perms: { screen: true, accessibility: true, camera: true },
        keepAwake: keepAwake, error: '',
      });
    }
    if (m.t !== 'ping') events.push(m);
    switch (m.t) {
      case 'ping': return this.sendJSON({ t: 'pong', ts: m.ts });
      case 'screen':
        if (m.on) { this.watching.add(0); this.audio = !!m.audio; this.waitKey[0] = true; } else this.watching.delete(0);
        updateSources();
        if (sources[0]?.config) this.sendJSON(sources[0].config);
        return;
      case 'audio': this.audio = !!m.on; return;
      case 'camera':
        if (m.on) { this.watching.add(1); this.waitKey[1] = true; } else this.watching.delete(1);
        updateSources();
        if (sources[1]?.config) this.sendJSON(sources[1].config);
        return;
      case 'rel':
        cursor.x = Math.min(1, Math.max(0, cursor.x + m.dx / 1512));
        cursor.y = Math.min(1, Math.max(0, cursor.y + m.dy / 982));
        return this.sendJSON({ t: 'cursor', x: cursor.x, y: cursor.y });
      case 'move': cursor.x = m.x; cursor.y = m.y; return;
      case 'keepAwake':
        if (m.hours) keepAwake = { ...keepAwake, until: Date.now() + m.hours * 3600e3, active: true };
        else keepAwake = { mode: m.mode, display: m.display ?? keepAwake.display, active: m.mode !== 'off' };
        for (const c of clients) c.sendJSON({ t: 'state', keepAwake });
        return;
      case 'clipboard':
        if (m.a === 'set') clipboard = m.text; else this.sendJSON({ t: 'clipboard', text: clipboard });
        return;
    }
  }
}

let keepAwake = { mode: 'connected', display: false, active: true };
let clipboard = 'hello from the mock Mac';
const cursor = { x: 0.5, y: 0.5 };

// ---------- media ----------
// One ffmpeg per stream id, started while someone watches. Output is Annex B H.264 which we
// convert to what the Mac app sends: an avcC config message + AVCC (length-prefixed) frames.
const sources = {};

function updateSources() {
  for (const id of [0, 1]) {
    const want = [...clients].some((c) => c.watching.has(id));
    if (want && !sources[id]) sources[id] = startSource(id);
    if (!want && sources[id]) { sources[id].proc.kill('SIGKILL'); delete sources[id]; }
  }
}

function startSource(id) {
  const [w, h, pattern] = id === 0 ? [1280, 832, 'testsrc2'] : [640, 480, 'smptebars'];
  const proc = spawn('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-re', '-f', 'lavfi', '-i', `${pattern}=size=${w}x${h}:rate=30`,
    '-c:v', 'libx264', '-profile:v', 'high', '-preset', 'ultrafast', '-tune', 'zerolatency', '-bf', '0', '-g', '30',
    '-x264-params', 'aud=1:repeat-headers=1', '-pix_fmt', 'yuv420p', '-f', 'h264', '-']);
  const src = { proc, config: null, pending: Buffer.alloc(0), nals: [], t0: Date.now() };
  proc.stdout.on('data', (d) => {
    src.pending = Buffer.concat([src.pending, d]);
    let start = findStart(src.pending, 0);
    while (start >= 0) {
      const next = findStart(src.pending, start + 3);
      if (next < 0) break;
      onNal(id, src, stripStart(src.pending.subarray(start, next)));
      start = next;
    }
    if (start > 0) src.pending = src.pending.subarray(start);
  });
  return src;
}

function findStart(b, from) {
  for (let i = from; i + 3 <= b.length; i++) if (b[i] === 0 && b[i + 1] === 0 && b[i + 2] === 1) return i > 0 && b[i - 1] === 0 ? i - 1 : i;
  return -1;
}
function stripStart(n) { return n[2] === 1 ? n.subarray(3) : n.subarray(4); }

function onNal(id, src, nal) {
  const type = nal[0] & 0x1f;
  if (type === 9) { flushAU(id, src); return; } // access unit delimiter
  if (type === 7) src.sps = Buffer.from(nal);
  if (type === 8) src.pps = Buffer.from(nal);
  src.nals.push(Buffer.from(nal));
}

function flushAU(id, src) {
  const nals = src.nals;
  src.nals = [];
  const vcl = nals.filter((n) => [1, 5].includes(n[0] & 0x1f));
  if (!vcl.length) return;
  const key = nals.some((n) => (n[0] & 0x1f) === 5);
  if (key && src.sps && src.pps && !src.config) {
    const { sps, pps } = src;
    const avcC = Buffer.concat([Buffer.from([1, sps[1], sps[2], sps[3], 0xff, 0xe1]), u16(sps.length), sps, Buffer.from([1]), u16(pps.length), pps]);
    const codec = 'avc1.' + [sps[1], sps[2], sps[3]].map((x) => x.toString(16).padStart(2, '0')).join('').toUpperCase();
    src.config = { t: 'vconfig', s: id, codec, w: id === 0 ? 1280 : 640, h: id === 0 ? 832 : 480, desc: avcC.toString('base64') };
    for (const c of clients) if (c.watching.has(id)) c.sendJSON(src.config);
  }
  if (!src.config) return;
  const body = Buffer.concat(vcl.flatMap((n) => [u32(n.length), n]));
  const head = Buffer.alloc(11);
  head[0] = 1; head[1] = id; head[2] = key ? 1 : 0;
  head.writeBigUInt64BE(BigInt((Date.now() - src.t0) * 1000), 3);
  const msg = Buffer.concat([head, body]);
  for (const c of clients) {
    if (!c.watching.has(id)) continue;
    if (c.waitKey[id] && !key) continue;
    c.waitKey[id] = false;
    c.sendBin(msg);
  }
}

const u16 = (n) => { const b = Buffer.alloc(2); b.writeUInt16BE(n); return b; };
const u32 = (n) => { const b = Buffer.alloc(4); b.writeUInt32BE(n); return b; };

// 440 Hz test tone in 20 ms packets, 48 kHz stereo, same layout as the Mac's system audio.
let phase = 0;
setInterval(() => {
  const listeners = [...clients].filter((c) => c.watching.has(0) && c.audio);
  if (!listeners.length) return;
  const frames = 960, buf = Buffer.alloc(6 + frames * 4);
  buf[0] = 2; buf[1] = 2; buf.writeUInt32BE(48000, 2);
  for (let i = 0; i < frames; i++) {
    const v = Math.round(Math.sin(phase) * 6000);
    phase += (2 * Math.PI * 440) / 48000;
    buf.writeInt16LE(v, 6 + i * 4);
    buf.writeInt16LE(v, 8 + i * 4);
  }
  for (const c of listeners) c.sendBin(buf);
}, 20);

server.listen(PORT, () => console.log(`mock RemoteMac on http://localhost:${PORT}/#t=${TOKEN}`));
