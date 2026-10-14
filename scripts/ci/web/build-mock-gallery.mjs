import { copyFile, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { layouts, pages } from './mock-page-catalog.mjs';

const artifacts = resolve(process.env.CI_ARTIFACTS_DIR || 'mock-page-artifacts');
const output = resolve(artifacts, 'site');
const escape = value => String(value).replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);

// Fail rather than publishing a partial gallery. Only reviewed PNGs enter the site;
// traces, logs, semantics snapshots and failure screenshots remain CI artifacts.
for (const [layout, viewport] of Object.entries(layouts)) {
  const manifest = JSON.parse(await readFile(resolve(artifacts, layout, 'manifest.json'), 'utf8'));
  if (manifest.layout !== layout || JSON.stringify(manifest.viewport) !== JSON.stringify(viewport)
      || JSON.stringify(manifest.pages) !== JSON.stringify(pages.map(page => page.id))) {
    throw new Error(`Incomplete or incompatible screenshot manifest: ${layout}`);
  }
}
// Remove old generated assets so removed interfaces cannot linger on the public site.
await rm(output, { recursive: true, force: true });
for (const layout of Object.keys(layouts)) {
  await mkdir(resolve(output, layout), { recursive: true });
  for (const page of pages) {
    await copyFile(resolve(artifacts, layout, `${page.id}.png`), resolve(output, layout, `${page.id}.png`));
  }
}

const sha = process.env.GALLERY_SHA || process.env.GITHUB_SHA || '本地预览';
const repository = process.env.GITHUB_REPOSITORY;
const runID = process.env.GITHUB_RUN_ID;
const runURL = repository && runID ? `https://github.com/${repository}/actions/runs/${runID}` : null;
const generated = new Intl.DateTimeFormat('zh-CN', {
  timeZone: 'Asia/Shanghai', dateStyle: 'medium', timeStyle: 'short', hour12: false,
}).format(new Date());
const navigation = [...new Set(pages.map(page => page.group))].map(group => `
  <h3>${escape(group)}</h3>
  ${pages.filter(page => page.group === group).map(page => `<a href="#${page.id}">${escape(page.title)}</a>`).join('\n')}
`).join('\n');
const content = pages.map((page, index) => `
  <article id="${page.id}" class="page-card" data-search="${escape([page.title, page.id, page.group, page.description, ...page.features].join(' '))}">
    <header class="page-header"><span class="number">${String(index + 1).padStart(2, '0')}</span><div><p class="eyebrow">${escape(page.group)} / ${page.id}</p><h2>${escape(page.title)}</h2></div><a class="permalink" href="#${page.id}" aria-label="链接到${escape(page.title)}">#</a></header>
    <p class="description">${escape(page.description)}</p>
    <p class="entry"><strong>进入路径</strong> ${escape(page.entry)}</p>
    <ul class="features">${page.features.map(feature => `<li>${escape(feature)}</li>`).join('')}</ul>
    <div class="screenshots">${Object.entries(layouts).map(([layout, viewport]) => `
      <figure class="${layout}"><figcaption>${layout === 'mobile' ? '手机' : '桌面'} <span>${viewport.width} × ${viewport.height}</span></figcaption>
        <a class="screenshot" href="${layout}/${page.id}.png" data-title="${escape(page.title)} · ${layout === 'mobile' ? '手机' : '桌面'}" aria-label="查看${escape(page.title)}${layout === 'mobile' ? '手机' : '桌面'}原图">
          <img src="${layout}/${page.id}.png" width="${viewport.width}" height="${viewport.height}" loading="lazy" alt="${escape(page.title)}${layout === 'mobile' ? '手机' : '桌面'}界面截图">
        </a></figure>`).join('')}
    </div>
    <p class="review"><strong>检视重点</strong> ${escape(page.review)}</p>
  </article>`).join('\n');

await writeFile(resolve(output, 'index.html'), `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="color-scheme" content="light"><title>做饭日记 · 界面检视</title><link rel="stylesheet" href="gallery.css"><script src="gallery.js" defer></script></head>
<body>
  <a class="skip" href="#main">跳到界面截图</a>
  <aside class="sidebar"><a class="brand" href="#top">做饭日记<span>FoodDiary / 界面检视</span></a><nav aria-label="界面目录">${navigation}</nav><p class="sidebar-note">16 个界面 · 32 张截图<br>手机与桌面双端对照</p></aside>
  <main id="main"><header id="top" class="hero"><p class="eyebrow">小厨房 · 界面图册</p><h1>每一份美味，<br>都值得仔细看看。</h1><p>沿着使用路径浏览每个界面，了解功能，再对照手机与桌面的实际呈现。</p><p class="metadata">版本 <code>${escape(sha.slice(0, 12))}</code> · 生成于 ${escape(generated)}（北京时间）${runURL ? ` · <a href="${escape(runURL)}">查看截图任务</a>` : ''}</p><p class="notice">截图来自独立 Mock 数据，仅展示当前视口；长页面的下方内容未全部收录。点击图片可放大或查看原图。</p></header>
  <section class="toolbar" aria-label="浏览选项"><label>查找界面 <input id="search" type="search" placeholder="名称、功能或页面 ID"></label><fieldset><legend>显示布局</legend><label><input type="radio" name="layout" value="both" checked>双端</label><label><input type="radio" name="layout" value="mobile">手机</label><label><input type="radio" name="layout" value="desktop">桌面</label></fieldset><span id="count" role="status">${pages.length} 个界面</span></section>
  <div id="pages">${content}</div><p id="empty" hidden>没有找到匹配的界面，请换个关键词。</p><footer>做饭日记 · 截图与功能说明随截图流程生成</footer></main>
  <dialog id="viewer" aria-labelledby="viewer-title"><header><h2 id="viewer-title"></h2><a id="original" target="_blank" rel="noopener">打开原图</a><button id="close" type="button">关闭</button></header><div class="image-scroll"><img id="viewer-image" alt=""></div></dialog>
</body></html>`, 'utf8');
for (const filename of ['gallery.css', 'gallery.js']) {
  await copyFile(fileURLToPath(new URL(`./mock-gallery/${filename}`, import.meta.url)), resolve(output, filename));
}
await writeFile(resolve(output, '.nojekyll'), '');
console.log(`Generated ${pages.length} interfaces / ${pages.length * Object.keys(layouts).length} screenshots: ${output}`);
