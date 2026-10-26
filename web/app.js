'use strict';
// RemoteMac phone client. No build step, no dependencies. Protocol: docs/PROTOCOL.md

const $ = (s) => document.querySelector(s);
const $$ = (s) => Array.from(document.querySelectorAll(s));

// ---------- persisted settings ----------
const store = {
  get(k, d) { try { const v = localStorage.getItem('rm.' + k); return v === null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem('rm.' + k, JSON.stringify(v)); } catch {} },
  del(k) { try { localStorage.removeItem('rm.' + k); } catch {} },
};

const settings = {
  mode: store.get('mode', 'trackpad'), // 'trackpad' | 'touch'
  quality: store.get('quality', 'auto'), // 'auto' | 'low' | 'medium' | 'high'
  sound: store.get('sound', true),
  speed: store.get('speed', 1.6),
  display: store.get('display', 0),
  toolbarHidden: store.get('toolbarHidden', false),
};
const saveSetting = (k, v) => { settings[k] = v; store.set(k, v); };

// Token arrives in the QR link as #t=..., then lives in localStorage only.
function readTokenFromHash() {
  const m = location.hash.match(/[#&]t=([A-Za-z0-9_\-]+)/);
  if (!m) return false;
  store.set('token', m[1]);
  history.replaceState(null, '', location.pathname + location.search);
  return true;
}
readTokenFromHash();
window.addEventListener('hashchange', () => { if (readTokenFromHash()) boot(); });

// ---------- state ----------
const state = {
  ws: null,
  connected: false,
  hello: null,
  reconnectDelay: 500,
  reconnectTimer: null,
  started: false,
  autoLevel: 'medium',
  congestion: [],
  lastUpgradeCheck: Date.now(),
  rtt: 0,
  bytes: 0,
  frames: 0,
  cursor: { x: 0.5, y: 0.5 },
  keepAwake: null,
};
// Exposed for tests and debugging.
window.__rm = { state, settings, stats: { decoded: 0, audioPackets: 0, camDecoded: 0, sent: [] } };

// ---------- connection ----------
function wsURL() {
  return (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws';
}

function connect() {
  clearTimeout(state.reconnectTimer);
  if (state.ws) { try { state.ws.onclose = null; state.ws.close(); } catch {} }
  setStatus('Connecting…', 'warn');
  const ws = new WebSocket(wsURL());
  ws.binaryType = 'arraybuffer';
  state.ws = ws;
  ws.onopen = () => send({ t: 'auth', token: store.get('token', '') });
  ws.onmessage = (ev) => {
    if (typeof ev.data === 'string') onJSON(JSON.parse(ev.data));
    else onBinary(ev.data);
  };
  ws.onclose = () => {
    state.connected = false;
    screenVideo.reset();
    camVideo.reset();
    setStatus('Reconnecting…', 'bad');
    state.reconnectTimer = setTimeout(connect, state.reconnectDelay);
    state.reconnectDelay = Math.min(state.reconnectDelay * 2, 5000);
  };
}

function send(msg) {
  const ws = state.ws;
  if (ws && ws.readyState === 1) {
    ws.send(JSON.stringify(msg));
    if (window.__rm.stats.sent.length < 500) window.__rm.stats.sent.push(msg);
  }
}

function onJSON(m) {
  switch (m.t) {
    case 'hello':
      state.connected = true;
      state.reconnectDelay = 500;
      state.hello = m;
      $('#macName').textContent = m.name || 'Mac';
      setStatus(m.name || 'Connected', 'ok');
      fillDisplays(m.displays || []);
      fillCameras(m.cameras || []);
      updateKeepAwake(m.keepAwake);
      showPermissionNotice(m.perms, m.error);
      if (state.started) startScreen();
      if (!$('#camera').hidden) startCamera();
      break;
    case 'denied':
      if (state.ws) state.ws.onclose = null;
      clearTimeout(state.reconnectTimer);
      store.del('token');
      showPair(m.reason);
      break;
    case 'vconfig':
      (m.s === 1 ? camVideo : screenVideo).configure(m);
      break;
    case 'pong':
      state.rtt = Math.round(performance.now() - m.ts);
      break;
    case 'cursor':
      state.cursor = { x: m.x, y: m.y };
      followCursor();
      break;
    case 'state':
      updateKeepAwake(m.keepAwake);
      break;
    case 'clipboard':
      $('#clipText').value = m.text || '';
      toast('Got the Mac clipboard');
      break;
    case 'congested':
      onCongested();
      break;
    case 'error':
      toast(m.msg, 6000);
      break;
  }
}

function onBinary(buf) {
  state.bytes += buf.byteLength;
  const dv = new DataView(buf);
  const type = dv.getUint8(0);
  if (type === 1) {
    const stream = dv.getUint8(1);
    const key = (dv.getUint8(2) & 1) === 1;
    const ts = Number(dv.getBigUint64(3));
    const data = new Uint8Array(buf, 11);
    (stream === 1 ? camVideo : screenVideo).chunk(key, ts, data);
  } else if (type === 2) {
    window.__rm.stats.audioPackets++;
    audio.play(dv.getUint8(1), dv.getUint32(2), new Int16Array(buf.slice(6)));
  }
}

// ---------- video ----------
class VideoStream {
  constructor(canvas, streamId, onFrame) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d', { alpha: false, desynchronized: true });
    this.streamId = streamId;
    this.onFrame = onFrame;
    this.decoder = null;
    this.needKey = true;
  }

  reset() {
    if (this.decoder) { try { this.decoder.close(); } catch {} }
    this.decoder = null;
    this.needKey = true;
  }

  configure(m) {
    if (!('VideoDecoder' in window)) return;
    this.reset();
    const desc = Uint8Array.from(atob(m.desc), (c) => c.charCodeAt(0));
    this.decoder = new VideoDecoder({
      output: (frame) => this.draw(frame),
      error: (e) => {
        console.warn('decoder error', e);
        this.reset();
        send({ t: 'keyframe', s: this.streamId });
      },
    });
    this.decoder.configure({ codec: m.codec, description: desc, optimizeForLatency: true });
    this.width = m.w;
    this.height = m.h;
  }

  chunk(key, ts, data) {
    const d = this.decoder;
    if (!d || d.state !== 'configured') return;
    if (this.needKey && !key) return;
    // Decoder really falling behind: skip ahead to the next keyframe. Safari's decoder keeps a few
    // frames queued even when it's keeping up, so a small threshold here caused a keyframe loop (~4 fps).
    if (!key && d.decodeQueueSize > 30) {
      window.__rm.stats.skips = (window.__rm.stats.skips || 0) + 1;
      this.needKey = true;
      send({ t: 'keyframe', s: this.streamId });
      return;
    }
    this.needKey = false;
    try {
      d.decode(new EncodedVideoChunk({ type: key ? 'key' : 'delta', timestamp: ts, data }));
    } catch (e) {
      console.warn(e);
      this.reset();
    }
  }

  // Paint at most once per display refresh and always the newest frame, so a burst of frames
  // never queues up behind the screen.
  draw(frame) {
    if (this.pending) this.pending.close();
    this.pending = frame;
    if (this.raf) return;
    this.raf = requestAnimationFrame(() => {
      this.raf = 0;
      const f = this.pending;
      this.pending = null;
      if (f) this.paint(f);
    });
  }

  paint(frame) {
    const w = frame.displayWidth, h = frame.displayHeight;
    if (this.canvas.width !== w || this.canvas.height !== h) {
      this.canvas.width = w;
      this.canvas.height = h;
      if (this.onFrame) this.onFrame(true);
    }
    this.ctx.drawImage(frame, 0, 0, w, h);
    frame.close();
    if (this.onFrame) this.onFrame(false);
  }
}

const screenVideo = new VideoStream($('#screen'), 0, (resized) => {
  state.frames++;
  window.__rm.stats.decoded++;
  if (resized) layout();
});
const camVideo = new VideoStream($('#camCanvas'), 1, () => { window.__rm.stats.camDecoded++; });

// ---------- audio ----------
const audio = {
  ctx: null,
  next: 0,
  unlock() {
    if (!this.ctx) {
      const AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return;
      // 'playback' keeps sound on when the iPhone's silent switch is on (iOS 17+).
      try { if (navigator.audioSession) navigator.audioSession.type = 'playback'; } catch {}
      this.ctx = new AC({ latencyHint: 'interactive' });
    }
    if (this.ctx.state === 'suspended') this.ctx.resume();
  },
  play(channels, rate, samples) {
    if (!settings.sound || !this.ctx || this.ctx.state !== 'running') return;
    const frames = samples.length / channels;
    const buf = this.ctx.createBuffer(channels, frames, rate);
    for (let c = 0; c < channels; c++) {
      const out = buf.getChannelData(c);
      for (let i = 0; i < frames; i++) out[i] = samples[i * channels + c] / 32768;
    }
    const now = this.ctx.currentTime;
    // Small jitter buffer; if we drift too far behind real time, jump back to live.
    if (this.next < now + 0.02 || this.next > now + 0.35) this.next = now + 0.08;
    const src = this.ctx.createBufferSource();
    src.buffer = buf;
    src.connect(this.ctx.destination);
    src.start(this.next);
    this.next += buf.duration;
  },
};

// ---------- screen start / quality ----------
const LEVELS = ['low', 'medium', 'high'];
function effectiveQuality() { return settings.quality === 'auto' ? state.autoLevel : settings.quality; }

function startScreen() {
  send({ t: 'screen', on: true, display: settings.display, quality: effectiveQuality(), audio: settings.sound });
}

function onCongested() {
  if (settings.quality !== 'auto') { toast('Connection is slow. Try Data saver in More.'); return; }
  const now = Date.now();
  state.congestion = state.congestion.filter((t) => now - t < 20000);
  state.congestion.push(now);
  const i = LEVELS.indexOf(state.autoLevel);
  if (state.congestion.length >= 2 && i > 0) {
    state.autoLevel = LEVELS[i - 1];
    state.congestion = [];
    state.lastUpgradeCheck = now;
    startScreen();
    toast('Slow connection: lowering picture quality');
  }
}

// Try a better level again after a quiet minute (auto mode only, never above balanced).
setInterval(() => {
  if (settings.quality !== 'auto' || !state.connected) return;
  const now = Date.now();
  if (state.autoLevel === 'low' && now - state.lastUpgradeCheck > 60000 &&
      state.congestion.every((t) => now - t > 60000)) {
    state.autoLevel = 'medium';
    state.lastUpgradeCheck = now;
    startScreen();
  }
}, 10000);

// ---------- stats & ping ----------
setInterval(() => {
  if (state.connected) send({ t: 'ping', ts: performance.now() });
  const kbps = Math.round((state.bytes * 8) / 1000);
  $('#stats').textContent = state.connected ? `${state.frames} fps · ${kbps >= 1000 ? (kbps / 1000).toFixed(1) + ' Mb/s' : kbps + ' kb/s'} · ${state.rtt} ms${window.__rm.stats.skips ? ' · ' + window.__rm.stats.skips + ' skips' : ''}` : '';
  state.bytes = 0;
  state.frames = 0;
}, 1000);

// ---------- layout / zoom ----------
const view = { scale: 1, x: 0, y: 0 }; // zoom transform on top of the fitted size
let fit = { w: 0, h: 0, x: 0, y: 0 };

function layout() {
  const stage = $('#stage').getBoundingClientRect();
  const cw = $('#screen').width || 16, ch = $('#screen').height || 10;
  const s = Math.min(stage.width / cw, stage.height / ch);
  fit = { w: cw * s, h: ch * s, x: (stage.width - cw * s) / 2, y: (stage.height - ch * s) / 2 };
  const v = $('#view');
  v.style.width = fit.w + 'px';
  v.style.height = fit.h + 'px';
  applyView();
}

function clampView() {
  const stage = $('#stage').getBoundingClientRect();
  view.scale = Math.min(Math.max(view.scale, 1), 6);
  const w = fit.w * view.scale, h = fit.h * view.scale;
  // Keep the picture covering the stage when zoomed; centered when it's smaller.
  const minX = Math.min(stage.width - w, fit.x), maxX = Math.max(0, fit.x);
  const minY = Math.min(stage.height - h, fit.y), maxY = Math.max(0, fit.y);
  const baseX = fit.x + view.x, baseY = fit.y + view.y;
  const cx = w <= stage.width ? (stage.width - w) / 2 : Math.min(Math.max(baseX, minX), maxX);
  const cy = h <= stage.height ? (stage.height - h) / 2 : Math.min(Math.max(baseY, minY), maxY);
  view.x = cx - fit.x;
  view.y = cy - fit.y;
}

function applyView() {
  clampView();
  $('#view').style.transform = `translate(${fit.x + view.x}px, ${fit.y + view.y}px) scale(${view.scale})`;
  $('#fitBtn').hidden = view.scale <= 1.01;
  placeCursorDot();
}

function zoomAt(px, py, factor) {
  const old = view.scale;
  const next = Math.min(Math.max(old * factor, 1), 6);
  const ox = fit.x + view.x, oy = fit.y + view.y;
  // Keep the point under the fingers fixed while zooming.
  const nx = px - ((px - ox) * next) / old;
  const ny = py - ((py - oy) * next) / old;
  view.scale = next;
  view.x = nx - fit.x;
  view.y = ny - fit.y;
  applyView();
}

function resetView() { view.scale = 1; view.x = 0; view.y = 0; applyView(); }

function toNorm(clientX, clientY) {
  const r = $('#screen').getBoundingClientRect();
  return { x: (clientX - r.left) / r.width, y: (clientY - r.top) / r.height };
}

function placeCursorDot() {
  const dot = $('#cursorDot');
  if (settings.mode !== 'trackpad' || view.scale <= 1.01) { dot.hidden = true; return; }
  const r = $('#screen').getBoundingClientRect();
  const s = $('#stage').getBoundingClientRect();
  dot.hidden = false;
  dot.style.left = r.left - s.left + state.cursor.x * r.width + 'px';
  dot.style.top = r.top - s.top + state.cursor.y * r.height + 'px';
}

// When zoomed in trackpad mode, pan so the Mac's cursor stays on screen.
function followCursor() {
  if (view.scale > 1.01) {
    const s = $('#stage').getBoundingClientRect();
    const w = fit.w * view.scale, h = fit.h * view.scale;
    const cx = fit.x + view.x + state.cursor.x * w, cy = fit.y + view.y + state.cursor.y * h;
    const m = 60;
    if (cx < m) view.x += m - cx;
    if (cx > s.width - m) view.x -= cx - (s.width - m);
    if (cy < m) view.y += m - cy;
    if (cy > s.height - m) view.y -= cy - (s.height - m);
    applyView();
  } else {
    placeCursorDot();
  }
}

window.addEventListener('resize', layout);
window.addEventListener('orientationchange', () => setTimeout(layout, 300));

// ---------- gestures ----------
// Trackpad: 1 finger moves the pointer, tap = click, two-finger tap = right click,
//           press and hold then drag = drag, two fingers = scroll, pinch = zoom.
// Touch:    tap = click there, drag = drag there, hold = right click, two fingers = scroll, pinch = zoom.
const g = {
  touches: new Map(),
  start: 0,
  moved: false,
  maxTouches: 0,
  mode: null, // 'move' | 'drag' | 'scroll' | 'pinch'
  last: null,
  startDist: 0,
  lastDist: 0,
  holdTimer: null,
  pendingRel: { dx: 0, dy: 0 },
  pendingScroll: { dx: 0, dy: 0 },
  lastMoveT: 0,
  mouseDown: false,
};

function centroid() {
  let x = 0, y = 0;
  for (const t of g.touches.values()) { x += t.x; y += t.y; }
  const n = g.touches.size || 1;
  return { x: x / n, y: y / n };
}
function spread() {
  const p = Array.from(g.touches.values());
  return p.length < 2 ? 0 : Math.hypot(p[0].x - p[1].x, p[0].y - p[1].y);
}

function flushInput() {
  if (g.pendingRel.dx || g.pendingRel.dy) {
    send({ t: 'rel', dx: Math.round(g.pendingRel.dx * 10) / 10, dy: Math.round(g.pendingRel.dy * 10) / 10 });
    g.pendingRel = { dx: 0, dy: 0 };
  }
  if (g.pendingScroll.dx || g.pendingScroll.dy) {
    send({ t: 'scroll', dx: Math.round(g.pendingScroll.dx), dy: Math.round(g.pendingScroll.dy) });
    g.pendingScroll = { dx: 0, dy: 0 };
  }
  g.raf = 0;
}
function queueFlush() { if (!g.raf) g.raf = requestAnimationFrame(flushInput); }

function stageDown(points) {
  const first = g.touches.size === 0;
  for (const p of points) g.touches.set(p.id, { x: p.x, y: p.y, sx: p.x, sy: p.y });
  g.maxTouches = Math.max(g.maxTouches, g.touches.size);
  if (first) {
    g.start = performance.now();
    g.moved = false;
    g.mode = null;
    g.last = centroid();
    g.lastMoveT = g.start;
    clearTimeout(g.holdTimer);
    const p = points[0];
    g.holdTimer = setTimeout(() => onHold(p), 450);
  } else {
    clearTimeout(g.holdTimer);
    if (g.mode === 'drag' && g.mouseDown) { send({ t: 'button', b: 0, down: false }); g.mouseDown = false; }
    g.mode = null;
    g.last = centroid();
    g.startDist = g.lastDist = spread();
  }
}

function onHold(p) {
  if (g.moved || g.touches.size !== 1) return;
  if (navigator.vibrate) navigator.vibrate(10);
  if (settings.mode === 'trackpad') {
    g.mode = 'drag';
    g.mouseDown = true;
    send({ t: 'button', b: 0, down: true });
  } else {
    const n = toNorm(p.x, p.y);
    send({ t: 'move', x: n.x, y: n.y });
    send({ t: 'click', b: 1, n: 1 });
    g.mode = 'held';
  }
}

function stageMove(points) {
  for (const p of points) {
    const t = g.touches.get(p.id);
    if (t) { t.x = p.x; t.y = p.y; }
  }
  const c = centroid();
  const dx = c.x - g.last.x, dy = c.y - g.last.y;
  const now = performance.now();
  const dt = Math.max(1, now - g.lastMoveT);
  g.lastMoveT = now;

  if (!g.moved) {
    let far = false;
    for (const t of g.touches.values()) if (Math.hypot(t.x - t.sx, t.y - t.sy) > 8) far = true;
    if (!far) return;
    g.moved = true;
    clearTimeout(g.holdTimer);
  }

  if (g.touches.size >= 2) {
    const d = spread();
    if (!g.mode || g.mode === 'move' || g.mode === 'drag') {
      g.mode = Math.abs(d / (g.startDist || 1) - 1) > 0.12 ? 'pinch' : (Math.hypot(dx, dy) > 2 ? 'scroll' : null);
    }
    if (g.mode === 'pinch') {
      if (g.lastDist > 0) zoomAt(c.x, c.y, d / g.lastDist);
      view.x += dx; view.y += dy;
      applyView();
    } else if (g.mode === 'scroll') {
      g.pendingScroll.dx += dx * 2;
      g.pendingScroll.dy += dy * 2;
      queueFlush();
    }
    g.lastDist = d;
  } else if (settings.mode === 'trackpad') {
    if (g.mode !== 'drag') g.mode = 'move';
    // Pointer acceleration: slow moves are precise, fast flicks cross the screen.
    const v = Math.hypot(dx, dy) / dt;
    const accel = 1 + Math.min(v, 3) * 1.2;
    const k = settings.speed * accel / Math.max(1, view.scale * 0.6);
    g.pendingRel.dx += dx * k;
    g.pendingRel.dy += dy * k;
    queueFlush();
  } else if (g.mode !== 'held') {
    const n = toNorm(c.x, c.y);
    if (g.mode !== 'drag') {
      const s = toNorm(g.touches.values().next().value.sx, g.touches.values().next().value.sy);
      send({ t: 'move', x: s.x, y: s.y });
      send({ t: 'button', b: 0, down: true });
      g.mouseDown = true;
      g.mode = 'drag';
    }
    send({ t: 'move', x: n.x, y: n.y });
  }
  g.last = c;
}

function stageUp(ids) {
  const before = new Map(g.touches);
  for (const id of ids) g.touches.delete(id);
  if (g.touches.size > 0) { g.last = centroid(); g.startDist = g.lastDist = spread(); return; }
  clearTimeout(g.holdTimer);
  flushInput();
  const dur = performance.now() - g.start;
  if (g.mouseDown) {
    send({ t: 'button', b: 0, down: false });
    g.mouseDown = false;
  } else if (!g.moved && dur < 350 && g.mode !== 'held') {
    if (g.maxTouches >= 2) {
      send({ t: 'click', b: 1, n: 1 });
    } else if (settings.mode === 'trackpad') {
      send({ t: 'click', b: 0, n: 1 });
    } else {
      const p = before.values().next().value;
      const n = toNorm(p.sx, p.sy);
      send({ t: 'move', x: n.x, y: n.y });
      send({ t: 'click', b: 0, n: 1 });
    }
  }
  g.maxTouches = 0;
  g.mode = null;
}

const stage = $('#stage');
const pts = (list) => Array.from(list, (t) => ({ id: t.identifier, x: t.clientX, y: t.clientY }));
stage.addEventListener('touchstart', (e) => { e.preventDefault(); ensureStarted(); stageDown(pts(e.changedTouches)); }, { passive: false });
stage.addEventListener('touchmove', (e) => { e.preventDefault(); stageMove(pts(e.changedTouches)); }, { passive: false });
stage.addEventListener('touchend', (e) => { e.preventDefault(); stageUp(Array.from(e.changedTouches, (t) => t.identifier)); }, { passive: false });
stage.addEventListener('touchcancel', (e) => { stageUp(Array.from(e.changedTouches, (t) => t.identifier)); });

// Desktop browsers (and an iPad with a mouse): direct mouse control.
let mouseHeld = false;
stage.addEventListener('mousedown', (e) => {
  if (e.sourceCapabilities && e.sourceCapabilities.firesTouchEvents) return;
  ensureStarted();
  const n = toNorm(e.clientX, e.clientY);
  send({ t: 'move', x: n.x, y: n.y });
  send({ t: 'button', b: e.button === 2 ? 1 : e.button === 1 ? 2 : 0, down: true });
  mouseHeld = true;
});
window.addEventListener('mousemove', (e) => {
  if (!mouseHeld && e.target !== stage && !stage.contains(e.target)) return;
  if (e.sourceCapabilities && e.sourceCapabilities.firesTouchEvents) return;
  if (!$('#sheet').hidden || !$('#camera').hidden) return;
  const n = toNorm(e.clientX, e.clientY);
  if (n.x >= 0 && n.x <= 1 && n.y >= 0 && n.y <= 1) send({ t: 'move', x: n.x, y: n.y });
});
window.addEventListener('mouseup', (e) => {
  if (!mouseHeld) return;
  mouseHeld = false;
  send({ t: 'button', b: e.button === 2 ? 1 : e.button === 1 ? 2 : 0, down: false });
});
stage.addEventListener('contextmenu', (e) => e.preventDefault());
stage.addEventListener('wheel', (e) => {
  e.preventDefault();
  if (e.ctrlKey) { zoomAt(e.clientX, e.clientY, Math.exp(-e.deltaY / 200)); return; }
  g.pendingScroll.dx -= e.deltaX;
  g.pendingScroll.dy -= e.deltaY;
  queueFlush();
}, { passive: false });

$('#fitBtn').onclick = resetView;

// ---------- keyboard ----------
const kbd = $('#kbd');
const SENTINEL = '​​';
const latched = new Map(); // mod -> 'once' | 'locked'

function resetKbd() { kbd.value = SENTINEL; kbd.setSelectionRange(SENTINEL.length, SENTINEL.length); }

function activeMods() { return Array.from(latched.keys()); }

function releaseOnceMods() {
  for (const [m, how] of latched) {
    if (how === 'once') { latched.delete(m); send({ t: 'mod', k: m, down: false }); }
  }
  renderMods();
}

function pressKey(k, extraMods = []) {
  send({ t: 'key', k, mods: [...new Set([...activeMods(), ...extraMods])] });
  releaseOnceMods();
}

function typeText(s) {
  if (!s) return;
  if (latched.size && s.length === 1) {
    // With ⌘/⌃/⌥ held, a letter is a shortcut, not text.
    pressKey(s.toLowerCase(), latched.has('shift') || s !== s.toLowerCase() ? ['shift'] : []);
    return;
  }
  send({ t: 'text', s });
}

kbd.addEventListener('beforeinput', (e) => {
  e.preventDefault();
  switch (e.inputType) {
    case 'insertText':
    case 'insertReplacementText':
    case 'insertFromPaste':
      typeText(e.data || (e.dataTransfer && e.dataTransfer.getData('text/plain')) || '');
      break;
    case 'insertLineBreak':
    case 'insertParagraph':
      pressKey('enter');
      break;
    case 'deleteContentBackward':
    case 'deleteWordBackward':
      pressKey('backspace', e.inputType === 'deleteWordBackward' ? ['alt'] : []);
      break;
    case 'deleteContentForward':
      pressKey('delete');
      break;
  }
  resetKbd();
});
// Some keyboards bypass beforeinput; catch whatever slips through.
kbd.addEventListener('input', () => {
  const v = kbd.value.replace(/​/g, '');
  if (v) typeText(v);
  resetKbd();
});

const HW_KEYS = {
  ArrowLeft: 'left', ArrowRight: 'right', ArrowUp: 'up', ArrowDown: 'down', Escape: 'esc', Tab: 'tab',
  Home: 'home', End: 'end', PageUp: 'pageup', PageDown: 'pagedown', Delete: 'delete',
  F1: 'f1', F2: 'f2', F3: 'f3', F4: 'f4', F5: 'f5', F6: 'f6', F7: 'f7', F8: 'f8', F9: 'f9', F10: 'f10', F11: 'f11', F12: 'f12',
};
// Hardware keyboards (iPad, desktop browsers): forward shortcuts and special keys directly.
window.addEventListener('keydown', (e) => {
  if (!$('#sheet').hidden || document.activeElement === $('#clipText') || document.activeElement === $('#pairInput')) return;
  const mods = [];
  if (e.metaKey) mods.push('cmd');
  if (e.ctrlKey) mods.push('ctrl');
  if (e.altKey) mods.push('alt');
  if (e.shiftKey) mods.push('shift');
  if (HW_KEYS[e.key]) {
    e.preventDefault();
    pressKey(HW_KEYS[e.key], mods);
  } else if ((e.metaKey || e.ctrlKey) && e.key.length === 1) {
    e.preventDefault();
    pressKey(e.key.toLowerCase(), mods);
  } else if (document.activeElement !== kbd) {
    if (e.key === 'Enter') { e.preventDefault(); pressKey('enter', mods); }
    else if (e.key === 'Backspace') { e.preventDefault(); pressKey('backspace', mods); }
    else if (e.key.length === 1 && !e.altKey) { e.preventDefault(); typeText(e.key); }
  }
});

$('#kbdBtn').onclick = () => {
  ensureStarted();
  if (document.activeElement === kbd) {
    kbd.blur();
  } else {
    resetKbd();
    kbd.focus();
    $('#keyBar').hidden = false;
  }
  renderToolbar();
};
kbd.addEventListener('focus', renderToolbar);
kbd.addEventListener('blur', renderToolbar);

$('#keysBtn').onclick = () => { $('#keyBar').hidden = !$('#keyBar').hidden; renderToolbar(); };

function renderMods() {
  for (const b of $$('#keyBar [data-mod]')) {
    const how = latched.get(b.dataset.mod);
    b.classList.toggle('latched', how === 'once');
    b.classList.toggle('locked', how === 'locked');
  }
}

// Key bar buttons must not steal focus from the hidden textarea, or the iOS keyboard closes.
$('#keyBar').addEventListener('mousedown', (e) => e.preventDefault());
$('#keyBar').addEventListener('touchstart', (e) => {
  const b = e.target.closest('button');
  if (!b) return;
  e.preventDefault();
  b.classList.add('pressed');
  setTimeout(() => b.classList.remove('pressed'), 120);
  keyBarButton(b);
}, { passive: false });
$('#keyBar').addEventListener('click', (e) => {
  const b = e.target.closest('button');
  if (b && !e.sourceCapabilities?.firesTouchEvents) keyBarButton(b);
});

let lastModTap = { mod: null, t: 0 };
function keyBarButton(b) {
  if (b.dataset.mod) {
    const m = b.dataset.mod;
    const now = performance.now();
    const how = latched.get(m);
    if (how) {
      // Tap a held modifier again to release it; double-tap locks it.
      if (how === 'once' && lastModTap.mod === m && now - lastModTap.t < 350) {
        latched.set(m, 'locked');
      } else {
        latched.delete(m);
        send({ t: 'mod', k: m, down: false });
      }
    } else {
      latched.set(m, 'once');
      send({ t: 'mod', k: m, down: true });
    }
    lastModTap = { mod: m, t: now };
    renderMods();
  } else if (b.dataset.key) {
    pressKey(b.dataset.key);
  } else if (b.dataset.combo) {
    const parts = b.dataset.combo.split('+');
    const k = parts.pop();
    pressKey(k, parts);
  } else if (b.dataset.action) {
    send({ t: 'action', name: b.dataset.action });
  }
}

// ---------- toolbar ----------
function renderToolbar() {
  $('#modeBtn .lbl').textContent = settings.mode === 'trackpad' ? 'Trackpad' : 'Touch';
  $('#modeBtn .ico').textContent = settings.mode === 'trackpad' ? '⌖' : '☝︎';
  $('#soundBtn .ico').textContent = settings.sound ? '🔊' : '🔇';
  $('#soundBtn').classList.toggle('on', settings.sound);
  $('#kbdBtn').classList.toggle('on', document.activeElement === kbd);
  $('#keysBtn').classList.toggle('on', !$('#keyBar').hidden);
  $('#main').classList.toggle('toolbar-hidden', settings.toolbarHidden);
  $('#toolbarToggle').textContent = settings.toolbarHidden ? '▴' : '▾';
  placeCursorDot();
}

$('#modeBtn').onclick = () => {
  saveSetting('mode', settings.mode === 'trackpad' ? 'touch' : 'trackpad');
  toast(settings.mode === 'trackpad' ? 'Trackpad: drag to move the pointer, tap to click' : 'Touch: tap exactly where you want to click');
  renderToolbar();
};
$('#soundBtn').onclick = () => {
  ensureStarted();
  saveSetting('sound', !settings.sound);
  send({ t: 'audio', on: settings.sound });
  if (settings.sound) audio.unlock();
  renderToolbar();
};
$('#toolbarToggle').onclick = () => { saveSetting('toolbarHidden', !settings.toolbarHidden); renderToolbar(); };
$('#moreBtn').onclick = () => { openSheet(); };

// ---------- sheet ----------
function openSheet() {
  kbd.blur();
  $('#sheet').hidden = false;
  renderSheet();
}
$('#sheet').addEventListener('click', (e) => {
  if (e.target === $('#sheet') || e.target.dataset.close === 'sheet') $('#sheet').hidden = true;
});

function renderSheet() {
  for (const b of $$('#qualitySeg button')) b.classList.toggle('on', b.dataset.q === settings.quality);
  $('#speed').value = settings.speed;
  const ka = state.keepAwake;
  for (const b of $$('#awakeSeg button')) b.classList.toggle('on', !!ka && !ka.until && ka.mode === b.dataset.mode);
  $('#awakeDisplay').checked = !!(ka && ka.display);
  $('#awakeState').textContent = !ka ? '' :
    ka.until ? `Keeping the Mac awake until ${new Date(ka.until).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}.` :
    ka.active ? 'The Mac is being kept awake right now.' : 'The Mac can sleep normally.';
  $('#connInfo').textContent = `${location.host} · ${state.connected ? 'connected' : 'not connected'} · picture: ${effectiveQuality()}`;
}

$('#qualitySeg').onclick = (e) => {
  const b = e.target.closest('button');
  if (!b) return;
  saveSetting('quality', b.dataset.q);
  if (b.dataset.q === 'auto') state.autoLevel = 'medium';
  startScreen();
  renderSheet();
};
$('#speed').oninput = (e) => saveSetting('speed', parseFloat(e.target.value));
$('#awakeSeg').onclick = (e) => {
  const b = e.target.closest('button');
  if (b) send({ t: 'keepAwake', mode: b.dataset.mode });
};
$('#awakeTimer').onclick = (e) => {
  const b = e.target.closest('button');
  if (b) send({ t: 'keepAwake', mode: 'always', hours: parseFloat(b.dataset.hours) });
};
$('#awakeDisplay').onchange = (e) => send({ t: 'keepAwake', mode: state.keepAwake ? state.keepAwake.mode : 'connected', display: e.target.checked });
$('#sheet .grid').onclick = (e) => {
  const b = e.target.closest('button[data-action]');
  if (b) send({ t: 'action', name: b.dataset.action });
};
$('#clipGet').onclick = () => send({ t: 'clipboard', a: 'get' });
$('#clipSend').onclick = () => {
  const text = $('#clipText').value;
  if (text) { send({ t: 'clipboard', a: 'set', text }); toast('Sent to the Mac clipboard'); }
};
$('#reconnectBtn').onclick = () => { state.reconnectDelay = 500; connect(); $('#sheet').hidden = true; };
$('#forgetBtn').onclick = () => {
  store.del('token');
  if (state.ws) { state.ws.onclose = null; state.ws.close(); }
  showPair();
};
$('#displaySelect').onchange = (e) => {
  saveSetting('display', parseInt(e.target.value, 10));
  resetView();
  startScreen();
};

function updateKeepAwake(ka) {
  state.keepAwake = ka || null;
  if (!$('#sheet').hidden) renderSheet();
}

function fillDisplays(displays) {
  const sel = $('#displaySelect');
  sel.innerHTML = '';
  displays.forEach((d, i) => {
    const o = document.createElement('option');
    o.value = i;
    o.textContent = `${d.name || 'Display ' + (i + 1)} (${d.w}×${d.h})`;
    sel.appendChild(o);
  });
  if (settings.display >= displays.length) saveSetting('display', 0);
  sel.value = settings.display;
  $('#displayField').hidden = displays.length < 2;
}

function showPermissionNotice(perms, error) {
  const missing = [];
  if (perms && !perms.screen) missing.push('Screen Recording');
  if (perms && !perms.accessibility) missing.push('Accessibility (for mouse & keyboard)');
  const n = $('#notice');
  if (missing.length) {
    n.textContent = `On the Mac, allow RemoteMac in System Settings > Privacy & Security > ${missing.join(' and ')}.`;
    n.hidden = false;
  } else if (error) {
    n.textContent = error;
    n.hidden = false;
  } else {
    n.hidden = true;
  }
}

// ---------- camera ----------
function fillCameras(cams) {
  const sel = $('#camSelect');
  sel.innerHTML = '';
  for (const c of cams) {
    const o = document.createElement('option');
    o.value = c.id;
    o.textContent = c.name;
    sel.appendChild(o);
  }
  const saved = store.get('camera', null);
  if (saved && cams.some((c) => c.id === saved)) sel.value = saved;
}
function startCamera() { send({ t: 'camera', on: true, id: $('#camSelect').value || null }); }

$('#camBtn').onclick = () => {
  ensureStarted();
  $('#camera').hidden = false;
  $('#camCanvas').classList.toggle('mirror', store.get('mirror', true));
  startCamera();
};
$('#camClose').onclick = () => {
  $('#camera').hidden = true;
  send({ t: 'camera', on: false });
  camVideo.reset();
};
$('#camSelect').onchange = (e) => { store.set('camera', e.target.value); startCamera(); };
$('#camMirror').onclick = () => {
  const m = !store.get('mirror', true);
  store.set('mirror', m);
  $('#camCanvas').classList.toggle('mirror', m);
};
$('#camSnap').onclick = () => {
  $('#camCanvas').toBlob(async (blob) => {
    if (!blob) return;
    const file = new File([blob], `mac-camera-${Date.now()}.jpg`, { type: 'image/jpeg' });
    if (navigator.canShare && navigator.canShare({ files: [file] })) {
      try { await navigator.share({ files: [file] }); return; } catch {}
    }
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = file.name;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 5000);
  }, 'image/jpeg', 0.92);
};

// ---------- misc UI ----------
function setStatus(text, level) {
  $('#statusText').textContent = text;
  const d = $('#statusDot');
  d.className = 'dot' + (level === 'ok' ? ' ok' : level === 'bad' ? ' bad' : '');
  const bar = $('#statusBar');
  bar.classList.remove('faded');
  clearTimeout(setStatus.t);
  if (level === 'ok') setStatus.t = setTimeout(() => bar.classList.add('faded'), 4000);
}

let toastTimer;
function toast(msg, ms = 2500) {
  const n = $('#notice');
  n.textContent = msg;
  n.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { n.hidden = true; }, ms);
}

let wakeLock = null;
async function keepPhoneAwake() {
  try { if ('wakeLock' in navigator && !wakeLock) { wakeLock = await navigator.wakeLock.request('screen'); wakeLock.onrelease = () => { wakeLock = null; }; } } catch {}
}

// Audio and the stream start on the first tap (iOS only allows sound after a user gesture).
function ensureStarted() {
  audio.unlock();
  keepPhoneAwake();
  if (state.started) return;
  state.started = true;
  $('#tapToStart').hidden = true;
  if (state.connected) startScreen();
}
$('#startBtn').onclick = (e) => { e.stopPropagation(); ensureStarted(); };
$('#tapToStart').addEventListener('touchstart', (e) => { e.preventDefault(); ensureStarted(); }, { passive: false });

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') {
    keepPhoneAwake();
    if (!state.ws || state.ws.readyState > 1) { state.reconnectDelay = 500; connect(); }
    else send({ t: 'keyframe', s: 0 });
  }
});

function showPair(reason) {
  $('#main').hidden = true;
  $('#pair').hidden = false;
  if (reason) {
    const p = $('#pair .card p');
    p.textContent = reason + ' ' + p.textContent;
  }
}
$('#pairForm').onsubmit = (e) => {
  e.preventDefault();
  let v = $('#pairInput').value.trim();
  const m = v.match(/[#&]t=([A-Za-z0-9_\-]+)/);
  if (m) v = m[1];
  if (!v) return;
  store.set('token', v);
  boot();
};

function boot() {
  if (!store.get('token', '')) return showPair();
  $('#pair').hidden = true;
  $('#main').hidden = false;
  if (!('VideoDecoder' in window)) {
    $('#notice').textContent = window.isSecureContext
      ? 'This browser can\'t play the video stream. Update to iOS 16.4 or newer.'
      : 'Open RemoteMac through its https:// address after installing the certificate (see the setup page on port 8080).';
    $('#notice').hidden = false;
  }
  $('#tapToStart').hidden = state.started;
  resetKbd();
  renderToolbar();
  layout();
  connect();
}

boot();
