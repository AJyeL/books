# 015 — Fiches produit

Date : 10 octobre 2026

> Statut : **proposée**, à relire par le porteur du projet avant tout code. Rédigée à partir de l'inventaire du
> 10 octobre 2026 (section 1). Les exemples sont inventés : aucun titre, nom ni numéro de catégorie réel.

## Contexte

Les fiches produit (`/dp/{ASIN}`) sont exclues de la collecte depuis la décision 005 (section 4) : « elles contiennent
des avis clients nominatifs ; leur ajout attendra une décision RGPD dédiée, puis un élargissement explicite de la liste
blanche ». La décision 013 a traité les auteurs ; la présente décision traite le reste des données personnelles d'une
fiche et dit comment la fiche entre dans la chaîne capture → RAW → STAGING.

La couche RAW l'avait prévu dès la migration 001 : `raw.raw_page.page_type` accepte `product`, avec un ASIN et sans
catégorie, liste ni page.

## Décision

### 1. Inventaire (10 octobre 2026)

Quatre fiches Kindle enregistrées à la main (Ctrl+S, « HTML uniquement »), jamais envoyées à atlas, conservées dans
`data/fiches/` (ignoré par Git). Étude hors ligne, en lecture seule, par un script jetable. Échantillon contrasté :
deux autoéditées en Kindle Unlimited (une avec éditeur déclaré), une d'une maison d'édition hors KU (œuvre traduite),
une gratuite parue cinq jours plus tôt, sans avis. Contre-épreuve : une phrase du bloc A+ lue à l'écran est présente
dans le fichier.

| Donnée | Repère | Présence |
|---|---|---|
| Titre | `#productTitle` | 4/4 |
| Série, rang dans la série | `#rpi-attribute-book_details-series`, liste des détails | 3/4 ; deux formes : « Livre n sur N », « Fait partie de la série » |
| Contributeurs | `#bylineInfo .author`, rôle dans `.contribution` | 4/4, **toujours « (Auteur) » seul**, traduction comprise |
| Éditeur | liste des détails, « Éditeur » | 2/4 |
| ISBN-13 | liste des détails, `#rpi-attribute-book_details-isbn13` | 2/4 |
| Date de publication, langue, pages imprimées, taille du fichier | liste des détails | 4/4 |
| Formats et prix | `#tmmSwatches` (Kindle, broché, relié, audio) | 4/4 ; le prix audio est « avec votre abonnement » |
| Offre Kindle Unlimited | mention « Emprunt ou … pour acheter » dans l'onglet Kindle | 3/4 (absente sur la fiche hors KU) |
| Note | `#acrPopover` | 3/4 |
| Nombre d'avis | `#acrCustomerReviewText` | 3/4 ; fiche sans avis : compteur absent, répartition à 0 % |
| Répartition par étoiles | `#histogramTable` (pourcentages) | 4/4 |
| Rangs de vente | liste des détails, « Classement des meilleures ventes d'Amazon » | 4/4 : un rang général et trois rangs de catégorie |
| Fil de catégories | `#wayfinding-breadcrumbs_feature_div` | 4/4 |
| Couverture | `#landingImage` (`data-old-hires`) | 4/4 |
| Description | `#bookDescription_feature_div` | 4/4 (1 100 à 1 700 caractères) |
| Bloc A+ | `#aplus_feature_div` | 2/4 |

Constats :
- **Deux sources pour les détails** : la liste « Détails sur le produit » (`#detailBullets_feature_div`) et le carrousel
  (`#rich_product_information`, identifiants `rpi-attribute-…`). La liste est **plus complète** (éditeur présent dans la
  liste mais absent du carrousel sur une fiche) ; le carrousel porte des identifiants techniques stables.
- **Rangs de vente** : chaque rang de catégorie est un lien `/gp/bestsellers/{boutique}/{numéro}`. Sur une fiche
  ebook, la boutique peut être `digital-text` **ou `books`** (livres papier). Le rang général d'une fiche gratuite est
  rédigé « n°N des titres gratuits » et ses liens portent `tf=1`.
- **Fil de catégories** : il commence par « Boutique Kindle » sur trois fiches, par « Livres » sur la quatrième.
- **Absence affichée ≠ absence réelle** : une œuvre traduite n'affiche aucun traducteur. Un rôle non affiché est
  inconnu, jamais « aucun ».
- **Format de la fiche** : la ligne d'auteur se termine par « Format : Format Kindle » sur les quatre fiches. Les
  onglets de formats ne suffisent pas : celui de la fiche sans autre format a l'identifiant `tmm-grid-swatch-OTHER`,
  et non `…-KINDLE`.
- **Liens entre formats** : chaque onglet d'un **autre** format (`HARDCOVER`, `PAPERBACK`, `AUDIO_DOWNLOAD`) porte un
  lien `/dp/{ASIN}` vers sa propre fiche ; l'onglet du format affiché n'en porte pas. Les éditions d'un même livre se
  relient donc par leurs ASIN.

#### Fiches papier (10 octobre 2026)

Deux fiches papier, un broché et un relié **du même livre** qu'une des fiches Kindle, enregistrées et étudiées selon le
même protocole. Les trois formats d'un même livre se comparent ainsi un à un (un seul livre : constats, pas règles).

- **Mêmes repères** que la fiche Kindle : `#productTitle`, `#bylineInfo`, `#tmmSwatches`, liste des détails,
  `#landingImage`, `#acrPopover`, `#histogramTable`, `#aplus_feature_div`. Un seul analyseur de fiche est possible.
- **Format** : « Format : Broché », « Format : Relié » en fin de ligne d'auteur, comme sur la fiche Kindle.
- **ASIN** : de la forme `B0…` pour les trois formats ; la forme de l'ASIN ne dit pas le format.
- **Détails propres au papier** : ISBN-10, poids, dimensions ; pas de taille de fichier. Le nombre de pages diffère
  d'un format à l'autre (trois valeurs différentes) ; dans le carrousel, son identifiant diffère aussi
  (`book_details-fiona_pages` pour le papier, `book_details-ebook_pages` pour l'ebook).
- **Ce qui diffère entre les trois formats** : le **titre** (le nom de série n'est dans le titre que sur la fiche
  Kindle), le **fichier image** de la couverture (trois images distinctes ; un fichier différent ne prouve pas une
  couverture différente : aucune image n'a été téléchargée, aucun programme ne contacte Amazon), le nombre de pages,
  les rangs de vente (boutique `books` pour le papier).
- **Ce qui est identique** : description et bloc A+ (texte et liste d'images identiques à l'empreinte près), note,
  **nombre d'avis** et fil de catégories.
- **Piège : les avis sont communs aux formats.** Le même nombre d'avis s'affiche sur les trois fiches : ce n'est pas un
  indicateur propre à une édition. Additionner les avis de plusieurs formats d'un livre compterait les mêmes avis
  plusieurs fois.
- **Le fil de catégories de la fiche Kindle est celui du livre papier** pour ce livre (il commence par « Livres ») :
  cela explique l'écart relevé plus haut.
- **Offres d'occasion** : les fiches papier affichent, à côté du prix neuf, une offre d'occasion d'un vendeur tiers,
  avec son prix et ses frais de livraison. Ce n'est pas un prix du livre ; un vendeur tiers peut être une personne
  physique.

### 2. Données personnelles relevées sur une fiche

| Donnée | Personnes | Règle |
|---|---|---|
| Nom et lien de l'auteur, biographie | auteurs | décision 013 |
| Éditeur | en général une personne morale ; une personne physique quand l'éditeur porte un nom de plume (cas observé) | lu et stocké tel qu'affiché (section 6) ; aucune sortie nominative d'un éditeur avant la règle d'affichage de la mise en œuvre de la décision 013 |
| Noms des commentateurs, textes et images des avis | **internautes, tiers** | **jamais extraits** (section 6) |
| Offres d'occasion et vendeurs tiers | vendeurs, parfois des personnes physiques | jamais extraits |
| « Livraison à {code postal} {ville} » | **le porteur du projet** (localisation déduite de sa connexion) | jamais extraite ; absente du dépôt public |
| Description, bloc A+ | auteurs (citation possible du nom) | stockage seulement, ni affichage ni citation (décision 013, section 3) |

- La mention de livraison figure **aussi sur les 14 captures de classement** déjà ingérées, donc dans RAW sur atlas.
  Vérifié le 10 octobre 2026 : elle n'apparaît **nulle part** dans le dépôt public, historique compris.

### 3. Adresse acceptée

- **Règle** : `https://www.amazon.fr/{libellé facultatif}/dp/{ASIN}`, suivie ou non de `/ref=…` et de paramètres ;
  ASIN de 10 caractères `[A-Z0-9]`. Seule la forme `/dp/` est acceptée (seule observée) ; `/gp/product/` est refusée
  jusqu'à observation.
- **L'ASIN est déduit de l'adresse affichée uniquement**, comme la catégorie d'une page de classement (décision 007).
- Écrite **une seule fois**, dans un module commun `src/books/amazon/product_page.py`, sur le modèle de
  `ranking_page.py` (décision 014, section 4).
- **Contrat commun** : `tests/fixtures/adresses_fiches.json` (adresses acceptées avec l'ASIN attendu, refusées avec le
  motif ; ASIN inventés), parcouru par les tests de ce dépôt et **copié dans l'extension** avec le commit d'origine.
- Refusées : autres domaines et sous-domaines, `http`, ASIN de forme invalide, ASIN répété, toute autre page.

### 4. Capture

- **Formats acceptés** : ebook Kindle et livres papier (broché, relié, poche). Raison : une couverture, une
  description, un A+ ou un titre peuvent différer d'un format à l'autre, et une observation non capturée est perdue
  pour toujours ; RAW étant immuable et STAGING recalculable, une fiche papier capturée aujourd'hui sera analysable
  plus tard, par réextraction. **Livre audio refusé** (autre boutique, jamais inventoriée), comme tout autre format.
- L'adresse `/dp/{ASIN}` ne dit pas le format : c'est la **validation** qui le reconnaît (section 5).
- **Liste blanche de l'extension** élargie aux adresses de la section 3 (dans son dépôt, d'après la présente décision).
  Décision 005 inchangée : navigation manuelle, aucune requête par un programme, capture des seules pages affichées.
- **Nom** : `amazon_fr_product_{ASIN}_{AAAA-MM-JJTHHMMSSZ}` ; mêmes fichiers jumeaux et même JSON (schéma 1) que la
  décision 007.
- **Moment** : une capture unique, quand le document est chargé (`document.readyState` à `complete`) et que
  `#productTitle` et la liste des détails sont présents. Une page sans ces repères (vérification, erreur) est capturée
  telle quelle ; l'ingestion la classe.
- **Question ouverte, tranchée par la recette (section 9)** : un bloc A+ ou d'avis absent de la capture est-il absent
  de la fiche, ou seulement pas encore chargé ? Tant qu'elle n'est pas tranchée, l'absence d'A+ est enregistrée comme
  **inconnue** (`NULL`), jamais comme « pas d'A+ ».

### 5. Ingestion et validation

- `raw.raw_page` : `page_type = 'product'`, `asin` renseigné ; rien d'autre ne change dans RAW. **Aucune migration
  RAW.**
- Indices de validation, sur le modèle de la décision 004 : un seul canonical, dont l'ASIN est celui de l'adresse ;
  un seul `#productTitle` non vide ; la liste des détails porte le même ASIN ; le format affiché (« Format : … » de la
  ligne d'auteur, section 1) est un format accepté (section 4) ; tout autre format (livre audio compris) est
  `invalid`. Page de vérification : `blocked` (décision 005).
- Les repères d'une fiche papier ont été relevés sur 2 fiches réelles (section 1, « Fiches papier ») : ils sont les
  mêmes que ceux d'une fiche Kindle.
- Le plafond de 200 captures par ingestion (décision 008) couvre les deux types de pages.

### 6. Extraction (STAGING)

Périmètre : les fiches **Kindle** seulement. Les fiches papier sont conservées dans RAW et **comptées au bilan**
comme hors périmètre (motif « format papier ») jusqu'à leur propre inventaire et un amendement de la présente décision ;
la réextraction les rendra alors analysables, historique compris.

Lues :
- `staging.product_observation`, une ligne par fiche extraite : ASIN, format affiché, titre, éditeur (tel qu'affiché),
  nom de série, rang dans la série, nombre
  de livres de la série, date de publication, langue, pages imprimées, taille du fichier, ISBN-13, note, nombre d'avis,
  adresse de la couverture, description (texte), indice d'offre KU, présence d'A+, fil de catégories (texte).
- `staging.product_format`, une ligne par format affiché : libellé, ASIN de sa fiche (`NULL` pour le format de la
  page), prix (Decimal ; `NULL` = inconnu, `0,00` =
  gratuit) ; le prix « avec votre abonnement » est marqué comme tel, jamais confondu avec un prix d'achat.
- `staging.product_sales_rank`, une ligne par rang : rang, boutique (`digital-text`, `books`), numéro de catégorie
  (`NULL` pour le rang général), liste (payante ou gratuite) ; ainsi, une fiche se relie aux pages de classement par
  le numéro de catégorie.
- `staging.product_rating_share`, une ligne par niveau d'étoiles : pourcentage affiché.

Règles :
- **Éditeur** : la valeur affichée dans la liste des détails, sans retouche ; absente → `NULL`. **Jamais
  « autoédition » par défaut** : une absence d'éditeur ne prouve pas l'autoédition, et un éditeur affiché ne prouve
  pas une maison d'édition (une marque d'autoéditeur porte un nom d'éditeur, cas observé). Le statut éditorial (maison,
  autoédition, inconnu) est une **interprétation**, calculée dans une couche ultérieure, par une règle documentée qui
  dit son incertitude.
- **Avis communs aux formats** (section 1) : le nombre d'avis et la note sont enregistrés tels qu'affichés, sur
  chaque fiche ; une couche ultérieure ne les additionne jamais entre les formats d'un même livre.
- **Nombre d'avis** : compteur lu → sa valeur ; compteur absent et répartition entièrement à 0 % → `0` ; ni l'un ni
  l'autre → `NULL`.
- **Indice KU** : colonne `ku_offer_hint`, sur le modèle de `ku_sticker_hint` (décision 011, section 8) ; utilisée dans
  aucune analyse avant vérification et décision.
- **Source des détails** : la liste « Détails sur le produit », seule ; le carrousel n'est pas lu (une règle, un
  propriétaire). À réexaminer si la liste disparaît.
- Même clé composée vers `staging.page_extraction` que `ranking_entry` (jamais deux versions mélangées) ; nouvelle
  version de l'extracteur, réextraction de tout l'historique ; une valeur absente est `NULL` et comptée au bilan, sans
  échec de page ; seuls l'ASIN et le titre sont obligatoires.

**Jamais lus par l'extracteur** : auteur et contributeurs (jusqu'à la mise en œuvre de la décision 013), biographie, avis individuels, noms des commentateurs, mention de livraison, recommandations (« les clients ont aussi
acheté »), offres d'occasion et vendeurs tiers. Le test RGPD de l'extracteur est étendu : un auteur sentinelle, un commentateur sentinelle et une mention de
livraison sentinelle n'apparaissent dans **aucun** champ de STAGING, ni dans les motifs ni dans les bilans ; avec
contre-épreuve.

### 7. RAW reste intègre

- La capture n'est **pas** expurgée avant écriture : le HTML est la page telle qu'affichée (décision 007), et son
  empreinte en dépend. Les avis et noms de commentateurs sont donc conservés dans RAW, ses sauvegardes et `envoyees\`.
- **Question ajoutée pour les juristes** (décision 013, section 4) : la minimisation dès la collecte, recommandée par la
  CNIL, impose-t-elle d'expurger les avis à la capture, au prix d'une capture qui n'est plus « telle qu'affichée » ?
  À trancher avant toute exploitation commerciale, avec la question 4 (effacement dans RAW).

### 8. Fichiers de test

- Les pages d'exemple des tests sont **inventées**. Une page dérivée d'une vraie capture n'est jamais commitée sans
  avoir été nettoyée de tout titre, nom, numéro de catégorie, avis et mention de livraison.

### 9. Recette, avant toute fiche en production

1. Sur une fiche avec A+ : capture par l'extension **sans défilement**, puis Ctrl+S après défilement complet ; comparer
   la présence du bloc A+ et du bloc d'avis. Résultat consigné dans `docs/exploration-amazon.md` ; il tranche la
   question de la section 4.
2. Première séance : 3 à 5 fiches capturées, ingérées en développement, extraites ; bilan relevé par comptes seulement.

## Conséquences et ordre des travaux

- **Étape A** : module `product_page.py` et contrat `adresses_fiches.json`, tests.
- **Étape B** : ingestion et validation des fiches (`page_type = 'product'`), décision 008 annotée.
- **Étape C** (dépôt de l'extension) : liste blanche, nom des fichiers, moment de la capture ; recette (section 9, point 1).
- **Étape D** : migration 007 (tables de la section 6), extracteur version 3, recette (section 9, point 2).
- **Décisions annotées** : 005 (section 4, fiches produit admises selon la présente décision), 011 (périmètre étendu au
  type `product`), 013 (règle d'affichage des éditeurs à prévoir avec sa mise en œuvre ; question 6 sur la minimisation).
- **`CLAUDE.md`** (privé, jamais commité) : la règle « liste blanche limitée aux pages de classement » est mise à jour
  d'après la présente décision.
- **Documents** : l'inventaire de la section 1 est reporté dans `docs/exploration-amazon.md`, structure seulement.
- **Avis d'un juriste** : toujours requis avant toute exploitation commerciale (décision 005).
