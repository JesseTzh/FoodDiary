import { chromium, expect as playwrightExpect } from '@playwright/test';
import { mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const expect = playwrightExpect.configure({ timeout: 30_000 });
const artifacts = resolve(process.env.CI_ARTIFACTS_DIR || 'mock-page-artifacts');
const baseURL = process.env.CI_BASE_URL || 'http://127.0.0.1:18081';
const browser = await chromium.launch({ headless: true });
const requiredPages = [
  'home', 'record', 'diary', 'diary-detail', 'diary-edit', 'diary-delete',
  'cookbook', 'recipe-detail', 'recipe-record', 'recipe-new', 'mine',
  'favorites', 'my-recipes', 'settings', 'login', 'setup',
];

try {
  for (const [layout, viewport] of Object.entries({
    mobile: { width: 390, height: 844 },
    desktop: { width: 1440, height: 1080 },
  })) {
    const directory = resolve(artifacts, layout);
    await mkdir(directory, { recursive: true });
    const context = await browser.newContext({
      viewport, deviceScaleFactor: 1, locale: 'zh-CN',
      timezoneId: 'Asia/Shanghai', reducedMotion: 'reduce',
    });
    context.setDefaultTimeout(30_000);
    await context.tracing.start({ screenshots: true, snapshots: true, sources: true });
    const page = await context.newPage();
    const logs = [], errors = [], captured = [];
    let current = 'startup';
    page.on('console', message => logs.push(`${message.type()}: ${message.text()}`));
    page.on('pageerror', error => errors.push(error.message));
    page.on('requestfailed', request => errors.push(`${request.url()}: ${request.failure()?.errorText}`));
    page.on('response', response => {
      if (response.status() >= 400) errors.push(`HTTP ${response.status()}: ${response.url()}`);
    });
    // Mock must never fall back to a real backend.
    await context.route('**/api/v1/**', route => {
      errors.push(`Unexpected backend request: ${route.request().url()}`);
      return route.abort();
    });
    const text = label => page.getByText(label, { exact: true }).last();
    const id = value => page.locator(`[flt-semantics-identifier="${value}"]`).first();
    async function click(locator) {
      await expect(locator).toBeVisible();
      await locator.scrollIntoViewIfNeeded();
      await locator.click();
    }
    async function capture(name, ready) {
      current = name;
      await expect(ready).toBeVisible();
      // Flutter paints to CanvasKit; wait for the semantics updates and paint frames.
      await page.evaluate(() => new Promise(resolve =>
        requestAnimationFrame(() => requestAnimationFrame(resolve))));
      await page.screenshot({ path: resolve(directory, `${name}.png`) });
      await writeFile(resolve(directory, `${name}-semantics.txt`), await page.locator('body').ariaSnapshot());
      captured.push(name);
    }
    async function back(ready) {
      await click(page.getByRole('button', { name: /Back|返回/ }).first());
      await expect(ready).toBeVisible();
    }
    try {
      await page.goto(baseURL, { waitUntil: 'domcontentloaded' });
      await expect(page.locator('#loading')).toHaveCount(0, { timeout: 60_000 });
      await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
      await capture('home', id('home-record-action'));
      await click(id('home-record-action'));
      await capture('record', text('晒晒今天的美味'));
      await back(id('home-record-action'));
      await click(text('日记'));
      await capture('diary', id('diary-entry'));
      await click(id('diary-entry'));
      await capture('diary-detail', text('美味回忆'));
      await click(text('编辑'));
      await capture('diary-edit', text('编辑日记'));
      await back(text('美味回忆'));
      await click(page.getByRole('button', { name: '删除日记' }));
      await capture('diary-delete', text('删除这份日记？'));
      await click(text('再想想'));
      await back(id('diary-entry'));
      await click(text('菜谱'));
      await capture('cookbook', page.getByRole('button', { name: '创建菜谱' }));
      await click(page.getByRole('group', { name: '番茄炒蛋 家常菜', exact: true }));
      await capture('recipe-detail', text('今日菜谱'));
      await click(text('今天就做这道菜'));
      await capture('recipe-record', text('晒晒今天的美味'));
      await back(text('今日菜谱'));
      await back(page.getByRole('button', { name: '创建菜谱' }));
      await click(page.getByRole('button', { name: '创建菜谱' }));
      await capture('recipe-new', text('我的拿手菜'));
      await back(page.getByRole('button', { name: '创建菜谱' }));
      await click(text('我的'));
      await capture('mine', text('我的收藏'));
      for (const [name, label, ready] of [
        ['favorites', '我的收藏', '番茄炒蛋'],
        ['my-recipes', '我的菜谱', '把喜欢的美味，慢慢收集起来吧 ♡'],
      ]) {
        await click(text(label));
        await capture(name, page.getByText(ready, { exact: false }).first());
        await back(text('我的收藏'));
      }
      await click(text('设置'));
      await capture('settings', text('保存资料'));
      await click(text('退出小厨房'));
      await capture('login', id('login-password-prompt'));
      // Exercise the first-run variant through the isolated mock store.
      await page.evaluate(() => {
        const key = 'flutter.fooddiary:mock:v1';
        const state = JSON.parse(JSON.parse(localStorage.getItem(key)));
        state.auth_required = false;
        localStorage.setItem(key, JSON.stringify(JSON.stringify(state)));
      });
      await page.reload({ waitUntil: 'domcontentloaded' });
      await expect(page.locator('#loading')).toHaveCount(0, { timeout: 60_000 });
      await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
      await capture('setup', id('first-run-password-prompt'));
      expect(captured).toEqual(requiredPages);
      expect(errors, 'Browser errors and unexpected backend calls').toEqual([]);
      await writeFile(resolve(directory, 'manifest.json'), JSON.stringify({ layout, viewport, pages: captured }, null, 2));
    } catch (error) {
      await page.screenshot({ path: resolve(directory, `${current}-failure.png`), timeout: 5000 }).catch(() => {});
      throw error;
    } finally {
      await writeFile(resolve(directory, 'browser.log'), [...logs, ...errors].join('\n'));
      await writeFile(resolve(directory, 'last-semantics.txt'), await page.locator('body').ariaSnapshot({ timeout: 5000 }).catch(() => 'Unavailable'));
      await context.tracing.stop({ path: resolve(directory, 'trace.zip') });
      await context.close();
    }
  }
} finally {
  await browser.close();
}
