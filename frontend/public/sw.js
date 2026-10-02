// 策略说明：
// - 页面导航：网络优先，失败时才回退缓存（离线可用），且只缓存成功响应。
// - /assets/ 下带哈希的构建产物：缓存优先（内容不可变）。
// - 其余请求（开发模式的 /src/*、sw.js 自身等）一律不拦截，
//   绝不允许用 HTML 响应去满足脚本/样式请求（否则触发严格 MIME 报错）。
// 升级任何缓存策略时必须递增 CACHE 版本号，activate 时会删除旧版本缓存。
const CACHE = 'fooddiary-v2';

self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(CACHE).then((c) => c.addAll(['/'])).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  // 动态数据、媒体与健康检查永远直连网络，不进缓存。
  if (url.pathname.startsWith('/api/') || url.pathname.startsWith('/media/') || url.pathname.startsWith('/health')) return;

  const isNavigation = req.mode === 'navigate' || (req.headers.get('accept') || '').includes('text/html');
  if (isNavigation) {
    e.respondWith(
      fetch(req)
        .then((res) => {
          if (res.ok) {
            const copy = res.clone();
            caches.open(CACHE).then((c) => c.put(req, copy));
          }
          return res;
        })
        .catch(() => caches.match(req).then((hit) => hit || caches.match('/')))
    );
    return;
  }

  const isImmutableAsset = url.pathname.startsWith('/assets/') || url.pathname === '/manifest.webmanifest';
  if (isImmutableAsset) {
    e.respondWith(
      caches.match(req).then(
        (hit) =>
          hit ||
          fetch(req).then((res) => {
            if (res.ok) {
              const copy = res.clone();
              caches.open(CACHE).then((c) => c.put(req, copy));
            }
            return res;
          })
      )
    );
  }
  // 其余请求不调用 respondWith，交给浏览器默认处理。
});
