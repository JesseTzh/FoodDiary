import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../../build-pwa.py', import.meta.url), 'utf8')
  .match(/worker = '''([\s\S]*?)'''/)[1]
  .replace('__VERSION__', '"test"').replace('__ASSETS__', '[]');

function worker({ cached, network, failStorage = false }) {
  const handlers = {};
  let fetches = 0, writes = 0;
  const cache = {
    match: async () => cached,
    put: async () => { writes++; if (failStorage) throw new Error('quota'); },
    keys: async () => [],
  };
  vm.runInNewContext(source, {
    self: { location: { origin: 'https://food.example.com' }, addEventListener: (name, handler) => { handlers[name] = handler; } },
    URL, Date, Response,
    caches: { open: async () => cache },
    fetch: async () => { fetches++; if (network instanceof Error) throw network; return network; },
  });
  return {
    async request() {
      let response;
      const pending = [];
      handlers.fetch({
        request: new Request('https://food.example.com/media/assets/photo/thumbnail'),
        respondWith: promise => { response = promise; },
        waitUntil: promise => pending.push(promise),
      });
      const result = await response;
      await Promise.all(pending);
      return result;
    },
    get fetches() { return fetches; },
    get writes() { return writes; },
  };
}

test('fresh photos render from cache without a request', async () => {
  const cached = new Response('cached', { headers: { date: new Date().toUTCString() } });
  const instance = worker({ cached, network: new Error('should not fetch') });
  assert.equal(await (await instance.request()).text(), 'cached');
  assert.equal(instance.fetches, 0);
});

test('storage quota errors do not hide a downloaded image', async () => {
  const instance = worker({ network: new Response('photo'), failStorage: true });
  assert.equal(await (await instance.request()).text(), 'photo');
  assert.equal(instance.writes, 1);
});

test('expired images refresh and remain available offline', async () => {
  const cached = new Response('old', { headers: { date: new Date(0).toUTCString() } });
  const online = worker({ cached, network: new Response('new') });
  assert.equal(await (await online.request()).text(), 'new');
  assert.equal(online.fetches, 1);
  const offline = worker({ cached, network: new Error('offline') });
  assert.equal(await (await offline.request()).text(), 'old');
});
