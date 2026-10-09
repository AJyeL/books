# 011 — Extracteur et couche STAGING

Date : 8 octobre 2026 · Migration prévue : `sql/migrations/005_couche_staging.sql`

## Contexte

La couche RAW (décision 001) conserve les pages de classement telles qu'elles ont été capturées, et rien d'autre :
aucun champ (titre, prix, note…) n'est encore lu dans une table. Depuis la décision 010, une capture contient
la carte détaillée de chaque livre de la liste (344 cartes sur 344 rangs lors de la recette du 8 octobre 2026) ;
les captures plus anciennes n'en ont que 30 par page.

L'inventaire du 8 octobre 2026 (`docs/exploration-amazon.md`) a établi les repères et les formes des champs sur
14 captures réelles. L'étape suivante est un **extracteur** : il lit les pages de RAW et range leur contenu dans
une couche **STAGING**, table par table, sans rien interpréter au-delà de ce qui est affiché.

## Décision

### 1. Périmètre

- Sont extraites les lignes de `raw.raw_page` de type `bestseller_list`, de statut `ok` **et** de méthode de capture
  `extension-dom` : la seule méthode de production (décision 005), qui donne des pages homogènes, capturées dans
  le DOM et telles qu'affichées. Les enregistrements manuels ne servent qu'au développement, et une page enregistrée
  à la main peut différer d'une capture (la variante « Page Web complète » réécrit par exemple les adresses des
  couvertures, `exploration-amazon.md`).
- Les autres lignes ne sont pas extraites ; elles sont **comptées** dans le bilan comme hors périmètre, par motif :
  méthode `manual-html`, méthode non enregistrée (lignes antérieures à la migration 004), statut autre que `ok`
  (`blocked`, `invalid`, erreurs), type `product`.
- Chaque page RAW reste une observation distincte : deux captures de la même liste le même jour donnent deux
  ensembles de lignes. Le choix d'une observation relève des couches suivantes (décision 001).

### 2. Intégrité d'abord

Avant toute lecture, pour chaque page :

- le fichier `storage_path` (relatif à `BOOKS_RAW_DIR`) est lu puis **décompressé** : RAW stocke le HTML compressé
  en gzip (`storage.py`), alors que `content_sha256` et `content_bytes` portent sur le **contenu d'origine**,
  non compressé ;
- l'empreinte SHA-256 et la taille du contenu décompressé sont comparées à `content_sha256` et `content_bytes`.
- Fichier absent, illisible ou non décompressible, empreinte ou taille différente : **anomalie d'intégrité**,
  page non extraite, motif enregistré (section 6). RAW n'est jamais modifié (décision 001).
- Le JSON de la capture (`metadata_path`) n'est pas lu : tout ce dont l'extracteur a besoin (catégorie, liste,
  page, horodatage) est déjà dans `raw.raw_page`.

### 3. Table `staging.ranking_entry`

Une ligne par livre classé d'une page : **une ligne par (page RAW, rang)**, y compris pour les rangs sans carte
détaillée.

| Colonne | Type | Contenu |
|---|---|---|
| `raw_page_id` | bigint, clé étrangère vers `raw.raw_page` | Page d'origine |
| `extract_run_id` | bigint, clé étrangère vers `staging.extract_run` | Exécution qui a produit la ligne |
| `rank` | smallint | Rang, lu dans la liste classée |
| `asin` | text | ASIN, lu dans la liste classée |
| `has_card` | boolean | Le livre a une carte détaillée dans la page |
| `title` | text | Titre affiché, espaces de début et de fin retirés |
| `price_amount` | numeric(8,2) | Prix affiché (`0,00 €` dans un Top gratuit) |
| `currency` | text | Code ISO 4217 (`EUR` pour `€`) |
| `rating` | numeric(2,1) | Note moyenne, sur 5 |
| `review_count` | integer | Nombre d'évaluations affiché |
| `cover_url` | text | Adresse de la couverture (`src` de l'image), telle quelle |
| `ku_sticker_hint` | boolean | Indice **non vérifié** : `ku-sticker` présent dans `cover_url` (section 8) |

- Le **contexte** (catégorie, type de liste, numéro de page, horodatage de la capture, méthode) n'est pas recopié :
  il s'obtient par jointure avec `raw.raw_page`.
- **Liste classée** : la définition commune de `src/books/collector/validation.py` (décision 010) : exactement une
  liste, éléments dont le `metadataMap` est un objet portant `render.zg.rank`, rang entier. L'extracteur réutilise
  ces fonctions plutôt que d'en écrire une seconde version.
- **Cartes** : `[id="gridItemRoot"]` à l'intérieur de l'élément qui porte la liste ; une carte est rattachée à son
  livre par l'ASIN de son `[data-asin]`, et le rang de son badge (`span.zg-bdg-text`) doit être celui de la liste.
- Sources des champs (inventaire du 8 octobre) : titre `a[role=link] > span > div` ; prix `span[class*=p13n-sc-price]` ;
  note `span.a-icon-alt` ; nombre d'évaluations, texte visible `span.a-size-small` du lien dont l'`aria-label` contient
  « étoiles » ; couverture `img.p13n-product-image` (`src`).
- **Absent n'est pas inconnu, ni l'inverse** : un livre sans carte a tous ses champs de détail à `NULL`
  (`has_card = false`, valeurs inconnues) ; un livre avec carte mais sans note ni évaluations a `has_card = true`,
  `rating` et `review_count` à `NULL` (livre sans évaluation affichée). Les deux cas ne se confondent pas.

### 4. Contraintes

- `PRIMARY KEY (raw_page_id, rank)` et `UNIQUE (raw_page_id, asin)`.
- `CHECK` :
  - sans carte, tous les champs de détail sont `NULL` (`has_card OR (title, price_amount, currency, rating,
    review_count, cover_url, ku_sticker_hint tous NULL)`) ;
  - note et nombre d'évaluations ensemble : tous deux `NULL` ou tous deux renseignés ;
  - prix et devise ensemble ; `price_amount >= 0` ; `currency ~ '^[A-Z]{3}$'` ;
  - `rating BETWEEN 0 AND 5` ; `review_count >= 0` ;
  - `rank BETWEEN 1 AND 100` ; `asin ~ '^[A-Z0-9]{10}$'` (même règle que `raw.raw_page`).
- Les contraintes sont un dernier garde-fou : l'extracteur vérifie tout avant d'écrire, et une page qui les
  enfreindrait est en échec avec un motif (section 5), jamais un plantage.

### 5. Atomicité par page

- Une page est extraite **entièrement ou pas du tout**, dans une transaction.
- **Champ absent** : `NULL`, selon la section 3. **Champ présent mais illisible** (forme inconnue, par exemple un prix
  sans `€` ou une note « sur 10 ») : la **page entière est en échec**, avec un motif qui nomme le champ et le rang ;
  aucune de ses lignes n'est écrite. Les autres pages continuent.
- Sont aussi des échecs de page : carte dont l'ASIN est absent de la liste, carte en double, badge de rang différent
  du rang de la liste ; et, par sécurité, rang ou ASIN en double dans la liste, normalement déjà refusés par la
  validation (section 5 bis).
- **Trou dans les rangs** (rang manquant dans la liste) : toléré. Le rang absent n'a simplement pas de ligne ;
  la validation le signale déjà comme une information.
- Formes acceptées, et seulement elles (inventaire du 8 octobre ; `⍽` = espace insécable U+00A0) :
  - prix : `9,99⍽€`, chiffres groupés par trois avec `⍽` au-delà de 999 ; décimale à la virgule, deux chiffres ;
  - note : `9,9 sur 5⍽étoiles` (une décimale, dénominateur 5) ;
  - nombre d'évaluations : `9`, `99`, `999`, `9⍽999`, `99⍽999`, `999⍽999` (groupes de trois séparés par `⍽`) ;
    il doit être égal au nombre de l'`aria-label` du même lien (`…, 1⍽234⍽évaluations`).
  Toute autre forme est un échec visible : le parser est complété **après** examen de la nouvelle forme,
  jamais par une acceptation silencieuse.

### 5 bis. Validation durcie : doublons dans la liste classée

- Le jugement de conformité d'une page appartient à la **validation** (`src/books/collector/validation.py`,
  décision 004), appliquée à l'ingestion (décision 008, section 3), et non à l'extracteur.
- Jusqu'ici, un rang en double n'était qu'une **information** (« suite de rangs non continue (trou ou doublon) »),
  et les ASIN en double n'étaient pas contrôlés : une page `ok` pouvait donc contenir des doublons.
- Désormais, **un rang en double ou un ASIN en double dans la liste classée rend la page `invalid`**. Comme toute
  page `invalid`, elle est déposée dans RAW avec son statut, l'ingestion continue, et l'anomalie figure au bilan
  (décision 008, sections 3 et 4). Elle n'entre donc pas dans le périmètre de l'extracteur.
- Un **trou** dans la suite des rangs reste une simple information.
- Les contraintes d'unicité de STAGING (section 4) et les contrôles de l'extracteur (section 5) restent en place,
  comme filet de sécurité.
- Les pages déjà dans RAW ne sont pas revalidées (RAW n'est jamais modifié). Les 14 captures réelles inventoriées
  le 8 octobre 2026 ne contiennent aucun doublon.

### 6. STAGING recalculable

- STAGING n'est **pas** en ajout seul : c'est un calcul à partir de RAW, qu'on peut refaire.
- **Réextraction** d'une page = remplacement de ses lignes dans une transaction (suppression de ses lignes, puis
  insertion des nouvelles). Si la réextraction échoue, les anciennes lignes de la page sont supprimées aussi et
  la page est marquée en échec : STAGING ne mélange jamais deux versions de l'extracteur pour une même page.
- **`staging.extract_run`** : une ligne par exécution (`id`, `started_at`, `finished_at`, `extractor_version`,
  `status` parmi `running`, `success`, `partial`, `failed`, compteurs, `notes` avec le bilan), sur le modèle de
  `raw.collect_run`, sans la valeur `aborted`.
- **`staging.page_extraction`** : une ligne par page RAW examinée (`raw_page_id` clé primaire, `extract_run_id`,
  `extractor_version`, `status` parmi `ok`, `parse_failed`, `integrity_failed`, `error_message`, `entry_count`).
  Elle rend visibles les pages en échec, qui n'ont aucune ligne dans `ranking_entry`, et indique ce qui reste à faire.
- **Pages traitées** par une exécution : celles du périmètre sans ligne dans `page_extraction`, ou extraites par
  une autre version de l'extracteur ; une option force la réextraction de tout le périmètre.
- **Règle du projet : toute modification des règles d'analyse de l'extracteur incrémente `EXTRACTOR_VERSION` dans
  le même commit.** C'est ce numéro, enregistré dans `extract_run` et `page_extraction`, qui déclenche la
  réextraction des pages : une règle changée sans nouvelle version laisserait dans STAGING des lignes produites
  par l'ancienne règle, sans que rien ne le signale.
- Une seule extraction à la fois : verrou consultatif de PostgreSQL (`pg_try_advisory_lock`), libéré à la fin de
  la session ; verrou occupé : message, code 1, aucune exécution enregistrée.

### 7. Rôle `books_transformer`

- Nouveau rôle de connexion, sur le modèle de `books_collector` (migration 002), créé par la migration 005 :
  - `USAGE` sur le schéma `raw` et `SELECT` sur `raw.collect_run` et `raw.raw_page` ; **rien d'autre sur `raw`** ;
  - `USAGE` sur le schéma `staging` ; `SELECT, INSERT, DELETE` sur `ranking_entry` ; `SELECT, INSERT, UPDATE` sur
    `page_extraction` ; `SELECT, INSERT` et `UPDATE` limité aux colonnes de clôture sur `extract_run` ;
  - aucun droit de création ; aucun droit pour `books_collector` sur `staging`.
- Les tables de `staging` appartiennent au propriétaire de la base, qui applique la migration.
- Mot de passe défini à la main (`\password`), reporté dans `.env` (`BOOKS_TRANSFORMER_PASSWORD`), comme pour le
  collecteur. Les fichiers RAW sont montés **en lecture seule** dans le conteneur de l'extracteur.

### 8. Indice `ku-sticker`

- La colonne s'appelle `ku_sticker_hint`, et non `kindle_unlimited` : c'est la présence d'un motif dans l'adresse de
  la couverture, hypothèse **non vérifiée** (`exploration-amazon.md`). Un commentaire SQL sur la colonne le rappelle.
- Elle n'est utilisée dans **aucune analyse** tant que l'hypothèse n'est pas vérifiée et consignée par une décision.

### 9. Aucun auteur

- Ni le nom affiché de l'auteur, ni son lien, ni son identifiant (`/e/{id}`) ne sont extraits : décision RGPD en attente
  (décision 002, section 6). Le parser ne lit pas ces éléments.

### 10. Analyse et exécution

- **Analyse** : une **fonction pure** qui reçoit le contenu HTML et rend soit les lignes de la page, soit un échec
  avec son motif ; elle n'accède ni à la base, ni aux fichiers. Elle est testée sur des **pages inventées**
  (`tests/fixtures/`), dont une variante par forme acceptée et par cas d'échec, et une page de 50 cartes.
- **Commande séparée** sur atlas, lancée à la main, distincte de l'ingestion :
  `docker compose --profile transformer run --rm transformer` (même image que le collecteur, autre point d'entrée,
  autre rôle). Pas de tâche programmée pour l'instant.
- **Codes de sortie** : 0 aucune anomalie (ou rien à extraire) ; 1 au moins une page en échec ou une anomalie
  d'intégrité, verrou occupé, ou erreur d'exécution ; 2 configuration invalide.
- **Bilan**, affiché et enregistré dans `extract_run.notes` : pages du périmètre, extraites, déjà à jour, en échec
  (avec motif), anomalies d'intégrité ; pages hors périmètre par type et statut ; lignes écrites, dont avec et sans carte.

## Conséquences

- **Première étape du code** : le durcissement de la validation (section 5 bis), avec un test par `ingest()` et sa
  contre-épreuve, avant toute écriture de l'extracteur.
- **Migration 005** : schéma `staging`, trois tables, rôle `books_transformer`, droits ; tests SQL des droits et
  des contraintes, sur le modèle de `test_002_role_collecteur.sql`.
- **Restauration** : `pg_dump` ne sauvegarde pas les rôles (README, « Restauration d'une sauvegarde ») : la procédure
  devra créer `books_transformer`, comme `books_collector`, **avant** `pg_restore`.
- **Captures antérieures à la décision 010** : 30 cartes par page ; leurs rangs 31-50 et 81-100 auront
  `has_card = false`. Les analyses devront le préciser (période, échantillon).
- Le service `transformer` s'ajoute à `docker-compose.yml`, avec les garde-fous de montage de `BOOKS_RAW_DIR`
  (décision 003), en lecture seule.
- CORE (livres, auteurs, catégories) et les analyses restent à décider : STAGING ne déduplique rien et n'agrège rien.

> Note du 8 octobre 2026 (étape 1 du code : liste classée commune et validation durcie) :
> - **Module commun** `src/books/amazon/ranked_list.py` : `RANK_KEY`, `ranked_items` et `rank_value`, déplacées de
>   `validation.py` sous des noms publics, sans changement de comportement (suite de tests inchangée : 207 réussis).
>   La validation l'importe ; l'extracteur l'importera, plutôt que des fonctions privées de la validation.
> - **Validation durcie** (section 5 bis) : un rang ou un ASIN en double rend la page `invalid`, motifs
>   « N rang(s) en double (ex. : …) » et « N ASIN en double dans la liste classée (ex. : …) ». Seuls les ASIN
>   en texte sont comparés. La note d'un trou devient « suite de rangs non continue (trou) ».
> - Vérifié le 8 octobre 2026 : deux fausses pages (`bestsellers_rang_double.html`, `bestsellers_asin_double.html`) ;
>   tests de la validation, et par `ingest()` (capture déposée `invalid` avec son motif, anomalie au bilan,
>   autre capture du lot traitée ; un trou reste une information sans anomalie) ; suite complète : 211 réussis.
>   Contre-épreuve : sans les nouvelles règles, les 4 tests de doublons échouent. Les 14 captures réelles
>   de `data/captures/` restent `ok`.

> Note du 9 octobre 2026 (étape 2 du code : migration 005) :
> - `sql/migrations/005_couche_staging.sql` : schéma `staging`, tables `extract_run`, `page_extraction` et
>   `ranking_entry` avec les contraintes de la section 4, toutes nommées ; commentaires sur `ku_sticker_hint` et
>   `has_card` ; rôle `books_transformer` et ses droits (section 7). `page_extraction` a de plus une contrainte de
>   cohérence : page `ok` avec au moins une ligne et sans motif, page en échec avec un motif et aucune ligne.
>   Son `UPDATE` exclut `raw_page_id` (remplacement par `INSERT … ON CONFLICT DO UPDATE`).
> - `tests/sql/test_005_couche_staging.sql`, lancé par le propriétaire, qui endosse tour à tour les deux rôles
>   (`SET LOCAL ROLE`) : 59 vérifications. Chaque refus doit venir de la contrainte nommée ou du droit attendu.
> - Vérifié le 9 octobre 2026 dans un PostgreSQL 17 jetable (migrations 001 à 005), puis en développement.
>   Contre-épreuves dans la base jetable : sans `ranking_entry_no_card_ck`, échec au test 10 ; avec un droit de
>   lecture sur `staging` accordé à `books_collector`, échec au test 60. Tests 002 et 004 toujours conformes.
>   Rien n'est appliqué sur atlas à cette étape.

> Note du 9 octobre 2026 (correction de la migration 005, **exception unique**) :
> - La migration 005 a été **modifiée sur place** après son application en développement. C'est une exception :
>   elle n'avait jamais été appliquée sur atlas, et `staging` était vide en développement. Une migration appliquée
>   en production n'est jamais modifiée ; toute évolution passe par une nouvelle migration. En développement,
>   `staging` et le rôle `books_transformer` ont été supprimés (`DROP SCHEMA staging CASCADE`,
>   `DROP OWNED BY` et `DROP ROLE books_transformer`, ligne 5 de `schema_migration`), puis la migration réappliquée.
> - **« Jamais deux versions mélangées » garanti par la base** (section 6) : `page_extraction` reçoit
>   `UNIQUE (raw_page_id, extract_run_id)`, et `ranking_entry` une **clé étrangère composée**
>   `(raw_page_id, extract_run_id)` vers `page_extraction`, à la place de ses deux clés étrangères simples
>   (la page RAW et l'exécution restent garanties par celles de `page_extraction`). Une ligne n'existe donc que pour
>   l'exécution enregistrée pour sa page. **Ordre de réextraction**, dans une transaction : suppression des lignes de
>   la page, mise à jour de `page_extraction` (nouvelle exécution), insertion des nouvelles lignes ; la base refuse
>   la mise à jour tant que des lignes de l'ancienne exécution existent. Ceci remplace l'`INSERT … ON CONFLICT DO
>   UPDATE` mentionné dans la note précédente.
> - **`page_extraction.extractor_version` supprimée** : redondante avec `extract_run.extractor_version`, obtenue par
>   jointure. Elle est retirée du droit `UPDATE` de `books_transformer`. Les pages « extraites par une autre version »
>   (section 6) se repèrent par cette jointure.
> - Vérifié le 9 octobre 2026, dans un PostgreSQL 17 jetable puis en développement : test 005 (63 vérifications),
>   dont une ligne d'une autre exécution refusée, une ligne sans `page_extraction` refusée, la mise à jour de
>   `page_extraction` refusée avant la suppression des lignes, la réextraction complète acceptée ; colonne absente.
>   Contre-épreuve sans la clé composée : échec au test 3. Tests 002 et 004 conformes.

> Note du 9 octobre 2026 (étape 3 du code : analyse pure) :
> - `src/books/transformer/parsing.py` : `parse_ranking_page(contenu)` rend une ligne par livre classé ou lève
>   `ParseError` avec un motif (champ et rang). Elle n'accède ni à la base ni aux fichiers, utilise l'analyseur HTML
>   de la bibliothèque standard (aucune dépendance ajoutée) et la liste classée commune (`books.amazon.ranked_list`).
>   **`EXTRACTOR_VERSION = "1"`**.
> - **Titre** (remplace « espaces de début et de fin retirés », section 3) : le nettoyage se limite au **décodage des
>   entités HTML** et à la **réduction des espaces** (toute suite d'espaces, insécables comprises, devient une espace ;
>   aucune en début ni en fin). Rien d'autre : ni changement de casse, ni retrait de ponctuation, ni troncature.
>   Un titre vide après nettoyage fait échouer la page.
> - **Prix** en `Decimal`, jamais en nombre à virgule flottante, cohérent avec `numeric(8,2)` ; au-delà de 999 999,99 :
>   échec. **Devise** par liste d'autorisation : `€` → `EUR`, et rien d'autre. Note aussi en `Decimal`.
> - **Formes** : l'espace insécable attendue est U+00A0, écrite `&nbsp;` dans les captures (`exploration-amazon.md`,
>   9 octobre 2026) ; espace ordinaire ou espace fine à sa place : échec. Libellé « évaluations » au pluriel seulement.
> - Contrôles complémentaires : badge de rang obligatoire sur chaque carte ; adresse de couverture en `https://`
>   seulement (une adresse réécrite par un enregistrement manuel est refusée) ; un seul élément par champ.
>   L'auteur n'est jamais lu : le titre est `a[role=link] > span > div`, et le lien de l'auteur n'a pas `role="link"`.
> - Vérifié le 9 octobre 2026 : `tests/python/test_parsing.py` (53 tests) sur trois fausses pages générées
>   (`generer_pages_extraction.py`), conformes à la validation ; suite complète : 264 réussis. **Contre-épreuves** :
>   une version qui lit l'auteur fait échouer le test RGPD (auteur inventé absent de tout champ et de tout motif) ;
>   un prix accepté avec tout espace, ou le dollar ajouté aux devises, fait échouer les tests de liste d'autorisation ;
>   un champ de détail donné à un livre sans carte fait échouer les tests `has_card`.
>   Sur les 14 captures réelles, en lecture seule : aucune page en échec ; 344 cartes sur 344 rangs (dont 314 notées)
>   pour les captures 0.2.0, 210 cartes (dont 191 notées) pour celles du 7 octobre, comme l'inventaire.

> Note du 9 octobre 2026 (étape 4 du code : intégrité, base et orchestration) :
> - **Préalable** : `tests/fixtures/bestsellers_exemple.html` (écrite à la main) reprend les formes observées
>   (`&nbsp;` devant `€` et `étoiles`, note avec décimale) ; variantes, pages d'extraction et captures de test régénérées.
>   Toute fausse page conforme à la validation passe désormais l'extracteur (testé).
> - `integrity.py` : décompression gzip, puis taille et empreinte comparées à `content_bytes` et `content_sha256` ;
>   emplacement absolu ou remontant (`..`) refusé ; fichier absent, illisible ou non décompressible : échec d'intégrité.
> - `repository.py` (droits de `books_transformer`) : verrou consultatif (`pg_try_advisory_lock`) ; pages à extraire
>   = jamais extraites, extraites par une autre version, **ou en échec** : une page en échec est reprise à chaque
>   exécution, et son anomalie reste visible (code 1) tant qu'elle n'est pas résolue ; pages hors périmètre comptées
>   par motif. Écriture d'une page dans une transaction, dans l'ordre suppression des lignes, mise à jour de
>   `page_extraction` (`INSERT … ON CONFLICT DO UPDATE`), insertion des lignes ; page en échec : lignes supprimées,
>   statut et motif enregistrés.
> - `extraction.py` : une page en échec (intégrité ou analyse) n'arrête pas les suivantes ; seule une erreur
>   d'exécution arrête l'extraction (`failed`) ; si la clôture échoue à son tour (connexion perdue), l'erreur
>   d'origine est conservée et la clôture signalée. Statuts et codes comme l'ingestion : `success` 0, `partial` 1,
>   `failed` 1 ; verrou occupé : aucune exécution enregistrée, code 1.
> - **Tests contre un PostgreSQL 17 jetable**, sous le rôle `books_transformer` (`tests/lancer-tests-postgres.sh` :
>   une base neuve par test, copiée d'une base modèle migrée). Couverts : périmètre et hors périmètre ; page à jour ;
>   changement de version ; réextraction forcée ; réextraction dans l'ordre imposé par la base ; réextraction en échec
>   (lignes supprimées, page en échec) ; écriture atomique d'une page ; anomalies d'intégrité (octet modifié, taille
>   différente, fichier absent, fichier non compressé) ; page en échec suivie d'une page extraite ; verrou occupé
>   (deux connexions réelles). Faux dépôt pour la seule connexion perdue.
> - Vérifié le 9 octobre 2026 : suite complète **291 réussis**, aucun test sauté. Contre-épreuves : sans comparaison
>   d'empreinte, le cas « octet modifié, même taille » échoue ; page_extraction mise à jour avant la suppression des
>   lignes : 3 échecs, refus par la base (clé composée) ; anciennes lignes conservées lors d'un échec : 2 échecs,
>   refus par la base.
