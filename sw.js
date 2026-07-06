/* EvenOut service worker — offline app shell.
   Shell files: cache-first with background refresh (stale-while-revalidate).
   Data (Supabase RPCs) is POST — never intercepted, always live. */

const CACHE = "evenout-v3.2";
const SHELL = [
  "./",
  "index.html",
  "styles.css",
  "app.js",
  "config.js",
  "manifest.webmanifest",
  "stats.html",
  "icon-192.png",
  "icon-512.png",
  "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js",
];

self.addEventListener("install", (ev) => {
  ev.waitUntil(
    caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (ev) => {
  ev.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (ev) => {
  if (ev.request.method !== "GET") return; // RPCs stay live
  ev.respondWith(
    caches.match(ev.request, { ignoreSearch: false }).then((cached) => {
      const refresh = fetch(ev.request)
        .then((resp) => {
          if (resp && (resp.ok || resp.type === "opaque")) {
            const copy = resp.clone();
            caches.open(CACHE).then((c) => c.put(ev.request, copy));
          }
          return resp;
        })
        .catch(() => cached); // offline: fall back to cache
      return cached || refresh;
    })
  );
});
