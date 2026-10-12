{{flutter_js}}
{{flutter_build_config}}
_flutter.loader.load({
  config: { renderer: 'canvaskit', canvasKitBaseUrl: 'canvaskit/' },
  onEntrypointLoaded: async function(engineInitializer) {
    const runner = await engineInitializer.initializeEngine();
    await runner.runApp();
    document.getElementById('loading')?.remove();
  }
});
if ('serviceWorker' in navigator) {
  window.addEventListener('load', async () => {
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
  });
}
