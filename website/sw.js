// Offline fallback for the marketing site.
//
// Navigations are network-first: the old worker was cache-first for everything,
// which meant a deployed change stayed invisible until the cache name changed.
// Static assets stay cache-first because they are content-addressed by the
// build and cheap to re-fetch when they are not.
//
// reset-password.html is deliberately never cached. It is a one-shot flow that
// reads a token out of the URL, and a stale copy of it helps nobody.

// Bumped to v3 to evict anything the v2 worker cached.
//
// A client still controlled by the previous worker can navigate to
// /auth-callback once before the new worker takes over, and that worker cached
// navigations under the full request URL - which for the callback contains the
// OAuth PKCE code. The bypass added below stops it happening again but cannot
// remove what is already stored, and activate() only deletes caches whose NAME
// differs from this constant, so leaving it at v2 kept the entry.
//
// Renaming discards every cached asset and forces one re-fetch. That is the
// right trade for evicting a credential with certainty, rather than purging
// selected keys and hoping the pattern matched every stored variant.
//
// v4 (2026-09-23): static assets are cache-first, so the icons this worker
// precached before the rebrand and the icon resize kept being served to
// returning visitors whatever the server had. The pages now link versioned
// icon URLs (?v=2); renaming the cache drops the stale copies outright.
const CACHE = 'ghostcopy-v4';

// Extensionless, matching what the pages actually link to. Precaching
// '/download.html' would have cached a 308 to '/download'.
const PRECACHE = [
    '/',
    '/download',
    '/faq',
    '/privacy',
    '/terms',
    '/output.css',
    '/waitlist.js',
    '/icons/ghost.svg?v=2',
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

    // Never involve the cache in a flow whose URL carries a credential.
    //
    // /auth-callback receives the OAuth PKCE code in its query string, and the
    // navigate handler below caches every navigation response keyed by its full
    // request URL. A no-store header does not help: the service worker calls
    // cache.put() itself, so the code would sit in Cache Storage under a key
    // containing it, outliving the page scrubbing its own history.
    if (
        url.pathname.startsWith('/reset-password') ||
        url.pathname.startsWith('/auth-callback')
    ) {
        return;
    }

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
