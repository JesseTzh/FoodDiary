"""Generate a versioned offline shell from the actual Flutter build output."""
from pathlib import Path
import hashlib
import json
root = Path(__file__).resolve().parent.parent / 'frontend/build/web'
paths = sorted(p for p in root.rglob('*') if p.is_file() and p.name not in ('sw.js', 'flutter_service_worker.js') and not p.name.endswith('.map'))
digest = hashlib.sha256()
for p in paths:
    digest.update(p.relative_to(root).as_posix().encode())
    digest.update(p.read_bytes())
assets = ['./'] + ['./' + p.relative_to(root).as_posix() for p in paths]
worker = '''
const VERSION = __VERSION__;
const SHELL = 'fooddiary-shell-' + VERSION;
const MEDIA = 'fooddiary-photos';
const ASSETS = __ASSETS__;
self.addEventListener('install', event => {
  event.waitUntil(caches.open(SHELL).then(cache => cache.addAll(ASSETS)));
});
self.addEventListener('message', event => {
  if (event.data === 'activate') self.skipWaiting();
  if (event.data === 'clear-photos') event.waitUntil(caches.delete(MEDIA));
});
self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(key => (key.startsWith('fooddiary-shell-') && key !== SHELL) || key === 'flutter-app-cache' || key === 'flutter-temp-cache' || key === 'flutter-app-manifest').map(key => caches.delete(key)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', event => {
  const req = event.request, url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname.endsWith('/api/v1/auth/logout')) event.waitUntil(caches.delete(MEDIA));
  if (req.method !== 'GET' || url.pathname.startsWith('/api/') || url.pathname.startsWith('/health/')) return;
  if (url.pathname.startsWith('/media/')) {
    event.respondWith(fetch(req).then(async response => {
      if (response.ok) {
        const cache = await caches.open(MEDIA);
        await cache.put(req, response.clone());
        const keys = await cache.keys();
        if (keys.length > 100) await cache.delete(keys[0]);
      }
      return response;
    }).catch(async () => (await caches.match(req)) || Response.error()));
    return;
  }
  event.respondWith(caches.open(SHELL).then(async cache => {
    const cached = await cache.match(req, {ignoreSearch: true});
    if (cached) return cached;
    if (req.mode === 'navigate') return cache.match('./index.html');
    return fetch(req);
  }));
});
'''
(root / 'sw.js').write_text(worker.replace('__VERSION__', json.dumps(digest.hexdigest()[:16])).replace('__ASSETS__', json.dumps(assets)), encoding='utf-8')
print(f'PWA: {len(assets)} resources, cache {digest.hexdigest()[:16]}')
