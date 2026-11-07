// Release-build benchmark. This measures main-thread frame callbacks, not GPU FPS.
import { chromium } from '@playwright/test';
import http from 'node:http';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { resolve, join, extname } from 'node:path';
import { gzipSync } from 'node:zlib';

const args = Object.fromEntries(process.argv.slice(2).map(value => {
  const [key, ...rest] = value.replace(/^--/, '').split('=');
  return [key, rest.length ? rest.join('=') : true];
}));
if (!args.build || !args.fixtures || !args.output) {
  throw new Error('Usage: node performance.mjs --build=DIR --fixtures=DIR --output=FILE [--runs=3] [--delivery=optimized] [--software] [--ios] [--cpu=4] [--channel=chrome]');
}
const root = resolve(args.build), fixtures = resolve(args.fixtures);
const optimized = args.delivery === 'optimized';
const files = new Map();
for (const variant of ['original', 'thumbnail', 'medium', 'preview']) {
  files.set(variant, await readFile(join(fixtures, `${variant}.jpg`)));
}
const photo = i => ({ id: `photo-${i}`, url: `/media/assets/photo-${i}/original` });
const entries = Array.from({ length: 300 }, (_, i) => ({
  id: `entry-${i}`, title: `日记${i}`, cooked_on: '2026-11-07',
  notes: '今天的家常菜，记录下厨的日常。', media: [photo(i)],
}));
const recipes = Array.from({ length: 300 }, (_, i) => ({
  id: `recipe-${i}`, title: `菜品${i}`, category: '家常菜', description: '记录下厨的日常', image: '',
  ingredients: ['番茄', '鸡蛋'], steps: ['翻炒后装盘'], favorite: false,
  custom: true, photos: [photo(i)], cover_media_id: `photo-${i}`,
}));
let requests = [];
const types = { '.html': 'text/html', '.js': 'application/javascript', '.mjs': 'application/javascript',
  '.wasm': 'application/wasm', '.json': 'application/json', '.png': 'image/png',
  '.webp': 'image/webp', '.ttf': 'font/ttf', '.woff2': 'font/woff2', '.otf': 'font/otf' };
const server = http.createServer(async (req, res) => {
  try {
    const path = new URL(req.url, 'http://localhost').pathname;
    requests.push({ path, time: Date.now() });
    if (optimized) {
      res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
      res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
    }
    let body, type, encoded = false;
    if (path.startsWith('/api/')) {
      const data = path.endsWith('/auth/status') ? { authenticated: true, auth_required: true }
        : path.endsWith('/entries') ? { items: entries }
        : path.endsWith('/recipes') ? recipes : { name: '性能测试', bio: '' };
      body = Buffer.from(JSON.stringify({ data })); type = 'application/json';
    } else if (path.startsWith('/media/')) {
      body = files.get(path.split('/').at(-1)); type = 'image/jpeg';
      res.setHeader('Cache-Control', 'private,max-age=86400');
    } else {
      const name = path === '/' ? 'index.html' : decodeURIComponent(path);
      const file = resolve(root, `.${name.startsWith('/') ? name : `/${name}`}`);
      if (!file.startsWith(`${root}/`)) throw new Error('invalid path');
      body = await readFile(file); type = types[extname(file)] || 'application/octet-stream';
      if (optimized) {
        for (const [coding, suffix] of [['br', '.br'], ['gzip', '.gz']]) {
          if (!req.headers['accept-encoding']?.includes(coding)) continue;
          const compressed = await readFile(file + suffix).catch(() => null);
          if (compressed) { body = compressed; encoded = true; res.setHeader('Content-Encoding', coding); break; }
        }
      }
    }
    if (!body) throw new Error('missing fixture');
    res.setHeader('Content-Type', type);
    if (optimized && !encoded && /(?:javascript|json|wasm|text\/)/.test(type) && req.headers['accept-encoding']?.includes('gzip')) {
      body = gzipSync(body); res.setHeader('Content-Encoding', 'gzip');
      res.setHeader('Vary', 'Accept-Encoding');
    }
    res.end(body);
  } catch { res.statusCode = 404; res.end('missing'); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const base = `http://127.0.0.1:${server.address().port}`;
let browser;
const samples = [];
function summary(frames, tasks) {
  const values = frames.toSorted((a, b) => a - b);
  return { callbackCount: values.length, p50Ms: values[Math.floor(values.length * .5)] ?? 0,
    p95Ms: values[Math.floor(values.length * .95)] ?? 0, maxMs: Math.max(0, ...values),
    gapsOver33ms: values.filter(x => x > 33.4).length,
    longTaskCount: tasks.length, longTaskTotalMs: tasks.reduce((n, x) => n + x, 0) };
}
try {
  browser = await chromium.launch({ headless: true, ...(args.channel ? { channel: args.channel } : {}),
    args: args.software ? ['--disable-webgl'] : ['--enable-webgl', '--ignore-gpu-blocklist'] });
  for (let run = 0; run < Number(args.runs || 3); run++) {
    requests = [];
    const context = await browser.newContext({ viewport: { width: 390, height: 844 },
      deviceScaleFactor: 3, isMobile: true, hasTouch: true, serviceWorkers: 'block',
      ...(args.ios ? { userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1' } : {}) });
    if (args.ios) await context.addInitScript(() => {
      Object.defineProperty(navigator, 'vendor', { get: () => 'Apple Computer, Inc.' });
    });
    const page = await context.newPage(); page.setDefaultTimeout(30000);
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    page.on('response', response => { if (response.status() >= 400) errors.push(`HTTP ${response.status()}: ${response.url()}`); });
    page.on('console', message => { if (/Failed to (?:parse|load) font/.test(message.text())) errors.push(message.text()); });
    const cdp = await context.newCDPSession(page);
    if (args.cpu) await cdp.send('Emulation.setCPUThrottlingRate', { rate: Number(args.cpu) });
    await page.addInitScript(() => {
      window.benchmark = { frames: [], tasks: [], active: false, last: null };
      function frame(t) { const b = window.benchmark;
        if (b.active && b.last !== null) b.frames.push(t - b.last);
        b.last = t; requestAnimationFrame(frame);
      }
      requestAnimationFrame(frame);
      new PerformanceObserver(list => { if (window.benchmark.active)
        window.benchmark.tasks.push(...list.getEntries().map(e => e.duration));
      }).observe({ entryTypes: ['longtask'] });
    });
    const home = page.locator('[flt-semantics-identifier="home-record-action"]');
    await page.goto(base, { waitUntil: 'domcontentloaded' });
    await page.waitForFunction(() => !document.querySelector('#loading'), null, { polling: 'raf', timeout: 60000 });
    await page.locator('flt-semantics-placeholder').evaluate(e => e.click());
    await page.waitForFunction(() => {
      const element = document.querySelector('[flt-semantics-identifier="home-record-action"]');
      if (element?.getBoundingClientRect().width > 0) { window.firstReadyMs = performance.now(); return true; }
      return false;
    }, null, { polling: 'raf', timeout: 30000 }).catch(async error => {
      console.error(JSON.stringify({ errors, requests: requests.map(r => r.path), semantics: await page.locator('body').ariaSnapshot() }));
      throw error;
    });
    if (args.screenshots && run === 0) {
      await mkdir(args.screenshots, { recursive: true });
      await page.screenshot({ path: join(args.screenshots, 'home.png') });
    }
    const result = { run: run + 1, browser: browser.version(), cpuThrottle: Number(args.cpu || 1),
      softwareRequested: Boolean(args.software), iosUserAgentOnly: Boolean(args.ios) };
    result.startup = await page.evaluate(() => ({ readyMs: window.firstReadyMs, isolated: crossOriginIsolated,
      resources: performance.getEntriesByType('resource').map(r => ({ name: new URL(r.name).pathname,
        bytes: r.encodedBodySize, durationMs: r.duration })) }));
    result.renderer = result.startup.resources.some(r => /main\.dart\.wasm$/.test(r.name)) ? 'skwasm' : 'canvaskit';
    await page.getByRole('button', { name: '菜谱', exact: true }).click();
    await page.getByRole('group', { name: '菜品0 家常菜', exact: true }).waitFor();
    await page.waitForTimeout(400);
    if (args.screenshots && run === 0) await page.screenshot({ path: join(args.screenshots, 'cookbook.png') });
    await page.evaluate(() => Object.assign(window.benchmark, { active: true, frames: [], tasks: [], last: null }));
    const scrollStart = Date.now();
    await page.mouse.move(200, 550);
    for (let i = 0; i < 40; i++) { await page.mouse.wheel(0, 120); await page.waitForTimeout(30); }
    await page.waitForTimeout(150);
    const scroll = await page.evaluate(() => { window.benchmark.active = false; return window.benchmark; });
    result.scroll = { ...summary(scroll.frames, scroll.tasks), elapsedMs: Date.now() - scrollStart };
    result.photoRequests = requests.filter(r => r.path.startsWith('/media/')).reduce((all, r) => {
      const variant = r.path.split('/').at(-1); all[variant] = (all[variant] || 0) + 1; return all;
    }, {});
    await page.getByRole('button', { name: '首页', exact: true }).click();
    await home.waitFor(); await home.click();
    await page.getByText('记录做饭', { exact: true }).first().waitFor();
    await page.waitForTimeout(350);
    const beforeBack = requests.length;
    await page.evaluate(() => { window.backStarted = performance.now(); history.back(); });
    await page.waitForFunction(() => {
      const element = document.querySelector('[flt-semantics-identifier="home-record-action"]');
      if (element?.getBoundingClientRect().width > 0) { window.backReady = performance.now(); return true; }
      return false;
    }, null, { polling: 'raf' });
    result.historyBackMs = await page.evaluate(() => window.backReady - window.backStarted);
    result.backRequests = requests.slice(beforeBack).filter(r => r.path.startsWith('/api/')).map(r => r.path);
    await page.getByRole('button', { name: '日记', exact: true }).click();
    await page.locator('[flt-semantics-identifier="diary-entry"]').first().click();
    await page.getByText('美味回忆', { exact: true }).waitFor();
    const beforeGallery = requests.length;
    await page.getByRole('button', { name: '查看第 1 张完整照片', exact: true }).click();
    await page.getByText('1 / 1', { exact: true }).waitFor();
    await page.waitForTimeout(300);
    result.fullPhotoRequests = requests.slice(beforeGallery).filter(r => r.path.startsWith('/media/')).map(r => r.path);
    const touch = (x1, x2) => [{ x: x1, y: 450, id: 1 }, { x: x2, y: 450, id: 2 }];
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: touch(150, 240) });
    for (let step = 1; step <= 6; step++) {
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: touch(150 - step * 8, 240 + step * 8) });
      await page.waitForTimeout(20);
    }
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    await page.waitForTimeout(200);
    result.zoomOriginalLoaded = requests.slice(beforeGallery).some(r => r.path.endsWith('/original'));
    if (!result.zoomOriginalLoaded) throw new Error('Pinch zoom did not load original photo');
    result.errors = errors;
    if (errors.length) throw new Error(errors.join('\n'));
    samples.push(result);
    console.log(JSON.stringify({ run: result.run, renderer: result.renderer, readyMs: result.startup.readyMs,
      scroll: result.scroll, historyBackMs: result.historyBackMs, photos: result.photoRequests }));
    await context.close();
  }
  await mkdir(resolve(args.output, '..'), { recursive: true });
  await writeFile(args.output, JSON.stringify({ config: { ...args, viewport: '390x844@3', entries: 300,
    note: 'rAF intervals measure main-thread responsiveness, not actual rendered GPU FPS; iOS UA emulation is not iPhone WebKit.' }, samples }, null, 2));
} finally {
  server.closeAllConnections(); server.close(); await browser?.close();
}
