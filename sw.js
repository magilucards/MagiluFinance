// Magilu Finance - Service Worker
// Estrategia: cache-first para shell, network para datos Supabase

const CACHE_NAME = 'magilu-finance-v1';
const SHELL_FILES = [
  './',
  './index.html',
  './manifest.json',
];

// Install: cachear shell
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(SHELL_FILES))
      .then(() => self.skipWaiting())
  );
});

// Activate: limpiar caches viejos
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
// - Llamadas a Supabase: SIEMPRE network (no cachear datos sensibles)
// - Resto: cache-first con fallback a network
self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  
  // No cachear llamadas a Supabase ni APIs
  if (url.hostname.includes('supabase.co') || url.hostname.includes('supabase.in')) {
    return; // dejar que el navegador maneje la petición normalmente
  }
  
  // No cachear peticiones POST/PUT/DELETE
  if (event.request.method !== 'GET') {
    return;
  }
  
  // Shell: cache-first
  event.respondWith(
    caches.match(event.request).then((cached) => {
      if (cached) return cached;
      return fetch(event.request).then((response) => {
        // Cachear nuevos recursos del shell
        if (response.ok && (url.origin === self.location.origin || url.hostname.includes('fonts.googleapis.com') || url.hostname.includes('fonts.gstatic.com') || url.hostname.includes('cdn.jsdelivr.net'))) {
          const responseClone = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, responseClone));
        }
        return response;
      }).catch(() => {
        // Offline fallback: si pide HTML, devolver index
        if (event.request.headers.get('accept')?.includes('text/html')) {
          return caches.match('./index.html');
        }
      });
    })
  );
});
