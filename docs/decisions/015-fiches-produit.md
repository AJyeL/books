# 015 — Fiches produit

Date : 10 octobre 2026

> Statut : **adoptée** le 10 octobre 2026, après relecture (amendements du même jour intégrés au texte). Rédigée à
> partir de l'inventaire du 10 octobre 2026 (section 1). Les exemples sont inventés : aucun titre, nom ni numéro de catégorie réel.

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
| Éditeur | en général une personne morale ; une personne physique quand l'éditeur porte un nom de plume (cas observé), souvent celui de l'auteur chez un autoédité | entité distincte de l'auteur, traitée par le **même mécanisme que la décision 013** : code dans STAGING, nom dans le schéma séparé ; **non extrait** avant la mise en œuvre de la décision 013 (section 6) |
| Noms des commentateurs, textes et images des avis | **internautes, tiers** | **jamais extraits** (section 6) |
| Offres d'occasion et vendeurs tiers | vendeurs, parfois des personnes physiques | jamais extraits |
| « Livraison à {code postal} {ville} » | **le porteur du projet** (localisation déduite de sa connexion) | jamais extraite ; absente du dépôt public |
| Description, bloc A+ | auteurs (citation possible du nom) | stockage seulement, ni affichage ni citation (décision 013, section 3) |

- La mention de livraison figure **aussi sur les pages de classement**. Vérifié le 10 octobre 2026 : **15/15 captures
  en local** (`data/captures/`), **60/60 pages RAW sur atlas** (comptes faits par le porteur du projet).
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
  décision 007, **amendée** en conséquence : expression régulière du nom d'une fiche
  (`amazon_fr_product_[A-Z0-9]{10}_[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z\.html`), et contrôle de lecture « ASIN déduit
  de `displayed_url` (section 3) égal à l'ASIN du nom », à la place de « catégorie, liste et page ».
- **Moment** : une capture unique, quand le document est chargé (`document.readyState` à `complete`) et que
  `#productTitle` et la liste des détails sont présents. Une page sans ces repères (vérification, erreur) est capturée
  telle quelle ; l'ingestion la classe.
- **Question ouverte, tranchée par la recette (section 9)** : un bloc A+ absent de la capture est-il absent
  de la fiche, ou seulement pas encore chargé ? (Le bloc des avis individuels n'est pas en cause : il n'est jamais lu.) Tant qu'elle n'est pas tranchée, l'absence d'A+ est enregistrée comme
  **inconnue** (`NULL`), jamais comme « pas d'A+ ».

### 5. Ingestion et validation

- `raw.raw_page` : `page_type = 'product'`, `asin` renseigné ; rien d'autre ne change dans RAW. **Aucune migration
  RAW.**
- **Emplacement dans RAW** (décision 004, `storage.py`) : celui des pages de classement repose sur la catégorie, la liste
  et la page ; une fiche a le sien, sur le même modèle :
  `amazon_fr/AAAA/MM/JJ/run-{id}/product_{ASIN}_{AAAA-MM-JJTHHMMSSZ}.html.gz` (et `.json.gz`).
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
- `staging.product_observation`, une ligne par fiche extraite : ASIN, format affiché, titre, nom de série, rang dans la série, nombre
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
- **Éditeur** : **entité distincte de l'auteur**, traitée par le **même mécanisme que la décision 013** : STAGING ne
  porte qu'un **code d'éditeur**, le nom affiché (lu dans la liste des détails, sans retouche) vit dans le schéma séparé.
  Raison : un éditeur peut être une personne physique, et chez un autoédité son nom est souvent celui de l'auteur ;
  stocké en clair dans STAGING, il y réintroduirait le nom que la décision 013 en retire. **Non extrait avant la mise en
  œuvre de la décision 013** ; RAW conserve tout, la réextraction le rendra disponible. Éditeur absent → code `NULL`.
  **Jamais « autoédition » par défaut** : une absence d'éditeur ne prouve pas l'autoédition, et un éditeur affiché ne prouve
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
- **Valeur présente mais illisible** (forme inconnue, par exemple un prix sans `€` ou une date d'une autre forme) :
  **échec de la page entière**, avec un motif qui nomme le champ, comme pour les pages de classement (décision 011,
  section 5). Absent n'est pas illisible : seule l'absence donne `NULL`.
- **`page_extraction.entry_count`** : vaut **1** pour une fiche extraite (une observation de fiche) ; la contrainte
  `page_extraction_result_ck` (page `ok` : `entry_count >= 1`) reste donc satisfaite. La migration 007 le précise
  (commentaire de colonne, test).

**Jamais lus par l'extracteur** : auteur, contributeurs et éditeur (jusqu'à la mise en œuvre de la décision 013), biographie, avis individuels, noms des commentateurs, mention de livraison, recommandations (« les clients ont aussi
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

1. Sur une fiche avec A+ : capture par l'extension **au chargement, sans défilement** ; puis recherche, dans ce seul
   fichier, d'une phrase du bloc A+ lue à l'écran. **Pas de Ctrl+S** (décision 005, section 5 : une nouvelle requête
   n'est pas exclue). Résultat consigné dans `docs/exploration-amazon.md` ; il tranche la question de la section 4
   pour le bloc A+.
2. Première séance : 3 à 5 fiches capturées, ingérées en développement, extraites ; bilan relevé par comptes seulement.

## Conséquences et ordre des travaux

- **Étape A** : module `product_page.py` et contrat `adresses_fiches.json`, tests.
- **Étape B** : ingestion et validation des fiches (`page_type = 'product'`), décision 008 annotée.
- **Étape C** (dépôt de l'extension) : liste blanche, nom des fichiers, moment de la capture ; recette (section 9, point 1).
- **Étape D** : migration 007 (tables de la section 6), extracteur version 3, recette (section 9, point 2).
- **Décisions annotées** :
  - 004 (emplacement RAW des fiches, section 5 ; `storage.py`) ;
  - 005 (section 4, fiches produit admises selon la présente décision) ;
  - 007 (nom `amazon_fr_product_{ASIN}_{horodatage}`, expression régulière, ASIN tiré de l'adresse affichée ;
    section 4) ;
  - 011 (périmètre étendu au type `product`) ;
  - 013 (l'éditeur, entité distincte de l'auteur, suit le même mécanisme : code dans STAGING, nom dans le schéma
    séparé ; question 6 sur la minimisation).
- **`CLAUDE.md`** (privé, jamais commité) : la règle « liste blanche limitée aux pages de classement » est mise à jour
  d'après la présente décision.
- **Documents** : l'inventaire de la section 1 est reporté dans `docs/exploration-amazon.md`, structure seulement.
- **Avis d'un juriste** : toujours requis avant toute exploitation commerciale (décision 005).

> Note du 10 octobre 2026 (étape A du code : adresse d'une fiche acceptée) :
> - **Relevé préalable**, en lecture seule, des adresses présentes dans les 6 fiches de `data/fiches/` (formes seulement,
>   ASIN, libellés et jetons masqués) : lien canonical `https://www.amazon.fr/{libellé}/dp/{ASIN}`, un par fiche, sans
>   paramètre ; liens internes `/{libellé}/dp/{ASIN}/ref=…`, parfois suivis d'un jeton de session et de paramètres,
>   `/{libellé}/dp/{ASIN}?ref_=…`, `/dp/{ASIN}?ref=…`, `/dp/{ASIN}?binding=…&ref=…` (autres formats). Des **ASIN
>   entièrement numériques** (forme d'un ISBN-10) figurent dans les liens : la règle `[A-Z0-9]{10}` les admet.
>   Un lien `/gp/product/…` existe dans 5 fiches, hors de l'adresse d'une fiche : la forme reste refusée.
> - Module commun `src/books/amazon/product_page.py` : `asin_from_url(adresse)` rend `(ASIN, None)` ou
>   `(None, motif)`, sur le modèle de `request_from_url` (décision 014). La forme du canonical d'une fiche n'y est pas
>   écrite : elle relève de la validation (étape B).
> - **Contrat commun** `tests/fixtures/adresses_fiches.json` : 10 adresses acceptées (dont 7 formes observées), 21
>   refusées (autres domaines, `http`, `/gp/product/`, ASIN invalide, `/dp/` répété, libellé de deux segments, pages
>   d'avis, d'auteur, d'offres d'occasion, de recherche, de classement). ASIN, libellés et jetons inventés.
> - `tests/python/test_product_page.py` parcourt toute la table et vérifie que les deux règles ne se chevauchent pas :
>   aucune fiche acceptée n'est une page de classement, aucune page de classement acceptée n'est une fiche.
> - Vérifié le 10 octobre 2026 : suite complète contre PostgreSQL 17 jetable, **373 réussis**. Contre-épreuves :
>   `/gp/product/` accepté → 2 échecs ; domaine accepté s'il finit par `amazon.fr` → 2 échecs ; ASIN en minuscules
>   accepté → 1 échec ; `/dp/` répété non contrôlé → 2 échecs. Extracteur inchangé : `EXTRACTOR_VERSION` reste « 2 ».
> - Prochaine étape côté extension : copier la table dans ses tests, avec en en-tête le commit d'origine de ce dépôt.

> Note du 10 octobre 2026 (étape B du code : ingestion et validation des fiches) :
> - **Relevé de structure préalable** (`docs/exploration-amazon.md`, « Repères de validation d'une fiche ») : seul
>   `div#detailBullets_feature_div` est doublé (deux `div` imbriquées) ; libellés « ASIN : » encadrés de marques de
>   direction invisibles ; « Format : » lu dans `#bylineInfo` seulement (le texte apparaît jusqu'à 17 fois dans la page).
> - **Validation** (`src/books/collector/product_validation.py`) : canonical unique dont l'ASIN est celui de l'adresse
>   affichée ; un seul `#productTitle` non vide ; une seule ligne « ASIN : » dans la liste des détails, de même ASIN ;
>   un seul « Format : » dans la ligne d'auteur, de valeur « Format Kindle », « Broché » ou « Relié ». La structure
>   décide, le mot « captcha » qualifie : `ok`, `blocked`, `invalid`.
> - **« Poche » refusé tant qu'il n'a pas été observé** (amende la section 4) : une fiche poche est `invalid`, donc
>   visible ; le libellé sera ajouté après observation.
> - **Motifs sans contenu de la page** : ils nomment l'indice et un compte, jamais un titre, une ligne d'auteur, un
>   format refusé ni l'adresse canonique.
> - **`Verdict.rank_count` facultatif** : `None` pour une fiche (aucune liste classée), jamais 0 ; `short_list` et
>   `next_page` n'en déduisent rien.
> - Nom, emplacement RAW et ligne `raw.raw_page` : décisions 007, 004 et 008 annotées. Script d'envoi du PC : nom de
>   fiche reconnu, rangement dans `envoyees\` inchangé.
> - **Tests** : fiche d'exemple inventée (piège de la recommandation, quatre sentinelles RGPD : auteur, commentatrice,
>   livraison, éditeur) et 21 variantes (`generer_fiches.py`) ; trois captures de fiche (`ok`, `invalid`, `blocked`) ;
>   dépôt réel d'une fiche sous le rôle `books_collector` dans PostgreSQL 17 jetable (fixture étendue à ce rôle) ;
>   aucune sentinelle dans les motifs, le bilan ni le journal.
> - Vérifié le 10 octobre 2026 : suite complète contre PostgreSQL 17 jetable, **449 réussis** ; test du script d'envoi
>   contre le faux atlas : tous conformes (16 fichiers, fiches comprises). **Contre-épreuves**, chacune en échec :
>   canonical non comparé (2) ; format cherché dans toute la page (26) ; livre audio accepté (2) ; poche accepté (2) ;
>   ASIN des détails non comparé (2) ; marques invisibles non retirées (22) ; mot « captcha » prioritaire sur la
>   structure (1) ; motif recopiant le format refusé (5) ; `rank_count` à 0 pour une fiche (2) ; `next_page` sans garde
>   `None` (1) ; ASIN du nom et de l'adresse non comparés (2) ; emplacement RAW d'une fiche sur le modèle des
>   classements (2) ; script d'envoi sans la forme `product` (10). Extracteur inchangé : `EXTRACTOR_VERSION` reste « 2 »
>   (les fiches sont comptées hors périmètre, motif « type product », comportement déjà testé).
> - **Limite, à lever avant qu'une fiche n'atteigne atlas** : la validation n'a été mise au point que sur des
>   enregistrements Ctrl+S et des pages inventées. Elle sera **rejouée en développement sur de vraies captures de
>   l'extension** (étape C) avant toute fiche envoyée sur atlas.
> - **Ordre de déploiement** : l'étape B est déployée sur atlas (reconstruction de l'image, sans migration) **avant toute
>   capture de fiche** ; sinon, une fiche envoyée serait mise en quarantaine (nom hors format) par l'ingestion actuelle.

> Note du 10 octobre 2026 (déploiement de l'étape B sur atlas, commit `2c0ac10`, rapporté par le porteur du projet) :
> - Sauvegarde de la base avant le déploiement ; `git pull` jusqu'à `2c0ac10` ; image reconstruite, sans migration ;
>   formats acceptés lus dans l'image : `('Format Kindle', 'Broché', 'Relié')`.
> - **Ingestion 16, à vide** : « Dont fiches produit: 0 », code 0. **Extraction** : 60 pages déjà à jour, code 0.
>   Quarantaine inchangée.
> - **Classements inchangés** : relevé de comptes (pages RAW par type et statut, extractions par statut, lignes de
>   classement avec et sans carte, observations de catégorie) identique avant et après le déploiement.
> - Aucune fiche n'a encore été capturée : la validation reste à rejouer sur de vraies captures de l'extension
>   (étape C) avant toute fiche envoyée sur atlas.

> Note du 10 octobre 2026 (étape C, recette de la section 9, point 1, rapportée par le porteur du projet) :
> - Extension **0.3.0** (dépôt de l'extension) : séance de 3 captures de fiches ; d'après le bilan de l'extension,
>   0 adresse `/dp/` non reconnue, 0 fiche sans repères (`#productTitle` et liste des détails).
> - Sur une fiche avec A+, capturée par l'extension **au chargement, sans défilement** : une phrase du bloc A+ lue à
>   l'écran est **présente** dans le fichier capturé (recherche dans ce seul fichier ; texte non cité).
> - **Question de la section 4 tranchée** : le bloc A+ est dans le DOM dès le chargement ; il n'attend pas le
>   défilement. Un bloc A+ absent d'une capture faite au chargement est donc **absent de la fiche** : l'extracteur
>   (étape D) enregistrera la présence d'A+ comme vrai ou faux, et non plus comme inconnue. Limite : une fiche, un jour,
>   une version de l'extension et de Chrome ; à réexaminer si une fiche avec A+ visible à l'écran donnait une capture
>   sans bloc A+.

> Note du 10 octobre 2026 (**amendement de la section 5, indice 3**, adopté par le porteur du projet) :
> - Constat (`docs/exploration-amazon.md`, premières captures de fiches par l'extension) : la fiche papier d'un livre
>   dont l'ISBN-10 sert d'ASIN n'a **pas de ligne « ASIN : »** dans la liste des détails, mais une ligne « ISBN-10 : »
>   égale à l'ASIN, tirets retirés. Les deux fiches papier capturées ont été refusées (`invalid`) par la règle de
>   l'étape B ; la fiche Kindle du même livre était `ok`.
> - **Règle amendée** : la liste des détails porte l'ASIN demandé par sa ligne « ASIN : » si elle existe ; sinon par sa
>   ligne « ISBN-10 : », tirets retirés. Exactement une ligne est lue ; aucune des deux, plusieurs lignes du type lu, ou
>   une valeur différente : `invalid`. Quand la ligne « ASIN : » existe, une ligne « ISBN-10 : » est ignorée, même de
>   valeur différente.
> - Code (`product_validation.py`) et tests : fiche papier d'exemple inventée, sans ligne ASIN (`fiche_papier_exemple.html`,
>   ASIN `2000000001`) et ses variantes (ISBN-10 terminé par X, avec tirets, différent, en double) ; fiche avec ligne
>   ASIN et ISBN-10 différent → `ok` ; capture de test d'une fiche papier à ASIN numérique, ingérée `ok`. Motif renommé :
>   « ni ligne ASIN ni ligne ISBN-10 dans la liste des détails ».
> - Vérifié le 10 octobre 2026 : suite complète contre PostgreSQL 17 jetable, **466 réussis** ; test du script d'envoi :
>   tous conformes (18 fichiers ; le cas « fiche hors format » ne dépend plus de l'ASIN de la première fiche).
>   **Contre-épreuves**, chacune en échec : ISBN-10 lu en priorité sur la ligne ASIN (1) ; tirets non retirés (1) ;
>   règle d'avant l'amendement, sans repli sur l'ISBN-10 (7).
> - Les deux fiches papier déjà déposées `invalid` dans RAW de développement le restent (RAW n'est jamais revalidé) ;
>   aucune fiche n'a été envoyée sur atlas.
