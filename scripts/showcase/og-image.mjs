// Image de partage 1200×630 (public/og.png) : capture du héros sur l'aplat ambre du site, avec l'accroche.
// Rendue par Chrome headless (police Archivo du site, aucune police système). Usage : node og-image.mjs <web/> <00-hero.png>
import { spawn } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { writeFileSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const [webDir, heroPng] = process.argv.slice(2).map((p) => resolve(p));
const font = `${webDir}/node_modules/@fontsource-variable/archivo/files/archivo-latin-wght-normal.woff2`;
const icon = `${webDir}/public/icon-192.png`;
const b64 = (p) => readFileSync(p).toString('base64');
const html = `<!doctype html><meta charset="utf-8"><style>
@font-face { font-family: A; src: url(data:font/woff2;base64,${b64(font)}) format('woff2'); font-weight: 100 900; }
html, body { margin: 0; width: 1200px; height: 630px; overflow: hidden; }
body { background: linear-gradient(160deg, #ffe28a 0%, #ffd24a 45%, #f59e0b 100%); font-family: A, sans-serif; color: #16171b; position: relative; }
.t { position: absolute; left: 64px; top: 64px; display: flex; align-items: center; gap: 18px; }
.t img { width: 76px; height: 76px; }
.t b { font-size: 46px; font-weight: 850; letter-spacing: -0.02em; }
h1 { position: absolute; left: 64px; top: 190px; margin: 0; font-size: 54px; line-height: 1.02; font-weight: 850; letter-spacing: -0.03em; width: 400px; }
p { position: absolute; left: 64px; top: 370px; margin: 0; font-size: 25px; line-height: 1.35; font-weight: 560; width: 400px; hyphens: none; }
.g { position: absolute; left: 64px; top: 516px; padding: 10px 20px; border-radius: 999px; background: #16171b; color: #ffd24a; font-size: 22px; font-weight: 750; }
.w { position: absolute; left: 500px; top: 60px; width: 900px; border-radius: 16px; overflow: hidden;
     box-shadow: 0 40px 80px -20px rgb(80 40 0 / .55), 0 0 0 1px rgb(0 0 0 / .25); }
.w img { display: block; width: 100%; }
</style>
<div class="t"><img src="data:image/png;base64,${b64(icon)}"><b>Escale</b></div>
<h1>Le client SSH natif pour Mac</h1>
<p>Terminal, SFTP, tunnels<br>et multi‑exécution,<br>dans une seule fenêtre.</p>
<div class="g">Gratuit · macOS 15 ou plus</div>
<div class="w"><img src="data:image/png;base64,${b64(heroPng)}"></div>`;

const chrome = spawn(process.env.CHROME, ['--remote-debugging-port=9334', `--user-data-dir=${mkdtempSync(tmpdir() + '/chrome-')}`, '--hide-scrollbars', 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let ws;
for (let i = 0; i < 50 && !ws; i++) {
  try { ws = (await (await fetch('http://127.0.0.1:9334/json')).json()).find((t) => t.type === 'page')?.webSocketDebuggerUrl; } catch { await sleep(200); }
}
const sock = new WebSocket(ws);
await new Promise((r) => sock.addEventListener('open', r));
let id = 0; const pending = new Map();
sock.addEventListener('message', (e) => { const m = JSON.parse(e.data); pending.get(m.id)?.(m); });
const cdp = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); sock.send(JSON.stringify({ id: i, method, params })); });
await cdp('Emulation.setDeviceMetricsOverride', { width: 1200, height: 630, deviceScaleFactor: 1, mobile: false });
const frame = (await cdp('Page.getFrameTree')).result.frameTree.frame.id;
await cdp('Page.setDocumentContent', { frameId: frame, html });
await sleep(1200);
const shot = await cdp('Page.captureScreenshot', { format: 'png', clip: { x: 0, y: 0, width: 1200, height: 630, scale: 1 } });
writeFileSync(`${webDir}/public/og.png`, Buffer.from(shot.result.data, 'base64'));
console.log('og.png écrite');
sock.close(); chrome.kill();
