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
- Une liste peut compter moins de 100 livres (ex. : 48 gratuits en Fantasy épique).
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
- Méthode retenue : page normale (pas `view-source:`), Ctrl+S, type « Page Web, HTML uniquement ».
  Contrôle : le fichier commence par `<!doctype html>` et ne contient ni `saved from` ni `line-content`.
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
- `<title>` contient le nom de la catégorie (`… dans la boutique Fantasy épique - ebooks`) ; `<h1>` est générique.
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
