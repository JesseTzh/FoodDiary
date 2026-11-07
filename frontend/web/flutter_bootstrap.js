{{flutter_js}}
{{flutter_build_config}}
_flutter.loader.load({
  // Let Flutter select skwasm on supported browsers and CanvasKit otherwise.
  config: { canvasKitBaseUrl: 'canvaskit/' },
  onEntrypointLoaded: async function(engineInitializer) {
    const runner = await engineInitializer.initializeEngine();
    await runner.runApp();
    document.getElementById('loading')?.remove();
    // Offline installation must not compete with the application's first paint.
    requestAnimationFrame(() => requestAnimationFrame(() => {
      if ('requestIdleCallback' in window) {
        requestIdleCallback(registerPwa, { timeout: 3000 });
      } else {
        setTimeout(registerPwa, 1000);
      }
    }));
  }
});
async function registerPwa() {
  if ('serviceWorker' in navigator) {
    try {
      const registration = await navigator.serviceWorker.register('sw.js');
      function offerUpdate() {
        if (!registration.waiting || !navigator.serviceWorker.controller) return;
        document.getElementById('update').style.display = 'block';
        document.getElementById('reload').onclick = () => registration.waiting.postMessage('activate');
      }
      offerUpdate();
      registration.addEventListener('updatefound', () => {
        registration.installing?.addEventListener('statechange', offerUpdate);
      });
      navigator.serviceWorker.addEventListener('controllerchange', () => {
        if (document.getElementById('update').style.display === 'block') location.reload();
      });
    } catch (error) { console.debug('PWA registration unavailable', error); }
  }
}
