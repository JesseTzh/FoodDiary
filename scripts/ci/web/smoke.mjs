import { chromium, expect as playwrightExpect } from '@playwright/test';
import { mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const phase = process.argv[2];
const expect = playwrightExpect.configure({ timeout: 30_000 });
if (!['first-run', 'home', 'after-restart'].includes(phase)) {
  throw new Error('Usage: node smoke.mjs first-run|home|after-restart');
}
const artifacts = resolve(process.env.CI_ARTIFACTS_DIR || 'web-startup-artifacts');
const baseURL = process.env.CI_BASE_URL || 'http://127.0.0.1:18080';
await mkdir(artifacts, { recursive: true });
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({
  viewport: { width: 1440, height: 1080 },
  deviceScaleFactor: 1,
  locale: 'zh-CN',
  timezoneId: 'Asia/Shanghai',
  reducedMotion: 'reduce',
});
context.setDefaultTimeout(30_000);
await context.tracing.start({ screenshots: true, snapshots: true, sources: true });
const page = await context.newPage();
const messages = [];
const errors = [];
let authenticationExpected = false;
let unauthenticatedRefreshes = 0;
page.on('console', (message) => messages.push(`${message.type()}: ${message.text()}`));
page.on('pageerror', (error) => errors.push(`Uncaught: ${error.message}`));
page.on('requestfailed', (request) => errors.push(`${request.url()}: ${request.failure()?.errorText}`));
page.on('response', (response) => {
  const request = response.request();
  // Each phase starts with a fresh browser context and no HttpOnly auth cookies.
  // The JWT client probes for a renewable session before showing setup/login.
  // Allow only this initial rejection; refresh failures after login remain errors.
  if (!authenticationExpected && response.status() === 401 &&
      request.method() === 'POST' && response.url() === `${baseURL}/api/v1/auth/refresh`) {
    unauthenticatedRefreshes++;
    messages.push(`Expected unauthenticated refresh: ${response.url()}`);
    return;
  }
  if (response.status() >= 400) errors.push(`HTTP ${response.status()}: ${response.url()}`);
});

try {
  await page.goto(baseURL, { waitUntil: 'domcontentloaded', timeout: 60_000 });
  await expect(page.locator('#loading')).toHaveCount(0, { timeout: 60_000 });
  // CanvasKit paints text on a canvas. Enable Flutter's real accessibility tree
  // so assertions and interactions target UI semantics rather than coordinates.
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  if (phase === 'first-run') {
    await expect(page.getByText('给我们的小厨房设一个密码', { exact: true })).toBeVisible();
    await expect(page.getByRole('textbox')).toBeVisible();
    await expect(page.getByRole('button', { name: '开启做饭日记', exact: true })).toBeVisible();
  } else {
    await expect(page.getByText('欢迎回到我们的小厨房', { exact: true })).toBeVisible();
    await page.getByRole('textbox').fill(process.env.CI_PASSWORD || 'ci-password-1234');
    authenticationExpected = true;
    await Promise.all([
      // Login is the deterministic boundary of this interaction. The home
      // page starts its entries/recipes/profile requests concurrently after
      // login, so waiting for one of those requests makes the smoke test
      // sensitive to harmless loading order and service-worker timing.
      page.waitForResponse((response) => response.url().endsWith('/api/v1/auth/login') && response.ok()),
      page.getByRole('button', { name: '进入小厨房', exact: true }).click(),
    ]);
    await expect(page.getByText('今天也要好好吃饭呀～')).toBeVisible();
    if (phase === 'after-restart') {
      if (!process.env.CI_ENTRY_TITLE) throw new Error('CI_ENTRY_TITLE is required after restart');
      const entry = page.getByText(process.env.CI_ENTRY_TITLE).first();
      await entry.scrollIntoViewIfNeeded();
      await expect(entry).toBeVisible();
    }
  }
  await page.screenshot({ path: resolve(artifacts, `${phase}.png`) });
  expect(unauthenticatedRefreshes, 'At most one refresh probe before login').toBeLessThanOrEqual(1);
  expect(errors, 'Browser errors and failed resources').toEqual([]);
  console.log(`Web ${phase} verified; screenshot saved to ${artifacts}`);
} catch (error) {
  await page.screenshot({ path: resolve(artifacts, `${phase}-failure.png`), timeout: 5000 }).catch(() => {});
  throw error;
} finally {
  await writeFile(resolve(artifacts, `${phase}-semantics.txt`), await page.locator('body').ariaSnapshot({ timeout: 5000 }).catch(() => 'Semantics unavailable'));
  await writeFile(resolve(artifacts, `${phase}-browser.log`), [...messages, ...errors].join('\n'));
  await context.tracing.stop({ path: resolve(artifacts, `${phase}-trace.zip`) });
  await browser.close();
}
