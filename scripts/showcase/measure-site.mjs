// Mesure la page construite (astro preview) : échelle d'affichage de chaque capture (≥ 50 % exigé), captures pleine page.
// Usage : node measure-site.mjs <url> <dossier sortie>   (CHROME = chemin de chrome-headless-shell)
import { spawn } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { writeFileSync, mkdirSync } from 'node:fs';

const [url, out] = process.argv.slice(2);
mkdirSync(out, { recursive: true });
const chrome = spawn(process.env.CHROME, ['--remote-debugging-port=9333', `--user-data-dir=${mkdtempSync(tmpdir() + '/chrome-')}`, '--hide-scrollbars', '--force-device-scale-factor=1', 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let ws;
for (let i = 0; i < 50 && !ws; i++) {
  try {
    const tabs = await (await fetch('http://127.0.0.1:9333/json')).json();
    ws = tabs.find((t) => t.type === 'page')?.webSocketDebuggerUrl;
  } catch { await sleep(200); }
}
const sock = new WebSocket(ws);
await new Promise((r) => sock.addEventListener('open', r));
let id = 0;
const pending = new Map();
sock.addEventListener('message', (e) => { const m = JSON.parse(e.data); pending.get(m.id)?.(m); });
const cdp = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); sock.send(JSON.stringify({ id: i, method, params })); });
const evalJS = async (expr) => (await cdp('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })).result?.result?.value;

await cdp('Network.enable');
await cdp('Network.setCacheDisabled', { cacheDisabled: true });
const report = {};
for (const [w, h, dpr] of [[1440, 900, 1], [390, 844, 3]]) {
  await cdp('Emulation.setDeviceMetricsOverride', { width: w, height: h, deviceScaleFactor: 1, mobile: w < 600 });
  await cdp('Page.navigate', { url });
  await sleep(2500);
  // Défilement complet : déclenche les apparitions au défilement et le chargement différé.
  const total = await evalJS('document.documentElement.scrollHeight');
  for (let y = 0; y < total; y += h / 2) { await evalJS(`window.scrollTo(0, ${y})`); await sleep(120); }
  await evalJS('window.scrollTo(0, 0)'); await sleep(1500);
  report[w] = await evalJS(`(async () => {
    const imgs = [...document.querySelectorAll('main img, header img, section img')].filter(i => i.naturalWidth > 200);
    // Images différées : chargement forcé, sinon currentSrc reste vide et la variante servie est inconnue.
    imgs.forEach(i => { i.loading = 'eager'; });
    await Promise.all(imgs.map(i => i.decode().catch(() => {})));
    await new Promise(r => setTimeout(r, 500));
    const dpr = ${dpr};
    return {
      heroTop: Math.round(document.querySelector('img')?.getBoundingClientRect().top + scrollY),
      images: imgs.map(i => {
        const r = i.getBoundingClientRect();
        const src = (i.currentSrc || i.src).split('/').pop().split('?')[0];
        // Taille native de la capture : attribut data-native-width si présent, sinon naturalWidth de la plus grande variante.
        const native = +i.dataset.nativeWidth || +i.getAttribute('data-w') || 0;
        return { alt: i.alt.slice(0, 40), src, top: Math.round(r.top + scrollY), shown: Math.round(r.width), natural: i.naturalWidth, native, visible: r.width > 0 };
      }),
    };
  })()`);
  writeFileSync(`${out}/measure.json`, JSON.stringify(report, null, 2));
  // Capture par tranches de 3000 px : au-delà, Chrome headless renvoie parfois « Unable to encode screenshot ».
  const full = await evalJS('document.documentElement.scrollHeight');
  for (let y = 0, k = 0; y < full; y += 3000, k++) {
    const shot = await cdp('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true, clip: { x: 0, y, width: w, height: Math.min(3000, full - y), scale: 1 } });
    if (!shot.result) { console.error('capture', w, y, JSON.stringify(shot.error)); continue; }
    writeFileSync(`${out}/page-${w}-${k}.png`, Buffer.from(shot.result.data, 'base64'));
  }
}
writeFileSync(`${out}/measure.json`, JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 1));
sock.close(); chrome.kill();
