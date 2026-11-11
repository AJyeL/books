# 021 — Couche CORE, lot 2 : fiches produit

Date : 11 novembre 2026 · **Acceptée** · Migration : `sql/migrations/015_core_fiches.sql`

> Statut : **acceptée** le 11 novembre 2026 par le porteur du projet, plan approuvé (tables de versions typées, deux
> sources jamais mêlées, vue `core.book_current`), avec cinq réponses intégrées au texte : balisage de la description
> versionné à part, par empreinte et longueur (section 3) ; ISBN-13 et fil de catégories hors du lot 2 ; adresse de
> couverture non normalisée, avec un relevé de la distribution des versions après déploiement
> (`sql/observations/versions_couverture.sql`) ; boutique sur chaque rang (section 6) ; indices d'abonnement des Tops
> repris, exclus des analyses jusqu'à décision.

## Contexte

Le lot 1 (décision 020) a construit CORE pour les classements : livres, catégories, listes du jour, rangs. Les fiches
produit Kindle sont dans STAGING depuis la décision 015 (migration 007) : une observation par fiche extraite
(`staging.product_observation`), ses onglets de formats (`product_format`), ses rangs de vente (`product_sales_rank`) et
sa répartition des étoiles (`product_rating_share`). Comme pour les classements, STAGING ne choisit rien : deux captures
de la même fiche donnent deux observations.

Règles tranchées par le porteur du projet (11 novembre 2026) :
1. deux natures de données : des **attributs** (titre, couverture, description, série et position, nombre de pages, A+,
   date de publication, langue, taille de fichier), versionnés attribut par attribut avec premier et dernier jour
   observés ; des **mesures** (prix et qualificatif du format sélectionné, emprunt abonnement, note, nombre d'avis,
   répartition des étoiles, rang général, rangs par catégorie), en état du jour au grain (livre, jour), dernière
   observation du jour avec son compte ;
2. un `NULL` n'est pas un changement ; un retour à une ancienne valeur ouvre une nouvelle version ;
3. la description n'entre dans CORE que par son empreinte et sa longueur, jamais par son texte (minimisation,
   décision 013) ;
4. identité : l'ASIN Kindle ; les liens vers les autres formats restent dans STAGING ;
5. `core.book` réunit les ASIN des Tops et des fiches, avec premiers et derniers jours par source ;
6. une catégorie vue seulement dans les rangs d'une fiche est identifiée par (source, nœud), comme au lot 1 ;
7. règles du lot 1 inchangées : jour de Paris, lignage, aucune interpolation, version courante de l'extracteur
   seulement, fiches papier exclues ;
8. migration 15, `CORE_VERSION` 2 ; `core.rebuild()` reconstruit les deux lots dans la même transaction.

## Décision

### 1. Fiches éligibles

Une fiche entre dans CORE si, comme au lot 1 :
- `raw.raw_page.page_type = 'product'` et `fetch_status = 'ok'` ;
- son extraction est `ok` dans `staging.page_extraction`, par la version de l'extracteur passée à `core.rebuild()`.

Sont donc exclues d'office :
- les **fiches papier**, mises à part (`skipped`) par l'extracteur, qui n'ont aucune ligne dans STAGING ;
- les fiches **en échec** (`parse_failed`, `integrity_failed`, section 7) ;
- les fiches extraites par une **autre version** de l'extracteur (comptées, comme au lot 1).

Une fonction `core.eligible_product_page(version)` définit cette règle une seule fois, sur le modèle de
`core.eligible_page`. Elle rend l'identifiant de la page, la source, l'ASIN, l'horodatage et le jour de Paris.

### 2. Identité

- Le livre est l'**ASIN de la fiche Kindle** (`raw.raw_page.asin`). Seules les fiches Kindle sont extraites
  (décision 015) : il n'y a donc jamais deux formats d'un même livre dans les tables du lot 2.
- Les liens vers les autres formats (`product_format.linked_asin`) restent dans STAGING, hors de CORE.
- Les avis étant communs aux formats d'un livre (`exploration-amazon.md`), ne lire que la fiche Kindle évite de les
  compter plusieurs fois.

### 3. Attributs : une table de versions par attribut

**Une table par attribut**, toutes de même forme (dix tables). Les valeurs qui vont ensemble forment une seule table
(série, taille de fichier) ; la description en forme deux, son texte et son balisage (réponse 1).

| Table | Valeur versionnée (types de STAGING) | Observation retenue quand |
|---|---|---|
| `core.book_title_version` | `title` text | `title` non nul (toujours, en pratique) |
| `core.book_cover_version` | `cover_url` text | `cover_url` non nul |
| `core.book_description_version` | `description_sha256` text, `description_length` integer | description non nulle |
| `core.book_description_markup_version` | `description_markup_sha256` text, `description_markup_length` integer | balisage non nul |
| `core.book_series_version` | `series_form`, `series_name`, `series_position`, `series_total` | `series_name` non nul |
| `core.book_print_pages_version` | `print_pages` integer | non nul |
| `core.book_aplus_version` | `has_aplus` boolean | non nul (`false` : bloc vide, c'est une valeur) |
| `core.book_publication_date_version` | `publication_date` date | non nulle |
| `core.book_language_version` | `language` text | non nulle |
| `core.book_file_size_version` | `file_size_value` numeric(8,1), `file_size_unit` text | `file_size_value` non nul |

Colonnes communes à chaque table, en plus de la valeur :

| Colonne | Type | Contenu |
|---|---|---|
| `asin` | text, clé étrangère vers `core.book` | |
| `valid_from`, `valid_to` | date | premier et dernier jour (Paris) **observés** de la version |
| `first_observed_at`, `last_observed_at` | timestamptz | horodatages des observations extrêmes |
| `observations` | integer ≥ 1 | fiches éligibles portant cette valeur dans la version |
| `first_raw_page_id`, `last_raw_page_id` | bigint, clés étrangères vers `raw.raw_page` | lignage |

Clé primaire `(asin, first_raw_page_id)`. Les colonnes de valeur reprennent les **types et les `CHECK`** de
`staging.product_observation` : série cohérente, taille et unité ensemble, `KB` ou `MB`, etc.

**Description** : `description_sha256` est l'empreinte déjà calculée par l'extracteur sur le texte
(`description_text_sha256`). `description_length` est sa longueur en caractères, `char_length(description_text)`. Le
texte n'est lu que pour ce calcul, dans la fonction, et n'est jamais écrit dans CORE (règle 3). Le **balisage** a sa
propre table, de même forme (`description_markup_sha256`, empreinte de l'extracteur ; `description_markup_length`) : une
réécriture change les deux empreintes, un simple changement de mise en forme ne change que celle du balisage.

**Pourquoi une table par attribut.** Chaque valeur garde son type natif et ses contraintes. Une date reste une date et
se compare comme une date. Une série reste quatre champs liés par leur contrainte de cohérence. Les requêtes sont
directes : `SELECT … FROM core.book_title_version WHERE asin = …`. Ajouter un attribut, c'est ajouter une table, sans
toucher aux autres.

**Pourquoi pas une table commune.**
- Avec une valeur en texte, les dates et les nombres se compareraient comme du texte, aucune contrainte ne serait
  possible, et chaque lecture devrait reconvertir la valeur.
- Avec plusieurs colonnes typées facultatives (`value_text`, `value_int`, `value_date`…), il faudrait une contrainte
  « une seule colonne remplie, la bonne pour cet attribut ». Les valeurs composées (série, taille) n'y entrent pas.
- En `jsonb`, le typage disparaît.

**Mise en œuvre de la règle.** Dix tables de même forme, mais la règle de la section 4 n'est **écrite qu'une fois** :
`core.rebuild()` parcourt une liste (table, colonnes, expressions de STAGING) et assemble pour chaque attribut la même
requête (SQL dynamique, `EXECUTE format(…)`), au lieu de dix blocs recopiés. Une erreur de copie dans un seul bloc
devient impossible ; les contre-épreuves portent sur cette règle unique, et le test de lignage compare les valeurs à
STAGING table par table.

### 4. Règle exacte de détection d'un changement

Pour un livre et un attribut :
1. on prend les observations éligibles de ce livre où la valeur de l'attribut est **non nulle** (colonne « Observation
   retenue quand » du tableau de la section 3). Les observations où elle est nulle sont ignorées pour cet attribut : un `NULL` n'est
   pas un changement ;
2. on les ordonne par `fetched_at`, puis par `raw_page.id` ;
3. une observation **ouvre une version** si c'est la première, ou si sa valeur diffère de celle de l'observation
   précédente. La comparaison porte sur la valeur entière, champ par champ, avec `IS DISTINCT FROM` : toute différence
   compte, sans retouche (ni casse, ni espaces au-delà de ce que fait déjà l'extracteur) ;
4. le numéro de version est la somme cumulée de ces ouvertures ; chaque version regroupe ses observations, avec ses
   bornes et son compte.

Toutes les observations éligibles comptent, et pas seulement la dernière du jour : un changement en cours de journée
crée deux versions qui se touchent le même jour, comme pour les noms de catégorie (décision 020, section 6).

**Exemple sur trois observations** (série d'un livre, valeurs inventées) :

| Observation | Moment (UTC) | Série observée |
|---|---|---|
| O1 | 10 nov. 09:00 | « Livre 2 sur 3 » (forme `livre_n_sur_n`, position 2, total 3) |
| O2 | 12 nov. 09:00 | `NULL` (ligne de série non lue) |
| O3 | 14 nov. 09:00 | « Livre 2 sur 4 » (total passé à 4) |

- O2 est ignorée : ce n'est pas un changement.
- O3 diffère de O1 par le total : nouvelle version.
- Résultat : deux versions. « Livre 2 sur 3 », du 10 au 10 novembre (1 observation), puis « Livre 2 sur 4 », du 14 au
  14 novembre (1 observation). Entre le 10 et le 14, la série est inconnue.
- Si O3 avait de nouveau porté « Livre 2 sur 3 », il n'y aurait eu qu'une version, du 10 au 14 novembre, avec
  2 observations.
- Avec trois valeurs A, B, A, on obtient trois versions : un retour à une ancienne valeur ouvre une nouvelle version.

**Valeur disparue.** Comme un `NULL` n'est pas un changement, la disparition réelle d'une valeur (série retirée, bloc A+
supprimé) ne crée pas de version. Elle se lit en comparant le `valid_to` de la dernière version au dernier jour de fiche
du livre (`core.book.last_product_day`) : une version qui s'arrête avant ce jour n'a plus été vue depuis.

### 5. Mesures : état du jour

**`core.product_day`** : une ligne par (livre, jour de Paris) observé. Elle vient de la **dernière fiche éligible du
jour** (`fetched_at` le plus grand, puis `id` le plus grand ; même règle qu'au lot 1).

| Colonne | Type | Contenu |
|---|---|---|
| `asin` | text, clé étrangère vers `core.book` | |
| `day` | date | jour de Paris |
| `raw_page_id` | bigint, clé étrangère vers `raw.raw_page` | fiche retenue (lignage) |
| `observed_at` | timestamptz | heure de la fiche retenue |
| `day_observations` | smallint ≥ 1 | fiches éligibles de ce livre ce jour-là |
| `price_amount`, `currency` | numeric(8,2), text | prix de l'onglet **sélectionné** (le format de la fiche) ; avec « Emprunt », prix d'achat du message « ou … pour acheter » |
| `price_qualifier` | text | `exact`, `a_partir_de`, `non_affiche`, etc. (valeurs de STAGING) |
| `ku_borrow` | boolean | onglet affiché « Emprunt » : indice d'abonnement **non vérifié**, exclu des analyses (décision 015) |
| `rating` | numeric(2,1) | note moyenne ; `NULL` si aucun avis |
| `review_count` | integer | nombre d'avis affiché sur la fiche (« Commentaires client »), 0 si aucun |
| `stars_1_percent` … `stars_5_percent` | smallint | répartition des étoiles, en pourcentages affichés |
| `general_rank` | integer | rang général ; `NULL` : non affiché ce jour-là |
| `general_rank_store`, `general_rank_list_type` | text | boutique (`digital-text`, `books`) et liste (`paid`, `free`) du rang général |
| `general_rank_category_node` | text | nœud de la sous-boutique, dans la forme rare de l'inventaire ; sinon `NULL` |

- Clé primaire `(asin, day)`.
- `CHECK` repris de STAGING : prix et devise ensemble ; note `NULL` si et seulement si aucun avis ; rang général et ses
  colonnes ensemble.
- La répartition des étoiles est en colonnes, et non dans une table à part : elle est toujours présente (431 fiches sur
  431 dans l'inventaire), et une ligne par (livre, jour) reste plus simple à lire.

**`core.product_day_category_rank`** : les rangs par catégorie de la fiche retenue.

| Colonne | Type | Contenu |
|---|---|---|
| `asin`, `day` | clé étrangère vers `core.product_day` | |
| `position` | smallint | ordre sur la fiche (1 à 3) |
| `rank` | integer ≥ 1 | |
| `store` | text | `digital-text` ou `books` (une fiche ebook peut avoir des rangs dans la boutique papier) |
| `list_type` | text | `paid` ou `free` |
| `source`, `category_node` | text, clé étrangère vers `core.category` | règle 6 |

Clé primaire `(asin, day, position)`.

**Deux sources jamais mêlées.** Le prix, la note et le nombre affichés sur une carte de Top (`core.ranking_day`) et sur
une fiche (`core.product_day`) restent dans leurs tables respectives. Ils ne se corrigent jamais l'un l'autre
(`exploration-amazon.md`, « Deux sources de classement »). Les Tops affichent des « évaluations », les fiches des
« Commentaires » : ce ne sont pas forcément les mêmes nombres.

### 6. Livres et catégories : jours par source

**`core.book`** (règle 5) : les colonnes `first_day` et `last_day` du lot 1 sont remplacées par quatre colonnes.

| Colonne | Contenu |
|---|---|
| `first_ranking_day`, `last_ranking_day` | premier et dernier jour où le livre figure dans une page de Top retenue (lot 1) |
| `first_product_day`, `last_product_day` | premier et dernier jour d'une fiche éligible du livre |

Chaque paire est nulle ou renseignée en entier, et au moins une des deux est renseignée (`CHECK`). Un livre connu
seulement par une fiche n'a pas de jours de Top.

**`core.category`** (règle 6) : de même, `first_day` et `last_day` deviennent `first_list_day` et `last_list_day`, pour
les pages de Top, et `first_product_rank_day` et `last_product_rank_day`, pour les rangs de fiches retenues, général ou
par catégorie.

- Une catégorie vue seulement dans les rangs d'une fiche y figure, identifiée par (source, nœud), sans jours de liste et
  sans nom (`core.category_name` ne lit que les pages de Top).
- La **boutique** (`store`) reste sur chaque rang, et non sur la catégorie : un même nœud observé dans deux boutiques
  ferait échouer une contrainte, sans que rien n'établisse aujourd'hui que c'est impossible (question ouverte 4).

### 7. Fiches en échec et fiches sans rang général

**Les trois fiches `parse_failed`** :
- elles n'ont aucune ligne dans STAGING, donc rien dans CORE ;
- elles ne créent ni jour, ni version, ni ligne fictive. Le jour de leur capture, le livre n'a pas de `product_day` si
  aucune autre fiche éligible ne le couvre ;
- elles sont **comptées** dans le journal (`product_pages_failed` : fiches de la version courante en échec) et restent
  visibles au bilan de l'extracteur, comme aujourd'hui ;
- quand l'extracteur sera corrigé (nouvelle `EXTRACTOR_VERSION`, lot de nettoyage prévu), elles seront réextraites. Si
  elles passent `ok`, elles entreront dans CORE à la construction suivante, sans autre action.

**Fiches sans rang général** (6 dans l'inventaire du 11 octobre) :
- la fiche reste éligible, et sa ligne `product_day` existe, avec `general_rank` et ses colonnes à `NULL` (« non
  affiché ce jour-là ») ;
- ses rangs par catégorie, s'il y en a, sont gardés ;
- le rang de la veille n'est **jamais** reporté (règle 7) ;
- STAGING ne distingue pas « non affiché » de « section absente » : l'extracteur met une page en échec quand une section
  présente est illisible. Un `NULL` signifie donc que le rang n'était pas affiché.

### 8. Vue des valeurs actuelles

**`core.book_current`** (vue, `security_invoker = true`) : une ligne par livre de `core.book`.
- Pour chaque attribut, la valeur de sa version la plus récente (`last_observed_at` le plus grand), avec le jour de sa
  dernière observation (`title`, `title_seen_on`, `cover_url`, `cover_seen_on`, etc.).
- La dernière ligne de `core.product_day` du livre : jour, prix, note, nombre d'avis, rang général.
- Les jours par source de `core.book`.

« Actuelle » veut dire **dernière valeur observée**, pas « valeur d'aujourd'hui » : le jour d'observation est donné à
côté de chaque valeur pour que l'âge se voie. Un livre connu seulement par les Tops a ses colonnes de fiche à `NULL`.

La vue ne stocke rien : elle relit les tables. Elle n'entre donc pas dans l'empreinte.

### 9. Construction

- Deux fonctions définissent les fiches une seule fois : `core.eligible_product_page(version)` (fiches éligibles,
  section 1) et `core.retained_product_page(version)` (dernière fiche éligible du jour de chaque livre, avec le compte),
  toutes deux `SECURITY INVOKER`, fermées à `PUBLIC`, exécutables par `books_transformer`.

- `CORE_VERSION` passe à `'2'`. La migration 15 remplace `core.rebuild()` : une seule fonction, une seule transaction,
  qui vide puis reconstruit les deux lots.
- Ordre des `DELETE`, imposé par les clés étrangères : rangs de fiches, `product_day`, tables de versions, puis les
  tables du lot 1. Ordre des `INSERT` : catégories (Tops et rangs de fiches), noms, listes du jour, livres (Tops et
  fiches), rangs du jour, versions d'attributs, `product_day`, rangs de fiches, journal.
- **Journal** (`core.build_run`), nouvelles colonnes :
  - `product_pages_eligible`, `product_pages_used`, `product_pages_other_version`, `product_pages_failed` ;
  - `product_days`, `attribute_versions` (total des dix tables), `product_category_ranks` ;
  - colonnes nulles pour les constructions antérieures à `CORE_VERSION` 2 (lignes déjà présentes sur atlas).
- **Bilan de l'extracteur** : une ligne « CORE fiches : N fiche(s) retenue(s) sur M, J livre-jour(s), V version(s)
  d'attributs ». En information, les fiches en échec et les fiches d'une autre version.
- Les règles du lot 1 ne changent pas. Seules les colonnes de jours de `core.book` et `core.category` sont renommées et
  complétées. Le test 014 est adapté en conséquence (version 2, noms de colonnes) ; ses autres attentes restent
  identiques.

### 10. Droits, liste blanche et empreinte

- `books_transformer` : `SELECT, INSERT, DELETE` sur les douze nouvelles tables ; `EXECUTE` sur
  `core.eligible_product_page(text)` et `core.retained_product_page(text)`, fermées à `PUBLIC`. Il lit déjà les quatre
  tables de fiches de STAGING.
- `books_reader` : `SELECT` sur les douze nouvelles tables et sur la vue `core.book_current`, aucune fonction.
- La liste attendue de `tests/sql/test_008_role_lecture.sql` est mise à jour dans le même commit : colonnes ajoutées,
  colonnes renommées de `core.book` et `core.category` : **350 colonnes lisibles** (176 de plus : 136 dans les douze
  tables, 40 dans la vue). CORE ne contient toujours aucun texte de description, aucune adresse de page, aucun nom de
  personne.
- `sql/observations/empreinte_core.sql` reçoit une ligne par nouvelle table : compte et `md5` des lignes triées par clé
  primaire. La vue est exclue (elle se déduit des tables), comme le journal.

## Tests

Test SQL `tests/sql/test_015_core_fiches.sql`, sur le modèle du test 014 : fiches inventées extraites avec la version
« test », seules éligibles pendant le test ; tout est annulé à la fin, puis on vérifie que CORE a retrouvé son contenu
d'avant. ASIN, titres, séries et nœuds sont inventés.

1. **Déterminisme** : deux constructions donnent la même empreinte ; lignes de STAGING réécrites dans un autre ordre
   physique, même empreinte.
2. **`NULL` n'est pas un changement** : couverture X, `NULL`, X → une version, 2 observations ; série de l'exemple
   (section 4) → deux versions ; série dont seul le total change puis revient (2/3, 2/4, 2/3) → trois versions ;
   `has_aplus` `NULL` ignoré, mais `false` compté comme une valeur ; description : réécriture et changement de mise en
   forme distingués par les deux empreintes.
3. **Retour à une ancienne valeur** : titre A, B, A → trois versions et leurs bornes.
4. **Deux observations le même jour** : mesures, la seconde retenue, `day_observations = 2` ; attributs, valeur
   différente → deux versions le même jour ; à la même seconde, `id` le plus grand.
5. **Minuit de Paris** : fiches à `22:59:59Z` et `23:00:00Z` en hiver, `21:59:59Z` et `22:00:00Z` en été → deux jours ;
   résultat identique avec la session dans un autre fuseau.
6. **Livre connu seulement par une fiche** : présent dans `core.book` avec ses jours de fiche et sans jours de Top ;
   catégorie vue seulement dans ses rangs : présente dans `core.category`, sans jours de liste ni nom.
7. **Exclusions** : fiche `parse_failed`, fiche papier (`skipped`), fiche d'une autre version → rien dans CORE, mais
   comptées au journal ; fiche sans rang général → ligne `product_day` avec rang `NULL`, sans report de la veille.
8. **Minimisation** : aucune colonne de CORE ne s'appelle `description_text` ni `description_markup` ; un texte de
   description sentinelle, présent dans STAGING, ne se retrouve dans aucune ligne de CORE ; empreinte et longueur égales
   à celles de STAGING.
9. **Lignage** : chaque version et chaque `product_day` désignent des fiches éligibles du bon livre ; valeurs égales à
   celles de STAGING.
10. **Vue** : valeur actuelle égale à la dernière version, jour d'observation correct, livre sans fiche à `NULL` ; vue
    en `security_invoker`.
11. **Droits** : `books_reader` lit tout, n'écrit rien, n'exécute aucune fonction ; `books_collector` n'a rien ;
    fonctions fermées à `PUBLIC`.
12. **Journal** : comptes attendus, en dernier (comme au test 014).

Test 014 relancé et adapté (version 2, colonnes de jours). Test 008 mis à jour. Python : la ligne du bilan, et une
construction refusée qui laisse les deux lots inchangés.

**Contre-épreuves** (mutation de la migration 15 dans un PostgreSQL 17 jetable), chacune doit faire échouer un test :
- `NULL` traité comme un changement (2) ;
- versions calculées sans `lag`, une seule version par valeur distincte, donc A, B, A fusionnés (3) ;
- versions calculées sur la seule dernière fiche du jour (4) ;
- première fiche du jour au lieu de la dernière (4) ;
- jour en UTC, ou dans le fuseau de la session (5) ;
- fiche papier éligible, ou fiche en échec éligible (7) ;
- rang général de la veille reporté (7) ;
- colonne `description_text` ajoutée à une table de CORE (8, et test 6 du test 008) ;
- comparaison de la série sans le total (2) ;
- fonction laissée à `PUBLIC` (11) ;
- vue sans `security_invoker` (10).

## Risques

- **Couverture** : l'adresse de l'image peut changer sans que l'image change (paramètres de mise en forme). Elle créerait
  alors des versions « de bruit ». La comparaison reste exacte, comme le veut la règle ; une normalisation éventuelle
  serait une nouvelle version des règles (question 3).
- **Série** : le total change à chaque nouveau tome, ce qui crée une version. C'est une information réelle, pas du
  bruit, mais il faut le savoir à la lecture.
- **Valeur disparue invisible** comme changement (section 4) : elle se lit par l'écart entre `valid_to` et le dernier
  jour de fiche.
- **Densité** : les fiches sont capturées moins souvent que les Tops. Les versions ont des bornes observées éloignées,
  et les mesures du jour manquent la plupart des jours.
- **Règle unique en SQL dynamique** (section 3) : plus d'erreur de copie possible, mais la requête assemblée n'est
  vérifiée qu'à l'exécution, et non à la création de la fonction. Les tests l'exécutent sur les dix tables, et le test
  de lignage compare chaque valeur à STAGING.
- **Renommage des colonnes de jours** dans `core.book` et `core.category` : une requête écrite contre le lot 1 devra être
  adaptée. Aucune n'existe encore dans le dépôt.

## Questions tranchées le 11 novembre 2026

1. **Balisage de la description** : versionné à part, par empreinte et longueur, jamais le texte (section 3).
2. **ISBN-13 et fil de catégories** : hors du lot 2 ; ils restent dans STAGING.
3. **Adresse de couverture** : non normalisée. `sql/observations/versions_couverture.sql`, lancé sous `books_reader`
   après le déploiement, rend la distribution du nombre de versions de couverture par livre (comptes seulement).
4. **Boutique** : sur chaque rang (section 6) ; à revoir si un relevé montre qu'un nœud n'appartient qu'à une boutique.
5. **Indices d'abonnement** (`ku_borrow` des fiches, `ku_sticker_hint` des Tops) : repris dans CORE comme indices non
   vérifiés, exclus des analyses jusqu'à une décision ; absents de la vue `core.book_current`.

> Note du 11 novembre 2026 (**mise en œuvre**) :
> - Migration 015 appliquée en développement ; test SQL 015 conforme (45 contrôles) ; tests 005 à 014 conformes, dont le
>   test 014 adapté (version 2, colonnes de jours) et le test 008 (350 colonnes). Suite Python : 736 réussis (une fiche
>   Kindle entre dans CORE, la fiche papier non ; empreinte et longueur de description égales à STAGING).
> - **Contre-épreuves** (mutation de la migration 015 dans un PostgreSQL 17 jetable, migrations 001 à 014 appliquées) :
>   15 mutations, toutes refusées ; témoins (tests 015, 014 et 008 sur la migration intacte) conformes. `NULL` traité
>   comme un changement (2a) ; retour à une ancienne valeur fusionné (pris par 2b2) ; comparaison sur le seul premier
>   champ (2b2) ; versions calculées sur la seule dernière fiche du jour (4a) ; première fiche du jour (4b) ; jour en UTC
>   et jour selon le fuseau de la session (4a) ; fiche en échec ou papier éligible (pris par 6a : ces livres
>   apparaissent dans `core.book`) ; rang général de la veille reporté (7b) ; colonne `description_text` ajoutée (8a,
>   et test 6 du test 008) ; prix de l'onglet non sélectionné (pris par 4b) ; fonctions laissées à `PUBLIC` (11a) ; vue
>   sans `security_invoker` (10c) ; vue retirée des droits de `books_reader` (test 6 du test 008).
> - **Recette en développement** : extracteur relancé (image reconstruite) : lot 1 inchangé (14 pages, 690 lignes,
>   393 livres), catégories passées de 2 à 13 (nœuds vus seulement dans les rangs des fiches) ; 5 fiches retenues sur 5,
>   5 livres-jours, 50 versions d'attributs, 15 rangs par catégorie ; code 0. Empreintes des 17 tables identiques avant
>   et après une reconstruction dans une transaction annulée. `versions_couverture.sql` : 5 livres à une version
>   (une seule fiche chacun : le relevé n'a de sens qu'après plusieurs séances).
