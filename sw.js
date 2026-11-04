// Magilu Finance - Service Worker
// Estrategia:
//  · Al instalarse descarga TODAS las páginas y librerías: la app abre sin cobertura
//    aunque no se haya visitado antes cada pantalla.
//  · Páginas (HTML): primero la red, pero si no responde en 4 s se sirve la copia
//    guardada (cobertura floja = la app no se queda en blanco).
//  · Resto (iconos, librerías, fuentes): primero la copia guardada.
//  · Supabase: nunca se guarda aquí (los datos sin conexión los gestiona offline.js).

const CACHE_NAME = 'magilu-finance-v40';  // ← subir este número en cada despliegue importante
const PRECACHE = [
  './',
  './index.html',
  './depositos.html',
  './tesoreria.html',
  './recaudacion.html',
  './contactos.html',
  './productos.html',
  './dashboard.html',
  './plan_financiero_magilu.html',
  './manifest.json',
  './privacy.js',
  './localbackup.js',
  './offline.js',
  './vendor/supabase-js-2.100.1.js',
  './vendor/jspdf-2.5.1.umd.min.js',
  './vendor/jspdf-autotable-3.8.2.min.js',
  './icon-192.png',
  './icon-512.png',
  './icon-maskable-192.png',
  './icon-maskable-512.png',
  './apple-touch-icon.png',
  './favicon.ico',
  './favicon-16.png',
  './favicon-32.png',
];
const NETWORK_TIMEOUT_MS = 4000;

// Install: precargar todo (si falla un archivo suelto, el resto se guarda igual)
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => Promise.all(PRECACHE.map((url) =>
        cache.add(new Request(url, { cache: 'reload' })).catch(() => null))))
      .then(() => self.skipWaiting())
  );
});

// Activate: limpiar TODOS los caches viejos
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((names) => Promise.all(
      names.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n))
    )).then(() => self.clients.claim())
  );
});

function cachedPage(request) {
  // depositos.html?dep=… usa la misma copia que depositos.html
  return caches.match(request, { ignoreSearch: true })
    .then((hit) => hit || caches.match('./index.html'));
}

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  // No tocar Supabase
  if (url.hostname.includes('supabase.co') || url.hostname.includes('supabase.in')) return;
  // Solo GET
  if (event.request.method !== 'GET') return;

  const isHTML = event.request.mode === 'navigate'
    || (event.request.headers.get('accept') || '').includes('text/html');

  if (isHTML) {
    event.respondWith(new Promise((resolve) => {
      let settled = false;
      const done = (resp) => { if (!settled && resp) { settled = true; resolve(resp); } };

      const net = fetch(event.request).then((response) => {
        if (response.ok && url.origin === self.location.origin) {
          const clone = response.clone();
          // Se guarda sin la parte ?… para que valga para cualquier depósito
          caches.open(CACHE_NAME).then((cache) => cache.put(url.origin + url.pathname, clone));
        }
        return response;
      });

      // Red lenta: a los 4 s se sirve la copia (si existe) y la red sigue en segundo plano
      const timer = setTimeout(() => { cachedPage(event.request).then(done); }, NETWORK_TIMEOUT_MS);

      net.then((resp) => { clearTimeout(timer); done(resp); })
        .catch(() => { clearTimeout(timer); cachedPage(event.request).then((hit) => done(hit || Response.error())); });
    }));
    return;
  }

  // Assets estáticos: cache-first
  event.respondWith(
    caches.match(event.request).then((cached) => {
      if (cached) return cached;
      return fetch(event.request).then((response) => {
        if (response.ok && (url.origin === self.location.origin
            || url.hostname.includes('fonts.googleapis.com')
            || url.hostname.includes('fonts.gstatic.com')
            || url.hostname.includes('cdn.jsdelivr.net'))) {
          const clone = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone));
        }
        return response;
      });
    })
  );
});
