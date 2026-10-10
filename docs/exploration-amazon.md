# Exploration des pages de classement Kindle (amazon.fr)

Observations manuelles du 3 octobre 2026, en navigation privée, sans connexion.

## Boutique
- Les ebooks Kindle sont dans la boutique `digital-text`.
- La boutique `books` correspond aux livres papier : arborescence et classements distincts.

## Adresses
- Format retenu : `https://www.amazon.fr/gp/bestsellers/digital-text/{categorie}?pg={1|2}`
- Top gratuit : ajouter `&tf=1`.
- Le paramètre `ref=` est un traceur de navigation, ignoré.
- Le numéro de catégorie (browse node) est l'identifiant externe stable ; le nom peut changer.

## Structure d'une page
- 50 livres par page au maximum, 2 pages au maximum.
- Le HTML initial contient les cartes détaillées d'une partie des livres seulement
  (30 le 5 octobre 2026, voir plus bas) ; les suivants sont chargés par le navigateur au défilement.
- L'attribut `data-client-recs-list` contient les ASIN de toute la page,
  chacun accompagné de son rang (clé exacte : `render.zg.rank`, voir plus bas).

## Règles de collecte et de parsing
- Chaque catégorie a deux classements : payant et gratuit.
- Une liste peut compter moins de 100 livres (ex. : 48 gratuits en Fantasy épique le 3 octobre, 45 le 5 octobre).
- La page 2 n'est demandée que si la page 1 contient 50 rangs.
- `data-client-recs-list` peut contenir une autre liste (ex. : nouveautés) :
  une liste n'est acceptée comme classement que si elle contient des `render.zg.rank`.
- Trois situations distinguées : liste normale, liste courte (information), page anormale (alerte, arrêt).

## Catégories identifiées
| Catégorie | Chemin | Identifiant |
|---|---|---|
| Fantasy épique | Ebooks Kindle › SF, fantasy et horreur › Fantasy › Épique | 12363082031 |
| Romance sportive | Ebooks Kindle › Romance et littérature sentimentale › Sport | 89265521031 |

## Fiche produit
- Une seule requête suffit : description et contenu A+ sont présents dans le HTML initial.
- Détails disponibles : ASIN, éditeur, date de publication, langue, taille du fichier,
  nombre de pages de l'édition imprimée, ISBN-13, série (« Livre X sur Y »), classements, avis.
- Le contenu A+ peut ne contenir que des images (texte non extractible sans analyse visuelle).
- Kindle Unlimited est indiqué dans le sélecteur de formats.

## Deux sources de classement
- Listes de catégorie : rang du livre dans CETTE catégorie (source de référence par catégorie).
- Fiche produit : rang général Boutique Kindle (seul rang comparable entre catégories)
  et uniquement les 3 meilleurs rangs de catégorie du livre.
- Exemple observé : 8e du top Fantasy épique, absent des classements de sa fiche,
  qui affichait 228e Boutique Kindle et trois catégories jeunesse.
- Les deux sources sont horodatées séparément et ne sont jamais corrigées l'une par l'autre.

## Étude hors ligne du HTML brut (5 octobre 2026)

Deux pages enregistrées à la main le 5 octobre 2026 (navigation privée, sans connexion) :
Top 100 payants, page 1, de Fantasy épique (`12363082031`) et de Romance sportive (`89265521031`).
Étude faite hors ligne, sans aucune requête vers Amazon. Les pages restent hors du dépôt ;
toutes les valeurs ci-dessous (ASIN, titres, auteurs, prix) sont **inventées**.

### Enregistrement des pages
- Méthode retenue : navigation privée, sans connexion ; page normale (pas `view-source:`), Ctrl+S,
  type « Page Web, HTML uniquement ». Dossier : `data/samples/` (hors du dépôt).
  Contrôle : le fichier commence par `<!doctype html>` et ne contient ni `saved from` ni `line-content`.
- Nom du fichier (convention du 5 octobre 2026, alignée sur le nommage RAW, type de liste toujours explicite) :
  `amazon_fr_bestsellers_{catégorie}_{paid|free}_p{n}_{AAAA-MM-JJ}.html`,
  par exemple `amazon_fr_bestsellers_10000000001_free_p1_2026-10-05.html` (catégorie inventée).
  La date est celle de l'enregistrement. Un nom hors convention est ignoré par la source locale.
- Pourquoi un type explicite : le canonical d'une page gratuite est identique à celui d'une page payante
  (voir « Top gratuit et page 2 » ci-dessous). Avec l'ancienne convention (`…_p1_{date}.html` et
  `…_p1_gratuit_{date}.html`), le motif `…_p1_*.html` désignait les deux pages, et la source locale servait
  la page **gratuite** pour une demande de Top payant (vérifié le 5 octobre 2026) : la validation l'aurait acceptée.
- Toutes les pages enregistrées le 5 octobre 2026 ont été renommées selon cette convention.
- À éviter : un Ctrl+S sur un onglet `view-source:` enregistre la *page d'affichage* du navigateur, pas le source.
  Chaque ligne du source y devient une ligne de tableau (`<td class="line-content">`), les `<` sont échappés
  en `&lt;` et colorés par des `<span class="html-…">`. Signes reconnaissables : commentaire
  `<!-- saved from url=(0014)about:internet -->`, classes `line-gutter-backdrop` et `line-wrap-control`.
- Une première étude a été faite sur une reconstitution de pages enveloppées, puis refaite sur deux pages
  réenregistrées en « HTML uniquement » le même jour : tous les constats ci-dessous ont été confirmés sur ces
  fichiers fidèles. Les deux versions sont deux réponses distinctes du serveur (environ 270 lignes diffèrent,
  par des jetons propres à chaque requête), mais la liste des 50 ASIN et leur ordre étaient identiques.

### Liste classée (`data-client-recs-list`)
- Un seul attribut `data-client-recs-list` par page ; sa valeur est un tableau JSON échappé en HTML (`&quot;`).
- 50 éléments, dans l'ordre des rangs 1 à 50, chacun au format suivant (valeurs inventées) :

  ```json
  {"id": "B0FAUX0001",
   "metadataMap": {"render.zg.rank": "1",
                   "render.zg.bsms.currentSalesRank": "",
                   "render.zg.bsms.twentyFourHourOldSalesRank": "",
                   "render.zg.bsms.percentageChange": "",
                   "disablePercolateLinkParams": "true"},
   "linkParameters": {}}
  ```

- La clé du rang est `render.zg.rank` (et non `zg.rank`, comme noté le 3 octobre).
- Les trois champs `render.zg.bsms.*` (rang actuel, rang d'il y a 24 h, variation) sont présents mais **vides**
  sur les 100 livres : on ne peut pas en tirer de rang de ventes.
- Les 50 `id` sont des ASIN valides et distincts.

### Cartes détaillées (`gridItemRoot`)
- 30 cartes dans le HTML brut sur chacune des deux pages (et non « environ 33 ») : ce sont les rangs 1 à 30,
  dans l'ordre. Les livres 31 à 50 n'apparaissent **que** dans `data-client-recs-list` (ASIN et rang seulement).
- Le nombre de cartes peut varier : le parser doit compter, pas supposer 30.
- Inventaire des informations par carte (présence sur 30 cartes, Fantasy épique / Romance sportive) :

| Information | Où | Forme (inventée) | Présence |
|---|---|---|---|
| ASIN | `div[data-asin]` dans la carte | `B0FAUX0001` | 30 / 30 |
| Rang affiché | `span.zg-bdg-text` | `#7` | 30 / 30 |
| Titre | `a[role=link] > span > div` (texte complet ; la troncature est seulement visuelle, en CSS) | `Le Royaume des cendres` | 30 / 30 |
| Titre (doublon) | attribut `alt` de l'image | identique au titre | 30 / 30 |
| Auteur | `a.a-link-child > div` ; un seul auteur affiché | `Camille Exemple` | 30 / 30 |
| Identifiant auteur | lien de l'auteur `/{nom}/e/{id}` | `/Camille-Exemple/e/B0AUTEUR01` | 30 / 30 |
| Note moyenne | `span.a-icon-alt` et classe `a-star-small-4-5` (arrondie à la demi-étoile) | `4,5 sur 5 étoiles` | 29 / 30 |
| Nombre d'évaluations | `aria-label` du lien des étoiles, et `span.a-size-small` visible | `4,5 sur 5 étoiles, 1 234 évaluations` | 29 / 30 |
| Format | `span.a-color-secondary` | `Format Kindle` | 30 / 30 |
| Prix | `span[class*=p13n-sc-price]` | `4,99 €` | 30 / 30 |
| Autres formats | `span.zg-book-title-format-text` | `3 formats disponibles` | 29 / 30 et 16 / 30 |
| Couverture | `img.p13n-product-image` (`src` et `data-a-dynamic-image`, plusieurs tailles) | URL `images-eu.ssl-images-amazon.com/images/I/…` | 30 / 30 |
| Lien fiche produit | `href` en `/{slug}/dp/{ASIN}/ref=…` | `/Le-Royaume-des-cendres/dp/B0FAUX0001/ref=…` | 30 / 30 |

- Un livre sans évaluation n'a ni note ni nombre d'évaluations : absence normale, pas une anomalie.
- Les milliers sont séparés par une espace insécable (U+00A0) : `1 234` ; la virgule est décimale (`4,99`).
- Le libellé est « évaluations » : selon Amazon, ce nombre inclut les notes sans commentaire écrit
  (non vérifié dans ces pages). Ne pas l'appeler « nombre d'avis écrits ».
- Absents des cartes : date de publication, éditeur, série, sous-titre distinct, Kindle Unlimited en texte.

#### Hypothèse non vérifiée : `ku-sticker`
- Constat : l'URL de la couverture contient `ku-sticker` pour 29 cartes sur 30 (Fantasy épique)
  et 30 sur 30 (Romance sportive) ; motif inventé : `…/images/I/{id}._UX300__OU08__PJku-sticker-v7,TopRight,0,-50_AC_UL900_SR900,600_.jpg`.
- Hypothèse : ce serait une vignette Kindle Unlimited incrustée dans l'image, donc un indice indirect
  d'appartenance à KU.
- Non vérifiée : aucun livre connu pour être hors KU n'a été examiné, et rien ne garantit qu'Amazon
  applique ce motif de façon systématique. Tant qu'elle n'est pas vérifiée, cette information n'est
  ni stockée comme « Kindle Unlimited », ni utilisée dans une analyse ; seule l'URL brute est conservée (couche RAW).
- Le paramètre `ref=` des liens contient un identifiant de session (`…/123-1234567-1234567`, valeur inventée) : à ignorer, jamais stocker comme donnée.

### Repères de page (contrôles de cohérence)
- `<link rel="canonical">` vaut exactement `https://www.amazon.fr/gp/bestsellers/digital-text/{categorie}` :
  il permet de vérifier que la page reçue correspond à la catégorie demandée.
- `<title>` contient le nom de la catégorie (`… dans la boutique Fantasy épique - ebooks`).
- Deux `<h1>` : le premier est générique (`Les meilleures ventes`), le second nomme la catégorie
  (`Les meilleures ventes en Fantasy épique - ebooks`). Correction du 5 octobre 2026 : la première version
  de cette étude n'avait relevé que le premier.
- Le collecteur (décision 004) ne s'appuie ni sur `<title>` ni sur les `<h1>`, qui peuvent changer.
  Il s'appuie sur le canonical, l'onglet actif, la pagination et les rangs (voir « Top gratuit et page 2 »).
- Onglet actif : `Top 100 payants` (`aria-current="page"`) ; lien vers `Top 100 gratuits` (`tf=1`)
  et vers la page 2 (`pg=2`).
- Aucune date de mise à jour : seulement « Mis à jour fréquemment ». L'horodatage reste celui de la collecte.
- Aucune mention de CAPTCHA dans ces deux pages normales.

### Comparaison des deux catégories
- Structure identique : mêmes classes, même liste JSON (mêmes clés), 30 cartes, rangs 1 à 30, mêmes repères.
- Seules les données varient (taux de présence de « formats disponibles », d'une note, etc.).
- Limite : 2 catégories, 1 seul jour, Top payant page 1 uniquement. Le Top gratuit (`tf=1`) et la page 2
  n'ont pas été étudiés hors ligne ; les classes à suffixe aléatoire (`_cDEzb_…_2hIsc`) peuvent changer
  à tout moment : le parser doit s'appuyer de préférence sur `data-client-recs-list` et sur les classes
  sans suffixe (`zg-bdg-text`, `a-icon-alt`, `a-link-child`, `p13n-product-image`) ; le prix n'a qu'une
  classe à suffixe (`_cDEzb_p13n-sc-price_…`), à repérer par la partie fixe `p13n-sc-price`.

## Top gratuit et page 2 (5 octobre 2026)

Deux pages de plus, enregistrées le 5 octobre 2026 pour Fantasy épique (`12363082031`) : Top 100 payants
page 2, et Top 100 gratuits page 1. Comparées à la page 1 payante du même jour. Étude hors ligne,
valeurs ci-dessous inventées ou génériques (textes d'interface).

### Ce qui ne distingue PAS les pages
- **Le canonical est identique** pour la page 1 payante, la page 2 payante et la page 1 gratuite :
  `https://www.amazon.fr/gp/bestsellers/digital-text/{categorie}`, sans `pg` ni `tf`.
  Le contrôle du canonical vérifie donc la catégorie, jamais le type de liste ni le numéro de page.
- `<title>`, les deux `<h1>`, l'élément `p13n-desktop-grid` (`data-reftag`, `data-index-offset="30"`)
  et les clés de `data-client-recs-list` sont identiques.

### Ce qui distingue Top payant et Top gratuit
| Indice | Top payant | Top gratuit |
|---|---|---|
| Onglet actif : `span[aria-current="page"]` dans `ul role="tablist"` | `Top 100 payants` | `Top 100 gratuits` |
| Onglet inactif : `a[aria-current="false"]` | lien `Top 100 gratuits` (`…/ref=zg_bs?ie=UTF8&tf=1`) | lien `Top 100 payants` (`…/ref=zg_bs`, sans `tf`) |
| `tf=1` dans la page | 1 fois (lien de l'onglet gratuit) | 14 fois : 13 liens de l'arborescence des catégories et le lien vers les nouveautés (`/gp/new-releases/…`) conservent `tf=1` |
| Prix des cartes | tous non nuls (de 0,99 € à 16,99 € sur les deux pages) | **tous à 0,00 €** (30 sur 30) |

- Chaque page contient **deux** `span[aria-current="page"]` : l'onglet actif, dans la rangée d'onglets
  (`ul role="tablist"`), et la catégorie courante dans l'arborescence des catégories
  (`span._p13n-zg-nav-tree-all_style_zg-selected__…`, texte du type `Épique (Current)`).
  Correction du 5 octobre 2026 : une première version indiquait un seul `span` ; le comptage cherchait
  le texte exact `<span aria-current="page"` et manquait celui dont les attributs sont dans un autre ordre.
  L'erreur a été révélée par la validation elle-même, qui refusait les 4 vraies pages (« 2 onglets actifs »).
- Aucun ASIN commun entre le Top payant (pages 1 et 2) et le Top gratuit de la même catégorie, le même jour.
- L'indice le plus direct est l'**onglet actif**. Les prix à 0,00 € sont un indice de cohérence, pas une preuve :
  un livre payant pourrait être temporairement gratuit.

### Page 2
- `data-client-recs-list` : 50 éléments, **rangs 51 à 100**, continus, mêmes clés que la page 1
  (champs `render.zg.bsms.*` vides).
- 30 cartes détaillées : rangs 51 à 80 (badges `#51` à `#80`), même structure que sur la page 1.
  Les rangs 81 à 100 ne figurent que dans `data-client-recs-list`.
- Aucun ASIN commun entre la page 1 et la page 2.
- Pagination : `li.a-selected` porte `aria-label="Page 2"` (et `aria-label="Page 1"` sur la page 1) ;
  le lien sélectionné porte `aria-current="page"`.

### Liste courte : Top gratuit de 45 livres
- `data-client-recs-list` : 45 éléments, rangs 1 à 45 ; `data-offset="45"` (50 sur les listes complètes) ;
  30 cartes détaillées.
- **Aucun bloc de pagination** (`nav aria-label="pagination"` absent) : une liste de 50 rangs ou moins
  n'a pas de page 2. Cohérent avec la règle « page 2 seulement si la page 1 contient 50 rangs ».

### Ce que la validation contrôle (proposition appliquée le 5 octobre 2026, décision 004)
La première validation (décision 004) ne vérifiait que la catégorie (canonical) et la présence de `render.zg.rank`.
Elle vérifie désormais aussi, avec la règle « la structure décide » (détail et règles exactes dans la décision 004) :
- le **type de liste** : texte du `span[aria-current="page"]` de la rangée d'onglets (`ul role="tablist"`),
  égal à `Top 100 payants` (paid) ou `Top 100 gratuits` (free) ;
- le **numéro de page** : `li.a-selected` avec `aria-label="Page {n}"` ; absence de pagination admise
  seulement pour la page 1 (liste courte) ;
- les **rangs** : premier rang égal à `(page - 1) × 50 + 1`, tous les rangs dans la plage de la page
  (1 à 50, 51 à 100) ; un trou dans la suite est seulement signalé.

Vérifié le 5 octobre 2026 : les 4 pages enregistrées sont conformes pour leur propre demande, et non conformes
pour une demande croisée (page gratuite demandée en payant et inversement, page 2 demandée en page 1
et inversement, Top gratuit court demandé en page 2, autre catégorie).

Limites : ces libellés sont des textes d'interface en français, qui peuvent changer ; un changement provoquerait
un arrêt `invalid` (visible, donc acceptable) plutôt qu'une erreur silencieuse. Observé sur une seule catégorie,
un seul jour.

## Romance sportive : Top gratuit et page 2 (6 octobre 2026)

Deux pages de plus, enregistrées le 6 octobre 2026 pour Romance sportive (`89265521031`) : Top 100 payants page 2,
et Top 100 gratuits page 1. Étude hors ligne, mêmes contrôles que pour Fantasy épique.
- Structure identique à celle de Fantasy épique : 30 cartes, mêmes repères, conformes à la validation
  (quatre indices) pour leur propre demande, non conformes pour les demandes croisées.
- Page 2 payante : rangs 51 à 100, aucun ASIN commun avec la page 1 du 5 octobre.
- **Top gratuit complet** : 50 rangs (1 à 50), avec un bloc de pagination annonçant une page 2
  (`li aria-label="Page 2"`, classe `a-normal`). Contrairement au Top gratuit court de Fantasy épique (45 rangs,
  sans pagination), il a donc une page 2 : les deux signaux (50 rangs et annonce) concordent.
- Aucun ASIN commun entre le Top payant (pages 1 et 2) et le Top gratuit.
- Limite : la page 1 payante date du 5 octobre, les deux autres du 6 ; l'absence d'ASIN commun entre pages
  de jours différents n'a donc pas la même portée qu'entre pages du même jour.

## Premières captures de l'extension (7 octobre 2026)

Une séance complète capturée le 7 octobre 2026 par l'extension (version 0.1.1, format de la décision 007) :
7 captures, Top payant et Top gratuit des deux catégories, pages 1 et 2 quand elles existent. Étude hors ligne,
fichiers ouverts en lecture seule ; ils restent hors du dépôt. Aucune valeur réelle ci-dessous.

### Intégrité (décision 007, section 6)
Contrôle indépendant de l'extension, fondé sur le seul contrat : **7 captures conformes, 0 anomalie**.
- Jumeaux `.html` et `.json` présents ; aucun fichier hors format ni orphelin.
- JSON : les 8 champs du schéma version 1, avec leurs types ; `capture_method` = `extension-dom`.
- `captured_at` identique à l'horodatage du nom ; catégorie, liste et page déduites de `displayed_url`
  (règles de la section 2 et de ses compléments) identiques au nom.
- `html_sha256` et `html_bytes` exacts ; HTML et JSON en UTF-8 sans BOM.
- Chaque HTML commence par `<!DOCTYPE html><html`, sans séparateur, comme le prévoit la section 3.
- Formes d'adresses affichées observées (valeurs retirées) : page 1 payante sans paramètre ;
  `…/ref=zg_bs?ie=UTF8&tf=1` (gratuit) ; `…/ref=zg_bs_pg_2_digital-text?ie=UTF8&pg=2` (page 2),
  avec `&tf=1` pour la page 2 gratuite.

### Capture DOM et HTML brut : comparaison de structure
Comparaison d'une capture (Top payant p1 de Fantasy épique, 7 octobre) avec l'échantillon brut de la même liste
(5 octobre). Jours différents : seule la structure est comparée, jamais les données.

| Mesure | HTML brut | Capture DOM |
|---|---|---|
| Taille | 494 Ko | 511 Ko |
| Balises | 2 055 | 2 373 |
| Scripts en ligne / externes | 90 / 1 | 89 / 12 |
| Octets dans les scripts | 241 Ko | 233 Ko |
| Cartes `gridItemRoot` | 30 | 30 |
| Attributs `data-client-recs-list` | 1 | 1 |

- **Taille** : les captures DOM (500 à 522 Ko) sont légèrement plus lourdes que le HTML brut (474 à 497 Ko pour
  les 6 échantillons enregistrés en « HTML uniquement »). Les fichiers d'environ 1,2 Mo étaient les pages enveloppées
  par `view-source:`, pas le source brut.
- **Ce qui apparaît** (ajouté par les scripts de la page après le chargement) : 11 scripts externes chargés
  dynamiquement, un `iframe`, 26 éléments `aria-modal` (fenêtres surgissantes préparées), des attributs de mesure
  d'audience (`data-csa-c-id`, `data-mix-*`), des `onclick` ; classes de détection sur `<html>`
  (`a-js`… au lieu de `a-no-js`) ; un `tbody` (inséré par le navigateur dans tout tableau) ; environ 230 `div` de plus.
- **Ce qui disparaît** : les attributs de contenu différé (`data-acp-path`, `data-acp-params`, `data-acp-stamp`),
  remplacés par le contenu chargé ; quelques sauts de ligne (sérialisation par le navigateur).
- **Ce qui ne change pas** : le texte des scripts en ligne est conservé ; une seule liste `data-client-recs-list` ;
  30 cartes détaillées. Les captures ont été faites sans défilement : aucune carte supplémentaire chargée.
  Une capture après défilement pourrait en contenir davantage (non observé).

### Les quatre indices de la décision 004 dans le DOM
Sur les 7 captures :
- **canonical** : un seul lien, égal à l'adresse canonique de la catégorie ;
- **onglet actif** : un seul `span aria-current="page"` dans la rangée d'onglets, du type du nom ;
- **pagination** : page active égale à la page du nom ; « Page 2 » annoncée sur les pages 1 des listes de 50 rangs ;
  aucun bloc de pagination pour le Top gratuit court ;
- **rangs** : une seule liste classée ; 50 rangs (1 à 50 en page 1, 51 à 100 en page 2), sauf le Top gratuit
  de Fantasy épique : **46 rangs** (45 le 5 octobre), sans pagination, donc sans page 2. D'où 7 captures et non 8.
- 30 cartes détaillées par capture ; aucune occurrence du mot « captcha ».

### Validation actuelle sur les captures
Validation du collecteur (décision 004, quatre indices), sans aucune modification, lancée sur chaque capture
avec la demande correspondant à son nom : **7 captures `ok`**, sans raison ni note ; « page 2 annoncée » vrai
pour les 3 pages 1 de 50 rangs, faux ailleurs. La réserve de la décision 005 (« validation à vérifier sur les captures
DOM ») est levée pour ces 7 captures.

Limites : une seule séance, un seul jour, une seule version de l'extension et de Chrome ; captures sans défilement.
À revérifier si l'extension, le navigateur ou la façon de consulter les pages changent.

## Inventaire des 7 captures et expérience du défilement (8 octobre 2026)

Étude hors ligne, fichiers ouverts en lecture seule, par un script jetable qui ne relève que des comptes et des formes
(chiffres remplacés par 9). Aucun titre, aucun ASIN ; l'auteur est seulement compté, son texte n'est jamais lu
(décision RGPD en attente). Notation : `⍽` = espace insécable.

### Inventaire des 7 captures de l'extension (séance du 7 octobre 2026)
Les 7 captures de `data/captures/` : Fantasy épique (FE) Top gratuit p1, Top payant p1 et p2 ;
Romance sportive (RS) Top gratuit p1 et p2, Top payant p1 et p2.

| Capture | Liste classée | Cartes détaillées | Rangs sans carte |
|---|---|---|---|
| FE gratuit p1 | 46 (rangs 1-46) | 30 (1-30) | 31-46 |
| FE payant p1 / RS gratuit p1 / RS payant p1 | 50 (1-50) | 30 (1-30) | 31-50 |
| FE payant p2 / RS gratuit p2 / RS payant p2 | 50 (51-100) | 30 (51-80) | 81-100 |
| **Total** | **346** | **210** | **136** |

- Aucune irrégularité : une seule liste classée par page, rangs continus, aucun ASIN vide ni en double ; les 210 cartes
  concordent avec la liste (même ASIN au même rang) ; aucun `data-asin` de la page hors de la liste classée.
- Sans défilement, **61 % des livres** (210 sur 346) ont des champs détaillés ; les autres n'ont que l'ASIN et le rang.
- Présence des champs sur les 210 cartes : rang, ASIN, titre, prix, URL de couverture, « Format Kindle » : 210 ;
  auteur affiché par un lien (`a.a-link-child`) : 205 ; note et nombre d'évaluations : 191 ;
  « N formats disponibles » : 142 ; « Kindle Unlimited » en texte : 0 ; `ku-sticker` dans l'URL : 148.
- **Note et nombre d'évaluations vont toujours ensemble** : 191 cartes ont les deux, 19 aucun des deux (dont 15 dans
  le Top gratuit), aucune l'un sans l'autre.
- **Cinq cartes sans lien auteur**, toutes dans un Top gratuit : le lien `a.a-link-child` est absent (et non vide),
  mais une ligne de texte de même style subsiste hors lien. Hypothèse, non vérifiée (texte non lu) : auteur affiché
  sans page auteur. Un parser qui ne lirait que `a.a-link-child` conclurait à tort à l'absence d'auteur.
- **Prix du Top gratuit : les 90 valent exactement `0,00⍽€`** ; le mot « Gratuit » n'apparaît dans aucune page.
  Les 120 prix du Top payant sont non nuls.
- Formes rencontrées :
  - rang : `#9`, `#99` ;
  - prix : `9,99⍽€`, `99,99⍽€` ;
  - note : `9,9 sur 9⍽étoiles` (toujours une décimale) ;
  - nombre d'évaluations, texte visible : `9`, `99`, `999`, `9⍽999`, `99⍽999`, `999⍽999` ;
  - `aria-label` du lien des étoiles : `9,9 sur 9⍽étoiles, 9⍽999⍽évaluations` ;
  - autres formats : `9⍽formats disponibles`.
- `ku-sticker` (indice KU non vérifié) : 36 sur 90 cartes du Top gratuit, 112 sur 120 du Top payant.
  Simple constat sur 7 pages d'un jour ; rien n'est établi sur Kindle Unlimited.

### Expérience du défilement
Une page FE Top payant p1, défilée à la main jusqu'en bas puis enregistrée par Ctrl+S, « Page Web complète »,
comparée à la capture de l'extension du 7 octobre (sans défilement). Jours différents : seule la structure est comparée.

| | Extension, sans défilement (7 oct.) | Ctrl+S après défilement (8 oct.) |
|---|---|---|
| Liste classée | 50 rangs (1-50) | 50 rangs (1-50) |
| Cartes détaillées | 30 (rangs 1-30) | **50 (rangs 1-50)**, continues, concordantes avec la liste |
| Rangs 31-50 : prix / note / évaluations | aucune carte | 20 / 19 / 19 (note et évaluations ensemble) |

- **Le défilement charge les cartes manquantes**, avec la même structure : mêmes sélecteurs, mêmes formes.
  La réserve du 7 octobre (« une capture après défilement pourrait en contenir davantage ») est levée sur cette page.
- **Repères du DOM** (identiques dans les trois pages examinées) :
  - la liste classée est portée par **un seul** `div.p13n-desktop-grid`, attribut `data-client-recs-list` ;
    ce même élément porte `data-index-offset="30"` (cartes du HTML initial) et `data-offset` (50, ou 46 pour le Top
    gratuit court). C'est une observation : la liste classée se repère par son attribut et ses rangs, comme dans
    `src/books/collector/validation.py`, jamais par cette classe (décision 010) ;
  - chaque carte détaillée est un `div` d'identifiant `gridItemRoot`, **répété sur chaque carte** (identifiant non
    unique, contraire à la norme HTML) : il se compte avec `[id="gridItemRoot"]` ; `getElementById` n'en renverrait
    qu'une. Toutes les cartes sont à l'intérieur du `div.p13n-desktop-grid` et portent un `data-asin` non vide.
- **Ctrl+S exclu comme méthode de capture** :
  - commentaire `<!-- saved from url=… -->` en tête, pas de JSON jumeau, nom hors format (décision 007) ;
  - les adresses `src` des 50 couvertures sont réécrites vers le dossier local `…_files` ; l'adresse d'origine
    ne subsiste que dans `data-a-dynamic-image` ;
  - la décision 005 laisse ouverte la question d'une nouvelle requête lors d'un Ctrl+S.
  Seule une capture de l'extension après chargement complet peut servir en production (décision 010).
- Limites : une page, une catégorie, Top payant p1 seulement ; ni page 2 ni Top gratuit défilés.

## Recette de la décision 010 : captures après chargement complet (8 octobre 2026)

Séance du 8 octobre 2026 vers 18 h 20 UTC, extension 0.2.0, chaque page défilée à la main jusqu'en bas :
7 captures (les mêmes listes que le 7 octobre). Étude hors ligne, en lecture seule, même méthode que l'inventaire
(comptes et formes seulement ; l'auteur n'est pas lu). La liste classée est repérée par la définition de
`src/books/collector/validation.py` (`_ranked_items`), les cartes par `[id="gridItemRoot"]` à l'intérieur de
l'élément qui la porte ; n = ASIN distincts de la liste qui ont une carte, m = rangs de la liste.

| Capture | 7 oct. (0.1.1) n/m | 8 oct. (0.2.0) n/m | Rangs des cartes (8 oct.) |
|---|---|---|---|
| FE gratuit p1 | 30/46 | **44/44** | 1-44 |
| FE payant p1 | 30/50 | **50/50** | 1-50 |
| FE payant p2 | 30/50 | **50/50** | 51-100 |
| RS gratuit p1 | 30/50 | **50/50** | 1-50 |
| RS gratuit p2 | 30/50 | **50/50** | 51-100 |
| RS payant p1 | 30/50 | **50/50** | 1-50 |
| RS payant p2 | 30/50 | **50/50** | 51-100 |
| **Total** | **210/346 (61 %)** | **344/344 (100 %)** | |

- Les 7 JSON portent `extension_version` 0.2.0 et `capture_method` `extension-dom` ; empreinte et taille du HTML exactes.
- Rangs des cartes continus ; les 344 cartes concordent avec la liste (même ASIN au même rang) ; aucun ASIN en double,
  aucune carte hors liste.
- **Rangs 31-50 et 81-100** (134 cartes, absentes le 7 octobre) : prix 134, couverture 134 (adresse d'origine
  d'Amazon), note 123, nombre d'évaluations 123 ; note et évaluations toujours ensemble. Prix du Top gratuit :
  tous à `0,00⍽€`, sur ces rangs comme sur les autres.
- Formes sur ces rangs, identiques à celles des rangs 1-30 : prix `9,99⍽€` (133), `99,99⍽€` (1) ;
  note `9,9 sur 9⍽étoiles` ; évaluations `9`, `99`, `999`, `9⍽999`, `99⍽999`, `999⍽999`.
- Top gratuit de Fantasy épique : 44 rangs (45 le 5 octobre, 46 le 7) : liste courte, sans pagination.
- **Quatre indices (décision 004)**, par la validation du collecteur : les 7 captures sont `ok` pour leur propre
  demande ; « page 2 annoncée » vrai pour les 3 pages 1 de 50 rangs qui ont une page 2 ; les 21 demandes croisées
  (autre liste, autre page, autre catégorie) sont `invalid`. Résultat identique sur les 7 captures du 7 octobre
  (30 cartes) : la validation ne dépend pas du nombre de cartes chargées.
- Limites : une séance, un jour, deux catégories, une version de l'extension et de Chrome.

## Espace insécable : écrite `&nbsp;` dans les captures (9 octobre 2026)

Comptage d'octets sur les 14 captures de `data/captures/`, en lecture seule, sans aucune valeur extraite :
- dans les captures de l'extension (DOM sérialisé par le navigateur), l'espace insécable est **toujours** écrite sous
  la forme de l'entité `&nbsp;`, jamais comme caractère U+00A0 ; aucune espace fine insécable (U+202F, `&#8239;`) ;
- emplacements : devant `€` dans les 554 prix (344 captures 0.2.0, 210 du 7 octobre), dans `sur 5&nbsp;étoiles`
  (icône et `aria-label`), entre les groupes de milliers, et devant `évaluations` ;
- dans l'`aria-label` des étoiles, la virgule est suivie d'une espace **ordinaire** :
  `4,5 sur 5&nbsp;étoiles, 1&nbsp;234&nbsp;évaluations` (valeurs inventées) ; libellé toujours au pluriel,
  y compris pour une seule évaluation (aucun « évaluation » au singulier observé) ;
- adresses des couvertures : toujours `https://`, sur trois hôtes d'Amazon
  (`images-eu.ssl-images-amazon.com`, `m.media-amazon.com`, `images-na.ssl-images-amazon.com`).
L'inventaire du 8 octobre notait `⍽` sans distinguer ces caractères : son outil décodait les entités.
Un analyseur HTML décode `&nbsp;` en U+00A0 : c'est ce caractère que l'extracteur attend (décision 011).

## Nom de la catégorie dans la page (10 octobre 2026)

Relevé de structure sur les 14 captures de `data/captures/`, en lecture seule ; aucun nom ni numéro réel ci-dessous
(décision 014), exemples inventés.
- **Deux `<h1>`** dans chaque page : le premier contient un `span id="zg_banner_text"` au texte générique
  (« Les meilleures ventes ») ; le second porte « Les meilleures ventes en {nom d'affichage} », précédé d'une espace.
  Le **suffixe « - ebooks »** du nom d'affichage n'est pas systématique : présent pour certaines catégories, absent pour
  d'autres. Le `<title>` reprend le même nom après « … dans la boutique ».
- **Arborescence des catégories** : la catégorie courante est un `span aria-current="page"` (classe à suffixe aléatoire
  `…zg-selected__…`), hors de la rangée d'onglets (`ul role="tablist"`). Son **texte direct** est le **nom court** ;
  il **contient** un second `span` caché (classe `…zg-visually-hidden__…`) au texte « (Current) », destiné aux lecteurs
  d'écran : le texte complet de l'élément vaut donc « {nom court}(Current) ».
- Les catégories parentes figurent dans l'arborescence, chacune avec son numéro et son nom, repérables aujourd'hui par
  un paramètre de navigation (`ref=zg_bs_unv_…`) ; les vraies captures n'ont pas d'attribut `role="treeitem"`.
- Lecture retenue par l'extracteur (version 2, décision 014) : le `<h1>` qui commence par le préfixe fixe, et le texte
  direct du `span aria-current="page"` hors de la rangée d'onglets ; jamais la classe à suffixe aléatoire.

## Fiches produit : inventaire de structure (10 octobre 2026)

Inventaire de la décision 015 (sections 1 et 2), reporté ici : **structure seulement**. Aucun titre, nom, ASIN ni numéro
de catégorie réel ; les exemples sont inventés ou sont des textes d'interface.

### Échantillon et méthode
- Quatre fiches Kindle et deux fiches papier (un broché et un relié **du même livre** qu'une des fiches Kindle),
  enregistrées à la main (Ctrl+S, « HTML uniquement »), jamais envoyées à atlas, conservées dans `data/fiches/`
  (hors du dépôt). Étude hors ligne, en lecture seule, par un script jetable.
- Fiches Kindle contrastées : deux autoéditées en Kindle Unlimited (une avec éditeur déclaré), une d'une maison
  d'édition hors KU (œuvre traduite), une gratuite parue cinq jours plus tôt, sans avis.
- Contre-épreuve : une phrase du bloc A+ lue à l'écran est présente dans le fichier (le bloc est dans le HTML initial).

### Repères d'une fiche Kindle (4 fiches)

| Donnée | Repère | Présence |
|---|---|---|
| Titre | `#productTitle` | 4/4 |
| Série, rang dans la série | `#rpi-attribute-book_details-series`, liste des détails | 3/4 ; deux formes : « Livre n sur N », « Fait partie de la série » |
| Contributeurs | `#bylineInfo .author`, rôle dans `.contribution` | 4/4, toujours « (Auteur) » seul, traduction comprise |
| Éditeur | liste des détails, « Éditeur » | 2/4 |
| ISBN-13 | liste des détails, `#rpi-attribute-book_details-isbn13` | 2/4 |
| Date de publication, langue, pages imprimées, taille du fichier | liste des détails | 4/4 |
| Formats et prix | `#tmmSwatches` (Kindle, broché, relié, audio) | 4/4 ; prix audio « avec votre abonnement » |
| Offre Kindle Unlimited | mention « Emprunt ou … pour acheter » dans l'onglet Kindle | 3/4 (absente sur la fiche hors KU) |
| Note | `#acrPopover` | 3/4 |
| Nombre d'avis | `#acrCustomerReviewText` | 3/4 ; fiche sans avis : compteur absent, répartition à 0 % |
| Répartition par étoiles | `#histogramTable` (pourcentages) | 4/4 |
| Rangs de vente | liste des détails, « Classement des meilleures ventes d'Amazon » | 4/4 : un rang général et trois rangs de catégorie |
| Fil de catégories | `#wayfinding-breadcrumbs_feature_div` | 4/4 |
| Couverture | `#landingImage` (`data-old-hires`) | 4/4 |
| Description | `#bookDescription_feature_div` | 4/4 (1 100 à 1 700 caractères) |
| Bloc A+ | `#aplus_feature_div` | 2/4 |

- **Deux sources pour les détails** : la liste « Détails sur le produit » (`#detailBullets_feature_div`) et le carrousel
  (`#rich_product_information`, identifiants `rpi-attribute-…`). La liste est plus complète (éditeur présent dans la
  liste mais absent du carrousel sur une fiche) ; le carrousel porte des identifiants techniques stables.
- **Rangs de vente** : chaque rang de catégorie est un lien `/gp/bestsellers/{boutique}/{numéro}` ; sur une fiche
  ebook, la boutique peut être `digital-text` **ou `books`** (livres papier). Le rang général d'une fiche gratuite est
  rédigé « n°N des titres gratuits » et ses liens portent `tf=1`.
- **Fil de catégories** : il commence par « Boutique Kindle » sur trois fiches, par « Livres » sur la quatrième
  (explication : voir « Fiches papier » ci-dessous).
- **Absence affichée n'est pas absence réelle** : une œuvre traduite n'affiche aucun traducteur. Un rôle non affiché
  est inconnu, jamais « aucun ».
- **Format de la fiche** : la ligne d'auteur se termine par « Format : Format Kindle » sur les quatre fiches. Les
  onglets de formats ne suffisent pas : celui de la fiche sans autre format a l'identifiant `tmm-grid-swatch-OTHER`,
  et non `…-KINDLE`.
- **Liens entre formats** : chaque onglet d'un **autre** format (`HARDCOVER`, `PAPERBACK`, `AUDIO_DOWNLOAD`) porte un
  lien `/dp/{ASIN}` vers sa propre fiche ; l'onglet du format affiché n'en porte pas. Les éditions d'un même livre se
  relient par leurs ASIN.

### Fiches papier (2 fiches, un seul livre : constats, pas règles)
- **Mêmes repères** que la fiche Kindle : `#productTitle`, `#bylineInfo`, `#tmmSwatches`, liste des détails,
  `#landingImage`, `#acrPopover`, `#histogramTable`, `#aplus_feature_div`.
- **Format** : « Format : Broché », « Format : Relié » en fin de ligne d'auteur.
- **ASIN** de la forme `B0…` pour les trois formats : la forme de l'ASIN ne dit pas le format.
- **Détails propres au papier** : ISBN-10, poids, dimensions ; pas de taille de fichier. Le nombre de pages diffère d'un
  format à l'autre (trois valeurs) ; dans le carrousel, son identifiant aussi (`book_details-fiona_pages` pour le papier,
  `book_details-ebook_pages` pour l'ebook).
- **Différent entre les trois formats** : le titre (nom de série dans le titre sur la seule fiche Kindle), le fichier
  image de la couverture (trois images distinctes ; un fichier différent ne prouve pas une couverture différente, aucune
  image n'a été téléchargée), le nombre de pages, les rangs de vente (boutique `books` pour le papier).
- **Identique** : description et bloc A+ (texte et liste d'images), note, **nombre d'avis**, fil de catégories.
- **Piège : les avis sont communs aux formats.** Le même nombre d'avis s'affiche sur les trois fiches ; additionner les
  avis de plusieurs formats d'un livre compterait les mêmes avis plusieurs fois.
- **Le fil de catégories de la fiche Kindle est celui du livre papier** pour ce livre (il commence par « Livres ») :
  c'est l'écart relevé sur les fiches Kindle.
- **Offres d'occasion** : à côté du prix neuf, une offre d'un vendeur tiers, avec son prix et ses frais de livraison.
  Ce n'est pas un prix du livre.

### Données personnelles présentes sur une fiche
- Nom et lien de l'auteur, biographie (décision 013).
- Éditeur : en général une personne morale ; une personne physique quand l'éditeur porte un nom de plume (cas observé).
- Noms des commentateurs, textes et images des avis (internautes, tiers).
- Offres d'occasion : vendeurs tiers, parfois des personnes physiques.
- Mention « Livraison à {code postal} {ville} » : localisation du porteur du projet, déduite de sa connexion. Elle
  figure **aussi sur les pages de classement** capturées. Ne jamais la recopier dans un document ou un test.
- Description et bloc A+ : peuvent citer le nom de l'auteur.
- Règles de traitement de chacune : décision 015, sections 2 et 6.

Limites : six fiches, un jour, enregistrées par Ctrl+S et non par l'extension ; la présence du bloc A+ et des avis dans
une capture DOM sans défilement reste à vérifier (décision 015, section 9).
