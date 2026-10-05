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
