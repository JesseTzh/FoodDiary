// Run only against a disposable local backend; creates a synthetic test account.
import { chromium, expect } from '@playwright/test';
const base = process.env.CI_BASE_URL || 'http://127.0.0.1:18764';
if (!['127.0.0.1', 'localhost'].includes(new URL(base).hostname)) {
  throw new Error('Offline smoke test requires a disposable local backend');
}
const password = process.env.CI_PASSWORD || 'web-offline-test-1234';
const browser = await chromium.launch({ headless: true,
  ...(process.env.CI_BROWSER_CHANNEL ? { channel: process.env.CI_BROWSER_CHANNEL } : {}) });
try {
  for (const safariSelection of [false, true]) {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 3,
      ...(safariSelection ? { userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1' } : {}) });
    if (safariSelection) await context.addInitScript(() => {
      Object.defineProperty(navigator, 'vendor', { get: () => 'Apple Computer, Inc.' });
    });
    const status = (await (await context.request.get(`${base}/api/v1/auth/status`)).json()).data;
    const login = await context.request.post(`${base}/api/v1/auth/${status.auth_required ? 'login' : 'setup'}`, {
      headers: { Origin: base }, data: { password },
    });
    expect(login.ok()).toBeTruthy();
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    page.on('response', response => { if (response.status() >= 400) errors.push(`HTTP ${response.status()}: ${response.url()}`); });
    await page.goto(base);
    await page.locator('#loading').waitFor({ state: 'detached', timeout: 60000 });
    await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
    await expect(page.locator('[flt-semantics-identifier="home-record-action"]')).toBeVisible({ timeout: 30000 });
    await page.evaluate(() => navigator.serviceWorker.ready);
    await page.waitForFunction(() => navigator.serviceWorker.controller !== null);
    await page.waitForFunction(() => Object.keys(localStorage).some(key => key.startsWith('flutter.snapshot:')));
    const online = await page.evaluate(async () => ({ isolated: crossOriginIsolated,
      engines: performance.getEntriesByType('resource').map(r => r.name).filter(n => /(?:skwasm|canvaskit)\.(?:js|wasm)/.test(n)),
      cached: (await caches.keys()).filter(key => key.startsWith('fooddiary-shell-')) }));
    expect(online.isolated).toBeTruthy(); expect(online.cached.length).toBe(1);
    expect(errors).toEqual([]);
    await context.setOffline(true);
    await page.reload();
    await page.locator('#loading').waitFor({ state: 'detached', timeout: 60000 });
    await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
    await expect(page.getByRole('group', { name: '离线浏览 · 显示上次保存的内容', exact: true })).toBeVisible({ timeout: 30000 }).catch(async error => {
      console.error(JSON.stringify({ errors, semantics: await page.locator('body').ariaSnapshot(),
        storageKeys: await page.evaluate(() => Object.keys(localStorage)),
        cached: await page.evaluate(async () => caches.keys()) }));
      throw error;
    });
    await expect(page.locator('[flt-semantics-identifier="home-record-action"]')).toBeVisible();
    console.log(JSON.stringify({ safariSelectionOnly: safariSelection, online, offlineReload: 'passed', errors }));
    await context.close();
  }
} finally { await browser.close(); }
