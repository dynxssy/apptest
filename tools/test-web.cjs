// End-to-end test of the phone web app against tools/mock-server.mjs, in an emulated iPhone.
//   node tools/test-web.cjs            (needs ffmpeg and Playwright's Chromium)
// Screenshots go to tools/screenshots/.
const { chromium, devices } = require('playwright');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const PORT = 8097;
const BASE = `http://localhost:${PORT}`;
const shots = path.join(__dirname, 'screenshots');
fs.mkdirSync(shots, { recursive: true });

let failures = 0;
function check(name, ok, detail = '') {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  (' + detail + ')' : ''}`);
  if (!ok) failures++;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const events = async () => (await fetch(BASE + '/__events')).json();

(async () => {
  const server = spawn('node', [path.join(__dirname, 'mock-server.mjs'), '--port', String(PORT)], { stdio: 'inherit' });
  await sleep(800);
  const browser = await chromium.launch({ args: ['--autoplay-policy=no-user-gesture-required'] });
  try {
    const ctx = await browser.newContext({ ...devices['iPhone 13'], hasTouch: true });
    const page = await ctx.newPage();
    page.on('pageerror', (e) => check('no page errors', false, e.message));
    page.on('console', (m) => { if (m.type() === 'error') console.log('console error:', m.text()); });

    // 1. Unpaired phone sees the pairing screen.
    await page.goto(BASE + '/');
    check('pairing screen without token', await page.isVisible('#pair'));

    // 2. Wrong token is rejected and pairing screen comes back.
    await page.goto(BASE + '/#t=wrongtoken');
    await sleep(800);
    check('wrong token rejected', await page.isVisible('#pair'));

    // 3. QR link logs in, token is stored and removed from the URL.
    await page.goto(BASE + '/#t=testtoken');
    await page.waitForFunction(() => window.__rm.state.connected, null, { timeout: 5000 });
    check('connects with token', true);
    check('token removed from URL', !(await page.evaluate(() => location.hash)).includes('testtoken'));
    check('tap-to-start shown', await page.isVisible('#tapToStart'));
    await page.screenshot({ path: path.join(shots, '1-tap-to-start.png') });

    // 4. Tap starts the stream: video frames decode and audio packets arrive.
    await page.touchscreen.tap(195, 400);
    await page.waitForFunction(() => window.__rm.stats.decoded > 20, null, { timeout: 8000 });
    const st = await page.evaluate(() => window.__rm.stats);
    check('screen video decodes', st.decoded > 20, `${st.decoded} frames`);
    check('audio packets received', st.audioPackets > 10, `${st.audioPackets} packets`);
    const canvas = await page.evaluate(() => [document.querySelector('#screen').width, document.querySelector('#screen').height]);
    check('canvas sized to stream', canvas[0] === 1280 && canvas[1] === 832, canvas.join('x'));
    const ev0 = await events();
    const start = ev0.find((e) => e.t === 'screen');
    check('screen start requested', start && start.on && start.quality === 'medium' && start.audio === true, JSON.stringify(start));
    await page.screenshot({ path: path.join(shots, '2-streaming.png') });

    // 5. Trackpad mode: drag moves the pointer, tap clicks.
    const cdp = await ctx.newCDPSession(page);
    const touch = (type, points) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: points.map(([x, y], i) => ({ x, y, id: i })) });
    await touch('touchStart', [[150, 300]]);
    for (let i = 1; i <= 10; i++) { await touch('touchMove', [[150 + i * 6, 300 + i * 3]]); await sleep(16); }
    await touch('touchEnd', []);
    await sleep(200);
    await page.touchscreen.tap(200, 300);
    await sleep(300);
    let ev = await events();
    const rel = ev.filter((e) => e.t === 'rel');
    check('trackpad drag sends relative moves', rel.length > 0 && rel.reduce((a, e) => a + e.dx, 0) > 0, `${rel.length} moves`);
    check('trackpad tap sends left click', ev.some((e) => e.t === 'click' && e.b === 0));
    check('server cursor echo received', await page.evaluate(() => window.__rm.state.cursor.x !== 0.5));

    // 6. Two-finger tap = right click; two-finger drag = scroll.
    await touch('touchStart', [[150, 300], [220, 300]]);
    await sleep(50);
    await touch('touchEnd', []);
    await sleep(100);
    await touch('touchStart', [[150, 300], [220, 300]]);
    for (let i = 1; i <= 8; i++) { await touch('touchMove', [[150, 300 - i * 10], [220, 300 - i * 10]]); await sleep(16); }
    await touch('touchEnd', []);
    await sleep(200);
    ev = await events();
    check('two-finger tap right-clicks', ev.some((e) => e.t === 'click' && e.b === 1));
    check('two-finger drag scrolls', ev.some((e) => e.t === 'scroll' && e.dy < 0));

    // 7. Pinch zooms the view locally (nothing sent to the Mac).
    const before = (await events()).length;
    await touch('touchStart', [[170, 400], [220, 400]]);
    for (let i = 1; i <= 10; i++) { await touch('touchMove', [[170 - i * 8, 400], [220 + i * 8, 400]]); await sleep(16); }
    await touch('touchEnd', []);
    await sleep(200);
    const zoom = await page.evaluate(() => document.querySelector('#view').style.transform);
    check('pinch zooms in', /scale\((?!1\))/.test(zoom), zoom);
    check('fit button appears when zoomed', await page.isVisible('#fitBtn'));
    check('pinch sends no scroll', (await events()).slice(before).every((e) => e.t !== 'scroll'));
    await page.screenshot({ path: path.join(shots, '3-zoomed.png') });
    await page.click('#fitBtn');

    // 8. Touch mode: tap clicks at the tapped spot.
    await page.click('#modeBtn');
    const box = await page.evaluate(() => { const r = document.querySelector('#screen').getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; });
    await page.touchscreen.tap(box[0] + box[2] * 0.25, box[1] + box[3] * 0.75);
    await sleep(300);
    ev = await events();
    const mv = [...ev].reverse().find((e) => e.t === 'move');
    check('touch mode tap moves to the spot', mv && Math.abs(mv.x - 0.25) < 0.02 && Math.abs(mv.y - 0.75) < 0.02, mv && `${mv.x.toFixed(3)},${mv.y.toFixed(3)}`);
    check('touch mode tap clicks', ev[ev.length - 1].t === 'click');
    await page.click('#modeBtn');

    // 9. Keyboard: typed text, backspace, enter, and a ⌘ shortcut from the key bar.
    await page.click('#kbdBtn');
    await page.keyboard.type('hi Mac');
    await page.keyboard.press('Backspace');
    await page.keyboard.press('Enter');
    await page.tap('#keyBar [data-mod="cmd"]');
    await page.keyboard.type('c');
    await sleep(300);
    ev = await events();
    const typed = ev.filter((e) => e.t === 'text').map((e) => e.s).join('');
    check('typing sends text', typed === 'hi Mac', JSON.stringify(typed));
    check('backspace sent', ev.some((e) => e.t === 'key' && e.k === 'backspace'));
    check('enter sent', ev.some((e) => e.t === 'key' && e.k === 'enter'));
    check('⌘ latch + c sends shortcut', ev.some((e) => e.t === 'key' && e.k === 'c' && e.mods.includes('cmd')), JSON.stringify(ev.filter((e) => e.t === 'key').slice(-1)));
    check('⌘ released after shortcut', ev.some((e) => e.t === 'mod' && e.k === 'cmd' && e.down === false));
    await page.tap('#keyBar [data-combo="cmd+tab"]');
    await sleep(100);
    check('combo chip sends cmd+tab', (await events()).some((e) => e.t === 'key' && e.k === 'tab' && e.mods.includes('cmd')));
    await page.screenshot({ path: path.join(shots, '4-keyboard.png') });
    await page.evaluate(() => document.querySelector('#kbd').blur());
    await page.tap('#keysBtn');

    // 10. Settings sheet: keep awake, quality, clipboard.
    await page.tap('#moreBtn');
    check('settings sheet opens', await page.isVisible('#sheet'));
    await page.tap('#awakeSeg [data-mode="always"]');
    await sleep(200);
    check('keep awake: always sent and reflected', await page.evaluate(() => document.querySelector('#awakeSeg [data-mode="always"]').classList.contains('on')));
    await page.tap('#awakeTimer [data-hours="4"]');
    await sleep(200);
    check('keep awake timer shows until', (await page.textContent('#awakeState')).includes('until'));
    await page.tap('#qualitySeg [data-q="low"]');
    await sleep(200);
    ev = await events();
    check('quality change restarts stream at low', [...ev].reverse().find((e) => e.t === 'screen').quality === 'low');
    await page.tap('#clipGet');
    await sleep(200);
    check('clipboard get', (await page.inputValue('#clipText')) === 'hello from the mock Mac');
    await page.screenshot({ path: path.join(shots, '5-settings.png'), fullPage: true });
    await page.tap('#sheet [data-close="sheet"]');

    // 11. Camera view.
    await page.tap('#camBtn');
    await page.waitForFunction(() => window.__rm.stats.camDecoded > 10, null, { timeout: 8000 });
    check('camera video decodes', true);
    await page.screenshot({ path: path.join(shots, '6-camera.png') });
    await page.tap('#camClose');
    await sleep(200);
    check('camera stop sent', (await events()).some((e) => e.t === 'camera' && e.on === false));

    // 12. Reconnects after the connection drops.
    await page.evaluate(() => window.__rm.state.ws.close());
    await page.waitForFunction(() => window.__rm.state.connected, null, { timeout: 5000 });
    check('reconnects automatically', true);
    const d0 = await page.evaluate(() => window.__rm.stats.decoded);
    await sleep(1500);
    check('video resumes after reconnect', (await page.evaluate(() => window.__rm.stats.decoded)) > d0 + 10);

    // 13. Landscape layout.
    await page.setViewportSize({ width: 844, height: 390 });
    await sleep(400);
    await page.screenshot({ path: path.join(shots, '7-landscape.png') });
    const lb = await page.evaluate(() => { const r = document.querySelector('#screen').getBoundingClientRect(); return r.height; });
    check('landscape fits the height', Math.abs(lb - 390) < 2, String(lb));
  } catch (e) {
    check('test run', false, e.stack);
  } finally {
    await browser.close();
    server.kill();
  }
  console.log(failures ? `\n${failures} failed` : '\nall passed');
  process.exit(failures ? 1 : 0);
})();
