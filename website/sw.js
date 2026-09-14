// Offline fallback for the marketing site.
//
// Navigations are network-first: the old worker was cache-first for everything,
// which meant a deployed change stayed invisible until the cache name changed.
// Static assets stay cache-first because they are content-addressed by the
// build and cheap to re-fetch when they are not.
//
// reset-password.html is deliberately never cached. It is a one-shot flow that
// reads a token out of the URL, and a stale copy of it helps nobody.

const CACHE = 'ghostcopy-v2';

const PRECACHE = [
    '/',
    '/index.html',
    '/download.html',
    '/faq.html',
    '/privacy.html',
    '/terms.html',
    '/output.css',
    '/waitlist.js',
    '/icons/ghost.svg',
];

self.addEventListener('install', (event) => {
    event.waitUntil(
        caches.open(CACHE)
            .then((cache) => cache.addAll(PRECACHE))
            .catch(() => { /* a miss here must not block activation */ })
    );
    self.skipWaiting();
});

self.addEventListener('activate', (event) => {
    event.waitUntil(
        caches.keys()
            .then((names) => Promise.all(
                names.filter((n) => n !== CACHE).map((n) => caches.delete(n))
            ))
            .then(() => self.clients.claim())
    );
});

self.addEventListener('fetch', (event) => {
    const request = event.request;

    if (request.method !== 'GET') return;

    const url = new URL(request.url);

    // Same-origin only. Fonts and the Supabase API go straight to the network.
    if (url.origin !== self.location.origin) return;

    // Never involve the cache in the password reset flow.
    if (url.pathname.startsWith('/reset-password')) return;

    // Pages: network first, falling back to whatever we last saw.
    if (request.mode === 'navigate') {
        event.respondWith(
            fetch(request)
                .then((response) => {
                    const copy = response.clone();
                    caches.open(CACHE).then((cache) => cache.put(request, copy));
                    return response;
                })
                .catch(() => caches.match(request).then((hit) => hit || caches.match('/index.html')))
        );
        return;
    }

    // Everything else: cache first, populate on miss.
    event.respondWith(
        caches.match(request).then((hit) => {
            if (hit) return hit;
            return fetch(request).then((response) => {
                if (!response || response.status !== 200 || response.type !== 'basic') {
                    return response;
                }
                const copy = response.clone();
                caches.open(CACHE).then((cache) => cache.put(request, copy));
                return response;
            });
        })
    );
});
