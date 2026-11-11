# 020 — Couche CORE, lot 1 : classements

Date : 9 novembre 2026 · **Acceptée** · Migration : `sql/migrations/014_core_classements.sql`

> Statut : **acceptée** le 9 novembre 2026 par le porteur du projet, avec six réponses intégrées au texte : grain avec le
> type de liste (section 5) ; nom non lu sans effet, retour à un ancien nom en nouvelle version (section 6) ; deux heures
> de p1 et p2 conservées sans seuil (section 4) ; CORE ne lit que les pages de la version courante de l'extracteur
> (section 3) ; catégorie identifiée par (source, nœud) (section 5) ; prix, devise, note, nombre d'évaluations et indice
> d'abonnement de la ligne retenue dans `core.ranking_day` (section 5).

## Contexte

STAGING contient une ligne par (page RAW, rang) (`staging.ranking_entry`, décision 011) et une observation du nom de
catégorie par page (`staging.category_observation`, décision 014). Il ne choisit rien : deux captures de la même liste
le même jour donnent deux jeux de lignes (décision 011, section 1, « le choix d'une observation relève des couches
suivantes »). Les analyses et le futur tableau de bord ont besoin d'une couche où ce choix est fait une fois, selon des
règles écrites, testées et versionnées : CORE.

Le lot 1 ne traite que les **classements** (livre, catégorie, liste, jour, rang, avec les valeurs de la carte retenue) et
l'**identité des catégories** avec leurs noms. Titres, fiches produit et rapports Amazon Ads viendront dans des lots
suivants.

Règles tranchées par le porteur du projet (9 novembre 2026) : CORE entièrement dérivée de STAGING et reconstructible à
l'identique ; jour civil Europe/Paris ; une ligne par (livre, catégorie, type de liste, jour), la dernière observation du
jour, avec le nombre d'observations ; aucune ligne sans observation ; livre = ASIN, catégorie = (source, numéro de nœud),
nom de catégorie = attribut observé, versionné ; lignage vers la page RAW retenue ; reconstruction atomique après chaque
extraction, version des règles identifiée ; lecture par `books_reader`.

## Décision

### 1. Mécanisme : tables reconstruites en entier par une fonction SQL, dans une transaction

- Schéma `core`, propriété du propriétaire de la base, créé par la **migration 014**.
- Les tables de CORE sont de **vraies tables**, vidées puis remplies en entier à chaque construction par la fonction
  `core.rebuild(version de l'extracteur)`, écrite en SQL dans la migration. Rien n'est mis à jour en place, rien n'est
  écrit à la main. Les pages éligibles sont définies une seule fois, par la fonction `core.eligible_page(version)`.
- La construction se fait **dans une seule transaction** : `DELETE` de toutes les lignes, puis `INSERT … SELECT` depuis
  STAGING et `raw.raw_page`, puis une ligne dans le journal `core.build_run`, rendue par la fonction. Si quoi que ce soit
  échoue, la transaction est annulée et CORE reste **exactement** dans son état précédent.
- `DELETE` plutôt que `TRUNCATE` : `DELETE` respecte l'isolation des transactions (MVCC). Un lecteur qui interroge
  CORE pendant une construction voit l'ancien contenu, en entier, jusqu'à la validation ; il n'est ni bloqué ni exposé
  à une table vide. `TRUNCATE` poserait un verrou exclusif (lecteurs en attente) et une transaction de lecture déjà
  ouverte en `REPEATABLE READ` verrait des tables vides. Le coût de `DELETE` (lignes mortes à nettoyer par l'autovacuum)
  est négligeable à notre volume (section 9).
- **Verrou** : la fonction prend `pg_advisory_xact_lock` sur le **numéro du verrou de l'extracteur**
  (`repository.LOCK_KEY`). Dans la session de l'extracteur, qui le détient déjà, il est accordé d'office ; depuis une
  autre session, la construction attend la fin de l'extraction en cours. STAGING ne change donc pas pendant une
  construction. `lock_timeout = 30s` (réglage de la fonction) : une construction bloquée échoue visiblement au lieu
  d'attendre indéfiniment.
- **Version des règles** : constante `CORE_VERSION` (`v_core_version`) dans le corps de la fonction (`'1'`),
  enregistrée dans chaque ligne de `core.build_run`. Toute modification des règles de construction est une nouvelle
  migration qui remplace la fonction **et** incrémente `CORE_VERSION` (règle de projet, section 10). Comme la
  construction est toujours complète, la version ne déclenche rien : elle identifie les règles qui ont produit le
  contenu actuel.

**Pourquoi pas des vues matérialisées.** PostgreSQL 17 permettrait à `books_transformer` de les rafraîchir (droit
`MAINTAIN`), et le rafraîchissement de plusieurs vues dans une transaction est atomique. Mais :
- une vue matérialisée n'accepte **aucune contrainte** (ni clé primaire, ni clé étrangère, ni `CHECK`) : le grain, le
  lignage et les règles de cohérence ne seraient plus garantis par la base, seulement par un index unique ;
- `REFRESH MATERIALIZED VIEW` (non concurrent) pose un verrou exclusif : les lecteurs attendent ; la variante
  `CONCURRENTLY` évite ce blocage mais exige un index unique et recalcule tout en comparant ancien et nouveau contenu ;
- la version et le journal des constructions demanderaient de toute façon une table à côté ;
- `pg_dump` ne sauvegarde pas leur contenu : il est recalculé au `pg_restore`, ce qui fait de la restauration un
  recalcul silencieux plutôt qu'une copie vérifiable.

**Pourquoi pas des vues simples.** Le calcul serait refait à chaque lecture (`books_reader` a un délai de 2 minutes),
sans contraintes, et sans trace de la version qui a servi.

**Pourquoi les règles en SQL dans la migration, et non en Python.** Les règles sont des sélections et des jointures :
SQL les exprime directement, et les tests SQL de la migration les vérifient sans passer par le Python. Le schéma et les
règles qui le remplissent changent ensemble, par migration, relue avant déploiement. Limite assumée : changer une règle
demande une migration (et non une simple image), et le PC comme atlas doivent l'appliquer avant le prochain passage de
l'extracteur.

### 2. Jour de Paris

- Le jour d'une observation est `(raw.raw_page.fetched_at AT TIME ZONE 'Europe/Paris')::date`. `fetched_at` est
  l'horodatage UTC de la capture (`captured_at` du JSON de l'extension, décision 007).
- Le fuseau est écrit **en toutes lettres** dans la fonction : le résultat ne dépend jamais du réglage `TimeZone` de la
  session qui lance la construction.
- Changement d'heure : `AT TIME ZONE` applique les règles de la base de fuseaux (`tzdata`) du serveur ; le dernier
  dimanche d'octobre compte 25 heures, celui de mars 23. Aucun traitement particulier.
- Les horodatages restent en UTC dans les colonnes (`observed_at`, convention du projet) ; seule la colonne `day` est un
  jour civil de Paris.

### 3. Pages retenues et règle exacte du « dernier de la journée »

**Pages éligibles** (`core.eligible_page`) : pages RAW de classement (`page_type = 'bestseller_list'`, statut `ok`) dont
l'extraction est `ok` dans `staging.page_extraction` **et a été faite par la version de l'extracteur passée à
`core.rebuild()`** (l'extracteur passe la sienne, `EXTRACTOR_VERSION`). Cela exclut d'office les pages `blocked` et
`invalid`, les enregistrements manuels (hors du périmètre de l'extracteur, décision 011), les pages en échec
d'extraction (aucune ligne dans STAGING) et les pages extraites par une autre version : CORE ne lit que l'état actuel de
STAGING, jamais deux versions mélangées. Les pages d'une autre version sont **comptées** (`pages_other_version` du
journal, information au bilan) ; en marche normale, il n'y en a aucune, car l'extracteur réextrait toutes les pages
d'une autre version avant de construire CORE.

**Liste** = (source, catégorie, type de liste) ; **page de liste** = (source, catégorie, type de liste, numéro de page).

Règle, pour chaque page de liste et chaque jour de Paris :
1. la page retenue est la page éligible dont `fetched_at` est **le plus grand** ;
2. à `fetched_at` égal, celle dont `raw_page.id` est le plus grand (déposée en dernier) : la règle ne laisse jamais le
   choix à l'ordre de lecture de la base ;
3. le **nombre d'observations du jour** est le nombre de pages éligibles de cette page de liste ce jour-là (retenue
   comprise) ;
4. une page plus récente mais **non éligible** (`blocked`, `invalid`, échec d'extraction, autre version) ne remplace
   jamais une page éligible plus ancienne. Elle n'est pas comptée dans les observations.

### 4. Listes sur deux pages (p1 et p2)

Les pages 1 (rangs 1 à 50) et 2 (rangs 51 à 100) d'une liste sont des captures distinctes, faites à quelques minutes
d'intervalle, parfois à des heures différentes, parfois pas du tout.

- Le « dernier du jour » est déterminé **pour chaque numéro de page séparément** (section 3). La liste du jour est
  l'union des lignes de la p1 retenue et de la p2 retenue.
- **Livre présent sur les deux pages retenues** (il a changé de page entre les deux captures) : on garde la ligne de la
  capture la plus récente (même règle : `fetched_at`, puis `id`). L'autre rang n'a pas de ligne : un trou apparaît dans
  la suite des rangs de cette page, comme pour un rang manquant (décision 011, section 5). Le nombre de cas est compté
  dans le journal (`cross_page_duplicates`) et signalé au bilan.
- **Complétude de la liste du jour**, enregistrée dans `core.list_day` (section 5) et garantie par une contrainte :
  - complète : p1 retenue avec moins de 50 rangs (liste courte, sans page 2), ou p1 et p2 retenues ;
  - incomplète : p1 de 50 rangs sans p2, ou p2 sans p1.
  Règle « 50 rangs » de la décision 004 ; `staging.page_extraction.entry_count` porte le nombre de rangs extraits.
- **Écart entre les deux captures** : les deux heures sont conservées dans `core.list_day` (`p1_observed_at`,
  `p2_observed_at`), **sans seuil ni alerte** pour l'instant.
- Conséquence pour l'analyse : l'**absence** d'un livre d'une liste incomplète ne signifie pas qu'il est sorti du Top 100.
  Les analyses filtrent ou signalent les listes incomplètes.

### 5. Tables et colonnes

Noms techniques en minuscules ; jours en `date` (Paris), horodatages en `timestamptz` (UTC). La source vaut aujourd'hui
toujours `amazon_fr` (`raw.raw_page.source`).

**`core.build_run`** — journal des constructions réussies (n'est **pas** vidé : c'est un historique, hors du contenu
reconstructible ; une construction annulée n'y laisse rien, elle est signalée dans le bilan de l'extracteur).

| Colonne | Type | Contenu |
|---|---|---|
| `id` | bigint identité, clé primaire | |
| `built_at` | timestamptz | `now()` de la transaction |
| `core_version` | text | `CORE_VERSION` de la fonction |
| `extractor_version` | text | version de l'extracteur dont les pages ont été lues |
| `pages_eligible` | integer | pages éligibles |
| `pages_other_version` | integer | pages de classement extraites (ok) par une autre version, exclues |
| `pages_used` | integer | pages retenues (toutes listes, tous jours) |
| `books`, `categories`, `category_name_versions` | integer | lignes des tables correspondantes |
| `list_days`, `list_days_incomplete` | integer | lignes de `core.list_day`, dont incomplètes |
| `ranking_rows` | integer | lignes de `core.ranking_day` |
| `cross_page_duplicates` | integer | livres présents sur p1 et p2 retenues (section 4) |

**`core.book`** — un livre par ASIN observé dans une liste retenue.

| Colonne | Type | Contenu |
|---|---|---|
| `asin` | text, clé primaire, `CHECK (asin ~ '^[A-Z0-9]{10}$')` | |
| `first_day`, `last_day` | date | premier et dernier jour où le livre figure dans une page retenue |

**`core.category`** — une catégorie par (source, numéro de nœud).

| Colonne | Type | Contenu |
|---|---|---|
| `source` | text | `amazon_fr` |
| `category_node` | text, `CHECK (category_node ~ '^[0-9]+$')` | |
| `first_day`, `last_day` | date | premier et dernier jour d'une page éligible de la catégorie |

Clé primaire `(source, category_node)`.

**`core.category_name`** — versions des noms observés (section 6).

| Colonne | Type | Contenu |
|---|---|---|
| `source`, `category_node` | text, clé étrangère vers `core.category` | |
| `name_kind` | text, `CHECK IN ('display', 'short')` | nom d'affichage (`<h1>`) ou nom court (arborescence) |
| `name` | text, non vide | |
| `valid_from`, `valid_to` | date | premier et dernier jour **observés** de la version (bornes incluses) |
| `first_observed_at`, `last_observed_at` | timestamptz | horodatages des observations extrêmes |
| `observations` | integer | pages éligibles portant ce nom dans la version |
| `first_raw_page_id`, `last_raw_page_id` | bigint, clés étrangères vers `raw.raw_page` | lignage |

Clé primaire `(source, category_node, name_kind, first_raw_page_id)` (deux versions peuvent commencer à la même seconde,
jamais sur la même page).

**`core.list_day`** — une ligne par (source, catégorie, type de liste, jour) observé.

| Colonne | Type | Contenu |
|---|---|---|
| `source`, `category_node` | text, clé étrangère vers `core.category` | |
| `list_type` | text, `CHECK IN ('paid', 'free')` | |
| `day` | date | jour de Paris |
| `p1_raw_page_id`, `p2_raw_page_id` | bigint, clés étrangères vers `raw.raw_page`, `NULL` si absente | pages retenues |
| `p1_observed_at`, `p2_observed_at` | timestamptz | heures des deux captures retenues |
| `p1_observations`, `p2_observations` | smallint | observations du jour de chaque page (0 si absente) |
| `p1_ranks`, `p2_ranks` | smallint | rangs extraits de chaque page retenue (0 si absente) |
| `complete` | boolean | section 4 |

Clé primaire `(source, category_node, list_type, day)` ; `CHECK` : au moins une page retenue ; page absente ⇔ heure
nulle, observations et rangs à 0 ; `complete` égal à la règle de la section 4.

**`core.ranking_day`** — une ligne par (livre, source, catégorie, type de liste, jour).

| Colonne | Type | Contenu |
|---|---|---|
| `asin` | text, clé étrangère vers `core.book` | |
| `source`, `category_node`, `list_type` | text | |
| `day` | date | jour de Paris |
| `rank` | smallint, `CHECK BETWEEN 1 AND 100` | |
| `raw_page_id` | bigint, clé étrangère vers `raw.raw_page` | page retenue d'où vient la ligne (lignage) |
| `observed_at` | timestamptz | `fetched_at` de cette page |
| `day_observations` | smallint, `>= 1` | observations du jour de cette page de liste |
| `has_card` | boolean | carte détaillée présente ; faux : valeurs suivantes inconnues (`NULL`) |
| `price_amount`, `currency` | numeric(8,2), text | prix affiché et devise ISO 4217 |
| `rating` | numeric(2,1) | note moyenne sur 5 |
| `review_count` | integer | nombre d'**évaluations** affiché (notes avec ou sans commentaire), pas d'avis écrits |
| `ku_sticker_hint` | boolean | indice d'abonnement **non vérifié** (décision 011, section 8), exclu des analyses |

- Clé primaire `(asin, source, category_node, list_type, day)` ; unicité `(source, category_node, list_type, day, rank)` ;
  clé étrangère `(source, category_node, list_type, day)` vers `core.list_day` ; mêmes `CHECK` que
  `staging.ranking_entry` (sans carte, tout `NULL` ; note et évaluations ensemble ; prix et devise ensemble).
- `has_card` est repris avec les valeurs : sans lui, un `NULL` ne dirait pas si la valeur est inconnue (pas de carte) ou
  absente (carte sans évaluation), distinction de la décision 011.
- Le **type de liste** fait partie du grain : une catégorie a deux classements distincts, payant et gratuit, et un même
  livre peut figurer dans les deux le même jour.
- Lignage : on ne référence pas `staging.ranking_entry` par clé étrangère, car elle bloquerait la réextraction de STAGING
  (suppression des lignes d'une page) ; la page RAW, en ajout seul, suffit à retrouver la ligne de STAGING
  (`raw_page_id`, `rank`).

### 6. Versions du nom d'une catégorie

- Pour chaque catégorie et chaque sorte de nom (`display`, `short`), les observations éligibles où ce nom est lu sont
  ordonnées par (`fetched_at`, `raw_page.id`). Une **version** est une suite ininterrompue d'observations portant le même
  nom ; un nom différent ouvre une nouvelle version. Un retour à un ancien nom ouvre une **nouvelle** version (A, B, A
  donne trois versions).
- Un nom non lu (`NULL`, élément absent ou de forme inconnue, décision 014) n'est **pas** un changement : l'observation
  est ignorée pour cette sorte de nom. Les deux sortes sont versionnées séparément.
- Bornes : jours et horodatages **observés**, sans extrapolation (section 7). Entre la dernière observation d'une
  version et la première de la suivante, le nom est inconnu ; deux versions peuvent se toucher le même jour si le nom
  change en cours de journée.
- Le nom « courant » d'une catégorie est celui de sa version dont `last_observed_at` est le plus grand ; il n'est pas
  recopié dans `core.category` (il se lit par requête).

### 7. Aucune observation, aucune ligne

- Aucun report de la veille, aucune interpolation : un jour sans page retenue n'a de ligne ni dans `core.list_day` ni
  dans `core.ranking_day` ; un livre absent d'une liste retenue n'a pas de ligne pour ce jour.
- Les séries de CORE sont donc **irrégulières** (décision 005, conséquences) ; les analyses doivent préciser les jours
  observés.

### 8. Enchaînement avec l'extraction

- `books.transformer` appelle `core.rebuild(EXTRACTOR_VERSION)` à la **fin de chaque exécution**, après les pages, sous
  son verrou consultatif, en une seule instruction (connexion en autocommit : une instruction, une transaction).
  Toujours, même si aucune page n'était à extraire : la construction est peu coûteuse, et une nouvelle `CORE_VERSION`
  (migration appliquée) prend effet au passage suivant.
- Les pages en échec n'ont pas de ligne dans STAGING : CORE est construite sans elles, et le bilan le dit déjà.
- **Construction en échec** (verrou non obtenu à temps, contrainte violée) : transaction annulée, CORE inchangée,
  anomalie au bilan (« CORE non reconstruite : … ; contenu précédent conservé »), statut `partial`, code 1. Le repère
  `BOOKS:EXTRACTION:CODE` porte donc aussi ce résultat (décision 012). Une erreur d'exécution (connexion perdue) reste
  une erreur d'exécution (`failed`).
- Bilan : une ligne « CORE version n » (pages retenues sur éligibles, listes du jour dont incomplètes, lignes, livres,
  catégories, versions de nom) ; en information, les doublons p1/p2 et les pages d'une autre version exclues. Une
  extraction non lancée (verrou occupé) ne reconstruit rien.
- Pas de commande séparée dans ce lot : la reconstruction seule s'obtient en relançant l'extracteur, qui répond « déjà à
  jour » pour les pages et reconstruit CORE.

### 9. Rôles et droits

- `books_transformer` : `USAGE` sur `core` ; `SELECT, INSERT, DELETE` sur `core.book`, `core.category`,
  `core.category_name`, `core.list_day`, `core.ranking_day` ; `SELECT, INSERT` sur `core.build_run` ; `EXECUTE` sur
  `core.rebuild(text)` et `core.eligible_page(text)`. Il lit déjà `raw.raw_page` et les tables de STAGING utilisées.
- Les deux fonctions : `SECURITY INVOKER` (elles s'exécutent avec les droits de l'appelant, rien de plus),
  `search_path = pg_catalog, pg_temp`, noms entièrement qualifiés, `REVOKE EXECUTE … FROM PUBLIC` (décision 016,
  section 4).
- `books_reader` : `USAGE` sur `core`, `SELECT` sur les six tables. Aucune exécution des fonctions. La liste attendue du
  test de liste blanche (`tests/sql/test_008_role_lecture.sql`) est mise à jour **dans le même commit** (décision 016,
  section 7) : 174 colonnes lisibles (60 de plus), schémas `core, guide, public, raw, staging`. CORE ne contient aucune
  adresse, aucun nom de personne : seulement ASIN, numéros et noms de catégorie, rangs, valeurs des cartes, jours,
  horodatages et identifiants de page.
- `books_collector` : aucun droit sur `core`. Aucun privilège par défaut.
- Volume : environ 7 000 pages de classement par an au rythme actuel (une dizaine de listes, deux pages, chaque jour),
  soit quelques centaines de milliers de lignes de STAGING ; une construction complète reste de l'ordre de la seconde.

### 10. Règle de projet

« Toute modification des règles de construction de CORE incrémente `CORE_VERSION` dans le même commit », sur le modèle
d'`EXTRACTOR_VERSION` et d'`ADS_EXTRACTOR_VERSION`. Ligne ajoutée à `CLAUDE.md` par le porteur du projet le
9 novembre 2026 (fichier non versionné).

## Tests

Test SQL `tests/sql/test_014_core_classements.sql`, même principe que les précédents (lancé par le propriétaire,
pages inventées extraites avec la version « test », seules éligibles pendant le test ; tout annulé à la fin, puis
vérification que CORE et son journal ont retrouvé leur état d'avant). ASIN et numéros de catégorie inventés.

1. **Déterminisme** : construction sans version refusée ; empreinte du contenu (`md5` des lignes triées par clé, journal
   exclu), reconstruction, empreintes identiques ; lignes de STAGING réécrites dans un autre ordre physique, empreinte
   identique.
2. **Jour de Paris au passage de minuit** : hiver, `22:59:59Z` jour J et `23:00:00Z` jour J+1 ; été, `21:59:59Z` et
   `22:00:00Z` ; les deux jours de changement d'heure (25 octobre 2026, 25 heures ; 28 mars 2027, 23 heures) ; résultat
   et contenu identiques avec la session en `UTC`, `America/New_York` et `Asia/Tokyo`.
3. **Plusieurs observations par jour** : trois captures ok → la dernière, 3 observations ; capture plus récente en échec
   d'analyse, bloquée ou d'une autre version → ignorée, non comptée ; même seconde → `id` le plus grand ; livre vu
   seulement dans une capture non retenue → aucune ligne ce jour-là ; heure de la capture retenue conservée.
4. **Deux pages** : p1 et p2 → complète, deux heures ; livre sur les deux → une ligne, celle de la capture la plus
   récente, rang libéré ; p1 courte → complète ; p1 de 50 rangs sans p2, p2 seule → incomplètes.
5. **Versions du nom** : A, A, NULL, B, A, C (C le même jour que le dernier A) → quatre versions d'affichage ; nom
   court avec un NULL → une seule version ; catégorie sans nom lu → aucune version ; identité (source, nœud).
6. **Absence** : jour sans capture → aucune liste du jour ; livre absent un jour → aucune ligne ce jour-là ; page d'une
   autre version seule → rien dans CORE.
7. **Atomicité** : construction qui échoue en cours (déclencheur temporaire) → contenu et journal inchangés, alors
   qu'une nouvelle catégorie était apparue dans STAGING ; page d'une autre version → comptée, contenu inchangé.
8. **Droits** : fonctions fermées à `PUBLIC` et `SECURITY INVOKER` ; `books_transformer` construit mais ne modifie pas
   le journal ; `books_reader` lit les six tables, ne peut ni écrire, ni vider, ni exécuter les fonctions ;
   `books_collector` n'a rien.
9. **Lignage** : chaque ligne retrouve sa ligne de STAGING (page, rang) avec les mêmes valeurs ; chaque ligne vient d'une
   page retenue de sa liste du jour ; livre sans carte : valeurs `NULL`.
10. **Journal** de la dernière construction : comptes attendus (placé en dernier, pour que les tests 2 à 9 désignent
    d'abord la règle enfreinte).

Python (`tests/python/test_extraction.py`, base jetable) : CORE construite après l'extraction (comptes, liste du jour,
ligne du bilan) ; reconstruite à l'identique sans page à extraire ; construction refusée → page extraite quand même,
statut `partial`, code 1, message, contenu et journal précédents conservés ; seule la version demandée est lue ; verrou
occupé → aucune construction.

## Restauration d'essai

- Les tables de CORE et leur contenu sont dans la sauvegarde `pg_dump`, comme STAGING. Aucun nouveau rôle : l'étape 2
  de la procédure du README est inchangée. La fermeture des fonctions à `PUBLIC` et les droits sont dans la sauvegarde.
- Étape 6 : tests SQL **005 à 014** ; `sql/observations/comptes_par_table.sql` compte aussi les six tables de CORE.
- **Contrôle nouveau** : `sql/observations/empreinte_core.sql`, lancé sous `books_reader`, rend pour chaque table son
  nombre de lignes et une empreinte `md5` (aucune donnée lisible ; fuseau et format des dates fixés). On compare les
  empreintes d'atlas et de la base restaurée, puis celles de la base restaurée après une reconstruction faite **dans une
  transaction annulée** par le propriétaire (commande dans le README). Égalité attendue partout : la sauvegarde est
  fidèle, et CORE est bien reconstructible à l'identique à partir de STAGING.
- Limite : une version différente de `tzdata` sur le serveur de restauration pourrait, en théorie, changer un jour de
  Paris ; l'empreinte après reconstruction le révélerait.

## Risques

- **p1 et p2 de moments différents** : la liste du jour peut assembler deux captures éloignées de plusieurs heures ;
  doublons et trous possibles, comptés, heures conservées, mais pas jugés.
- **Construction bloquée** : `DELETE` ne bloque pas les lecteurs, mais une session tenant un verrou fort (une migration
  en cours) ou une extraction d'une autre session ferait échouer la construction après 30 s : visible, CORE inchangée.
- **Densité des observations** : les bornes de version d'un nom et les jours observés dépendent de la régularité des
  séances ; une version courte peut n'être qu'un trou de capture.
- **Captures après minuit** : une séance commencée à 23 h 50 et finie à 0 h 10 se répartit sur deux jours de Paris.

## Questions ouvertes

1. Seuil d'écart entre p1 et p2 : aucun pour l'instant (heures conservées) ; à décider si les analyses le demandent.
2. Hiérarchie des catégories (parents de l'arborescence) : non lue par l'extracteur (décision 014, section 3), donc hors
   de CORE.
3. Lots suivants : attributs observés des livres (titre, avec versions), fiches produit, rapports Amazon Ads.

> Note du 9 novembre 2026 (**mise en œuvre**) :
> - Migration 014 appliquée en développement ; test SQL 014 conforme (48 contrôles), tests 005 à 013 inchangés et
>   conformes, test 008 conforme avec la liste blanche mise à jour (174 colonnes). Suite Python : 735 réussis (5 de
>   plus).
> - **Contre-épreuves** (mutation de la migration dans un PostgreSQL 17 jetable, migrations 001 à 013 appliquées) :
>   17 mutations, toutes refusées par un test ; témoins (migration intacte) conformes. Premier du jour au lieu du dernier
>   (pris dès le test 2, dont deux jours comptent deux captures) ; jour en UTC ; jour selon le fuseau de la session
>   (test 2) ; égalité départagée par le plus petit `id` (3c) ; page en échec éligible (contrainte `list_day_p1_ck`) ;
>   autre version mélangée (3a) ; doublon p1/p2 gardé (clé primaire) ; doublon p1/p2 tranché pour la plus ancienne
>   (4b) ; retour à un ancien nom fusionné (5a) ; nom NULL compté (contrainte `NOT NULL`) ; nom NULL qui coupe une
>   version (5b) ; report de la veille (pris dès le test 2, dont la liste a des jours sans capture) ; `EXECUTE` laissé
>   à `PUBLIC` (8a, et test 6 du test 008) ; `SECURITY DEFINER` (8a) ; `INSERT` accordé à `books_reader` (8) ; colonne
>   ajoutée hors liste blanche (test 6 du test 008).
> - **Recette en développement** : extracteur relancé (image reconstruite) : 14 pages retenues sur 14, 8 listes du jour
>   complètes, 690 lignes, 393 livres, 2 catégories, 4 versions de nom ; code 0. Empreintes de CORE identiques avant et
>   après une reconstruction dans une transaction annulée.

> Note du 11 novembre 2026 (décision 021, CORE lot 2) : `CORE_VERSION` passe à 2 (migration 015) ; `core.rebuild()`
> reconstruit les deux lots dans la même transaction. Les règles du lot 1 sont inchangées. Dans `core.book`,
> `first_day` et `last_day` deviennent `first_ranking_day` et `last_ranking_day` (jours de fiche à côté) ; dans
> `core.category`, `first_list_day` et `last_list_day` (jours de rang de fiche à côté). Test 014 adapté en conséquence.
