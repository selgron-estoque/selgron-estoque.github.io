// v4 — correção de segurança: as versões anteriores deste service worker
// cacheavam QUALQUER requisição GET bem-sucedida, sem checar origem — isso
// incluía as chamadas REST do supabase-js (`.from('contagens').select()` e
// afins, que carregam token de autenticação no cabeçalho e devolvem dado
// protegido no corpo: contagens, inventários, usuários, saldo...) e os
// scripts de CDN de terceiros (jsdelivr). Um cache de Service Worker é
// compartilhado pelo APARELHO inteiro, não por usuário logado — cachear
// resposta autenticada aqui achava um jeito de vazar dado de um operador
// pro próximo que logar no MESMO tablet, mesmo offline (bastava o
// `caches.match()` do fallback devolver a última resposta cacheada de
// outra pessoa). Bump de `CACHE_NAME` (v3 -> v4) já limpa esse cache antigo
// sozinho, no `activate` de qualquer aparelho que atualizar — nenhuma ação
// manual necessária, e nenhum dado real é perdido (é só o cache do
// navegador, não o banco).
const CACHE_NAME = 'stock360-v4';
const CORE_ASSETS = ['./', './index.html', './manifest.json'];

// Teto simples pro cache não crescer sem limite (defesa a mais, mesmo o
// escopo já sendo naturalmente pequeno — só assets estáticos do PWA, sem
// query string variável, ver `deveCachear` abaixo). `Cache.keys()` devolve
// as chaves na ordem em que foram inseridas na maioria dos navegadores —
// suficiente pra um FIFO aproximado, não uma garantia forte, mas nunca
// deixa o cache crescer indefinidamente.
const MAX_CACHE_ENTRIES = 60;

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(CORE_ASSETS))
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

async function limitarTamanhoCache(cache) {
  const keys = await cache.keys();
  const excedente = keys.length - MAX_CACHE_ENTRIES;
  if (excedente > 0) {
    for (let i = 0; i < excedente; i++) {
      await cache.delete(keys[i]);
    }
  }
}

// Só cacheia requisição GET, MESMA ORIGEM (nunca supabase.co, nunca CDN de
// terceiro — "de origens externas" explicitamente fora do cache) — o app
// inteiro é servido por essa mesma origem (GitHub Pages) e não tem nenhuma
// API própria same-origin, então isso na prática só cobre
// index.html/manifest.json/ícones/imagens/preview-etiqueta.html/o próprio
// service-worker.js — exatamente "os assets estáticos necessários ao PWA",
// nunca dado autenticado/de API.
function deveCachear(request, url) {
  if (request.method !== 'GET') return false;
  if (url.origin !== self.location.origin) return false;
  return true;
}

// Network-first, sempre — o app está em desenvolvimento ativo (mudanças
// frequentes) e a versão antiga em cache já causou confusão real mais de
// uma vez. Só cai pro cache se a rede falhar de verdade (offline no
// almoxarifado), não como atalho de velocidade. Requisição de origem
// externa (Supabase, CDN) nunca passa por `event.respondWith` — o
// navegador trata normalmente, sem nenhuma interceptação/cache deste SW.
self.addEventListener('fetch', (event) => {
  const { request } = event;
  const url = new URL(request.url);
  if (!deveCachear(request, url)) return;

  event.respondWith(
    fetch(request)
      .then((response) => {
        // Só guarda resposta REAL de sucesso (2xx, same-origin — nunca uma
        // resposta de erro, nem uma resposta opaca de origem cruzada, que
        // sequer chegaria aqui depois do filtro `deveCachear` acima).
        if (response && response.ok) {
          const copy = response.clone();
          caches.open(CACHE_NAME).then((cache) => {
            cache.put(request, copy);
            limitarTamanhoCache(cache);
          });
        }
        return response;
      })
      .catch(() => caches.match(request))
  );
});
