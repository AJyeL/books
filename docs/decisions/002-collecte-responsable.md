# 002 — Collecte responsable

Date : 4 octobre 2026

> Analyse réalisée par un non-juriste, sans valeur d'avis juridique.

## Contexte

B.O.O.K.S. doit collecter automatiquement des pages publiques d'amazon.fr pour historiser le marché
des ebooks Kindle. Cette collecte pose des questions juridiques et éthiques : conditions d'utilisation
d'Amazon, accès à un système informatique tiers, données personnelles présentes sur les pages.
Avant d'écrire le collecteur, il faut fixer les règles qu'il respectera, et celles qu'il ne franchira jamais.

## Décision

### 1. Critère général

Réduire notre empreinte sur les serveurs d'Amazon est légitime ; contourner un refus est interdit.

Sont interdits :
- résoudre un CAPTCHA ;
- changer d'adresse IP ou passer par un proxy ;
- se connecter à un compte ;
- insister après un blocage.

Raison : passer outre un refus exprimé par le site exposerait au risque de maintien frauduleux
dans un système de traitement automatisé de données (article 323-1 du Code pénal).

### 2. Identité

Le collecteur s'annonce honnêtement avec le User-Agent `books-collector/0.1`, accompagné d'une adresse
de contact dédiée au projet (à créer). Si Amazon refuse ce visiteur, le refus est respecté :
le collecteur ne se fait jamais passer pour un navigateur.

### 3. robots.txt

Le fichier robots.txt d'amazon.fr a été vérifié le 4 octobre 2026, depuis atlas, avec `urllib.robotparser`
et l'agent `books-collector`. Aucune règle ne vise cet agent : ce sont celles de `User-agent: *` qui s'appliquent.
Les trois adresses testées sont autorisées :
- `https://www.amazon.fr/gp/bestsellers/digital-text/12363082031` (classement, page 1) ;
- `https://www.amazon.fr/gp/bestsellers/digital-text/12363082031?pg=2&tf=1` (classement gratuit, page 2) ;
- `https://www.amazon.fr/dp/B0F8VVKM5S` (fiche produit).

Limite : `urllib.robotparser` compare seulement le début des adresses et ne comprend pas les jokers
(`*` et `$`). Une règle à joker visant nos adresses serait ignorée, et l'outil répondrait « autorisé » à tort.
Les règles contenant un joker ou visant `bestsellers`, `digital-text` ou `/dp` ont donc été relues
manuellement le même jour. Conclusion : aucune ne vise `/gp/bestsellers/…`, `digital-text` ni `/dp/{ASIN}`.
Les règles `/dp/` ne visent que des sous-chemins (ex. : `/dp/rate-this-item/`), et les règles à joker
visent la recherche, les listes d'envies, l'aide et le service client.

robots.txt est relu automatiquement au début de chaque tournée ; toute adresse interdite est abandonnée.
Le collecteur doit utiliser un lecteur de robots.txt qui comprend les jokers.

### 4. Modération

- Une seule requête à la fois.
- Une pause d'environ 30 secondes entre deux requêtes.
- Un plafond dur de 200 requêtes par tournée.
- Collecte de nuit.
- Pages demandées compressées (en-tête `Accept-Encoding`), pour réduire le volume transféré.

### 5. Disjoncteur

Le disjoncteur se déclenche sur :
- un CAPTCHA ;
- une réponse HTTP 429 ou 503 ;
- une redirection inattendue ;
- une page de classement sans `zg.rank`.

Effet : arrêt immédiat de la tournée et alerte. Aucune nouvelle tentative la même nuit.

Reprise :
- la nuit suivante, une seule requête de test ;
- en cas d'échec, attente de 2, puis 4 nuits ;
- au 3e échec consécutif, arrêt définitif jusqu'au réarmement manuel ;
- l'en-tête `Retry-After` est respecté s'il impose un délai plus long.

### 6. Données personnelles (RGPD)

- Les noms d'auteurs sont des données personnelles. Ils sont traités sur la base de l'intérêt légitime,
  pour la seule analyse de marché.
- Les fiches produit contiennent des avis clients nominatifs. La version 0.1 du collecteur se limite donc
  aux pages de classement ; la collecte des fiches attendra une décision RGPD dédiée.
- La phase commerciale exigera un registre des traitements et une mention d'information publique.

## Conséquences

- **Risque assumé** : les conditions d'utilisation d'Amazon interdisent les robots. Le projet collecte
  malgré tout, à très faible volume et sans contournement. Le risque réaliste à ce volume est un blocage
  de l'adresse IP domestique d'atlas, qui serait alors respecté.
- **Politique restrictive d'Amazon** : robots.txt contient près d'une centaine de blocs nominatifs visant
  des robots d'IA et des outils de collecte (dont Scrapy et Crawl4AI). Vérifié le 4 octobre 2026 sur le bloc
  Scrapy (lignes 131 à 133) : `Disallow: /`, soit tout le site interdit. Ces blocs ne visent pas
  `books-collector`, mais signalent une politique restrictive d'Amazon envers la collecte automatisée.
  Si `books-collector`, ou une règle générale visant nos adresses, apparaît un jour dans robots.txt,
  le collecteur s'arrête.
- Le cadre Scrapy, nommément exclu, ne sera pas utilisé.
- Un blocage peut interrompre l'historique pendant plusieurs nuits, voire définitivement : les séries
  temporelles devront tolérer des trous, et les analyses les signaler.
- Avec 30 secondes entre deux requêtes, une tournée plafonnée à 200 requêtes dure au plus 1 h 40 environ.
- Sans les fiches produit, la version 0.1 ne dispose que des pages de classement : l'ASIN et le rang
  sont garantis pour tous les livres, mais les détails des cartes ne couvrent qu'une partie d'entre eux
  (environ 33 par page, voir `docs/exploration-amazon.md`). Description, éditeur et rang général
  Boutique Kindle ne seront pas collectés.
- Une adresse de contact dédiée doit être créée avant la première collecte.
- Toute évolution de ces règles (volume, nouvelles pages, nouvelles sources) passe par une nouvelle décision.
