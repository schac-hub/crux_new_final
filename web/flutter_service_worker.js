/* Service worker de NEUTRALISATION.
 *
 * L'ancien service worker Flutter (stratégie PWA) servait l'ANCIENNE version
 * de l'app depuis son cache, même après un déploiement — d'où les « pages
 * blanches » et les bugs déjà corrigés qui persistaient pour les visiteurs.
 *
 * Ce fichier, déployé au MÊME chemin, remplace l'ancien SW : il se
 * désenregistre lui-même, purge tous les caches et recharge la page une
 * dernière fois. Ensuite plus aucun SW : chaque visite télécharge la version
 * à jour (GitHub Pages revalide les fichiers à chaque requête).
 */
self.addEventListener('install', (event) => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    self.registration
      .unregister()
      .then(() => caches.keys())
      .then((keys) =>
        Promise.all(keys.map((key) => caches.delete(key))),
      )
      .then(() =>
        self.clients.matchAll({ type: 'window' }).then((clients) => {
          clients.forEach((client) => {
            if (client.url && 'navigate' in client) {
              client.navigate(client.url);
            }
          });
        }),
      ),
  );
});
