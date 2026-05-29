// Magilu Finance - Service Worker
// Estrategia: NETWORK-FIRST para HTML (siempre busca versión nueva),
//             cache-first solo para assets estáticos (iconos, fuentes).

const CACHE_NAME = 'magilu-finance-v21';  // ← subir este número en cada despliegue importante
const SHELL_FILES = [
  './manifest.json',
];

// Install: cachear shell mínimo y activar inmediatamente
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(SHELL_FILES))
      .then(() => self.skipWaiting())
  );
});

// Activate: limpiar TODOS los caches viejos
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((names) => {
      return Promise.all(
        names.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n))
      );
    }).then(() => self.clients.claim())
  );
});

// Fetch:
// - Supabase: siempre network (datos en vivo)
// - HTML (navegación): NETWORK-FIRST (siempre versión más nueva; caché solo si offline)
// - Resto (iconos, fuentes, JS CDN): cache-first
self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  // No tocar Supabase
  if (url.hostname.includes('supabase.co') || url.hostname.includes('supabase.in')) {
    return;
  }

  // Solo GET
  if (event.request.method !== 'GET') {
    return;
  }

  const isHTML = event.request.mode === 'navigate'
    || (event.request.headers.get('accept') || '').includes('text/html');

  if (isHTML) {
    // NETWORK-FIRST: busca la versión nueva, cae a caché solo si no hay red
    event.respondWith(
      fetch(event.request).then((response) => {
        if (response.ok && url.origin === self.location.origin) {
          const clone = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone));
        }
        return response;
      }).catch(() => {
        return caches.match(event.request).then((cached) => {
          return cached || caches.match('./index.html');
        });
      })
    );
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
