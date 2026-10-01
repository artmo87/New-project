/* Therapist Copilot service worker: caches the app shell so it opens offline. No network calls other than fetching its own files. */
const VERSION = 'tc-v1';
const SHELL = [
  './', './index.html', './manifest.webmanifest', './assets/app.css',
  './assets/icons/icon-192.png', './assets/icons/icon-512.png', './assets/icons/icon-maskable-512.png', './assets/icons/apple-touch-icon.png',
  './js/util.js', './js/lexicon.js', './js/db.js', './js/transcriber.js', './js/recorder.js', './js/insights.js', './js/ondevice-ai.js', './js/exporter.js', './js/app.js'
];
self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(VERSION).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', (event) => {
  event.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  event.respondWith(
    caches.match(req, { ignoreSearch: true }).then((cached) => {
      const network = fetch(req).then((res) => {
        if (res && res.ok) caches.open(VERSION).then((cache) => cache.put(req, res.clone()));
        return res;
      }).catch(() => cached);
      return cached || network;
    })
  );
});
self.addEventListener('message', (event) => { if (event.data === 'skipWaiting') self.skipWaiting(); });
