import { chromium, expect as playwrightExpect } from '@playwright/test';
import { mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const phases = new Set(['first-run', 'home', 'after-restart']);
const phase = process.argv[2];
if (!phases.has(phase)) throw new Error('Usage: node smoke.mjs first-run|home|after-restart');

const timeout = 30_000;
const expect = playwrightExpect.configure({ timeout });
const artifacts = resolve(process.env.CI_ARTIFACTS_DIR || 'web-startup-artifacts');
const baseURL = process.env.CI_BASE_URL || 'http://127.0.0.1:18080';
const password = process.env.CI_PASSWORD || 'ci-password-1234';
await mkdir(artifacts, { recursive: true });

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({
  viewport: { width: 1440, height: 1080 },
  deviceScaleFactor: 1,
  locale: 'zh-CN',
  timezoneId: 'Asia/Shanghai',
  reducedMotion: 'reduce',
});
context.setDefaultTimeout(timeout);
await context.tracing.start({ screenshots: true, snapshots: true, sources: true });
const page = await context.newPage();
const messages = [];
const errors = [];
let authenticationStarted = false;
let unauthenticatedRefreshes = 0;

function isInitialRefresh(response) {
  const request = response.request();
  return !authenticationStarted && response.status() === 401 &&
    request.method() === 'POST' &&
    new URL(response.url()).pathname === '/api/v1/auth/refresh';
}

function installDiagnostics() {
  page.on('console', (message) => messages.push(`${message.type()}: ${message.text()}`));
  page.on('pageerror', (error) => errors.push(`Uncaught: ${error.message}`));
  page.on('requestfailed', (request) => {
    const reason = request.failure()?.errorText || 'unknown request failure';
    const url = new URL(request.url());
    // Flutter cancels the initial auth probe while replacing its loading frame.
    if (reason === 'net::ERR_ABORTED' && request.method() === 'GET' &&
        url.pathname === '/api/v1/auth/status') {
      messages.push(`Expected request cancellation: ${request.url()}`);
      return;
    }
    errors.push(`${request.url()}: ${reason}`);
  });
  page.on('response', (response) => {
    if (isInitialRefresh(response)) {
      unauthenticatedRefreshes++;
      messages.push(`Expected unauthenticated refresh: ${response.url()}`);
      return;
    }
    if (response.status() >= 400) errors.push(`HTTP ${response.status()}: ${response.url()}`);
  });
}

async function startApplication() {
  await page.goto(baseURL, { waitUntil: 'domcontentloaded', timeout: 60_000 });
  await expect(page.locator('#loading')).toHaveCount(0, { timeout: 60_000 });
  // CanvasKit exposes controls through Flutter's semantics tree after this click.
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
}

async function assertFirstRun() {
  await expect(page.locator('[flt-semantics-identifier="first-run-password-prompt"]')).toBeVisible();
  await expect(page.locator('[flt-semantics-identifier="setup-password-input"]')).toBeVisible();
  await expect(page.locator('[flt-semantics-identifier="setup-submit"]')).toBeVisible();
}

async function authenticate() {
  await expect(page.locator('[flt-semantics-identifier="login-password-prompt"]')).toBeVisible();
  await page.locator('[flt-semantics-identifier="login-password-input"]').fill(password);
  authenticationStarted = true;
  await page.locator('[flt-semantics-identifier="login-submit"]').click();
  await expect(page.locator('[flt-semantics-identifier="home-record-action"]')).toBeVisible();
}

async function assertPersistedEntry() {
  const entry = page.locator('[flt-semantics-identifier="diary-entry"]').first();
  await entry.scrollIntoViewIfNeeded();
  await expect(entry).toBeVisible();
}

async function saveEvidence() {
  await page.screenshot({ path: resolve(artifacts, `${phase}.png`) });
  if (unauthenticatedRefreshes > 1) {
    throw new Error(`Expected at most one unauthenticated refresh probe, got ${unauthenticatedRefreshes}`);
  }
  expect(errors, 'Browser errors and failed resources').toEqual([]);
}

installDiagnostics();
try {
  await startApplication();
  if (phase === 'first-run') {
    await assertFirstRun();
  } else {
    await authenticate();
    if (phase === 'after-restart') await assertPersistedEntry();
  }
  await saveEvidence();
  console.log(`Web ${phase} verified; screenshot saved to ${artifacts}`);
} catch (error) {
  await page.screenshot({ path: resolve(artifacts, `${phase}-failure.png`), timeout: 5000 }).catch(() => {});
  throw error;
} finally {
  await writeFile(
    resolve(artifacts, `${phase}-semantics.txt`),
    await page.locator('body').ariaSnapshot({ timeout: 5000 }).catch(() => 'Semantics unavailable'),
  );
  await writeFile(resolve(artifacts, `${phase}-browser.log`), [...messages, ...errors].join('\n'));
  await context.tracing.stop({ path: resolve(artifacts, `${phase}-trace.zip`) });
  await browser.close();
}
