# B.O.O.K.S.

**Books Observatory & Optimization Knowledge System**

Observatoire historisé du marché du livre numérique, centré dans un premier temps sur Amazon Kindle France.

> 🚧 Projet en cours de construction.

## Collecteur

Le collecteur est un service Docker Compose rangé dans le profil `collector` :
`docker compose up` ne le lance jamais. Toute page de classement Kindle d'amazon.fr est dans le périmètre,
quelle que soit la catégorie (décision 014) : aucune liste de catégories n'est tenue dans le dépôt. En dev, une tournée
obtient chaque page 1 enregistrée dans `data/samples/`, et sa page 2 seulement si la page 1 compte 50 rangs et annonce
une page 2. Chaque page est validée, puis déposée dans RAW (fichier dans `BOOKS_RAW_DIR` + ligne `raw.raw_page`) ;
la tournée est ensuite close. Voir les décisions 003 et 004.

```bash
docker compose build collector
docker compose --profile collector run --rm collector
```

- **En dev (PC)**, la source est locale : les pages enregistrées à la main dans `data/samples/`
  (« Page Web, HTML uniquement », nom `amazon_fr_bestsellers_{catégorie}_{paid|free}_p{n}_{AAAA-MM-JJ}.html`,
  type de liste toujours explicite ; voir `docs/exploration-amazon.md`).
  Le `.env` du PC doit contenir les deux lignes `COMPOSE_FILE` et `COMPOSE_PATH_SEPARATOR` de `.env.example`.
  Aucune requête vers Amazon. Chaque lancement ajoute une tournée **définitive** dans RAW (ajout seul).
- **En prod (atlas)**, le collecteur ingère les captures de l'extension déposées dans `BOOKS_CAPTURES_DIR/inbox/`
  (décision 008) : contrôles d'intégrité, quarantaine dans `BOOKS_CAPTURES_DIR/quarantaine/`, dépôt dans RAW.
  Tant que le montage de ce dossier n'existe pas (étape 4), il s'arrête (code 2) sans rien ingérer.
  Ne **jamais** définir `COMPOSE_FILE` sur atlas.
- Ajouter une catégorie ne demande ni modification du dépôt ni reconstruction de l'image : il suffit de la consulter.
  Le bilan d'ingestion signale, en information (numéro seulement), toute catégorie jamais vue dans RAW.

Codes de sortie (décision 008) : 0 aucune anomalie (`success`) ; 1 au moins une anomalie (`partial`)
ou erreur d'exécution (`failed`) ; 2 configuration invalide. Une page bloquée ou non conforme est déposée
avec son statut, sans arrêt ; le bilan de fin d'ingestion détaille les anomalies.

Le collecteur se connecte avec le rôle `books_collector` (migration 002), aux droits limités,
jamais avec le propriétaire de la base.

Les commandes ci-dessous sont à lancer depuis le dossier du dépôt, dans bash
(sur atlas, ou Git Bash sur le PC : PowerShell ne comprend pas la redirection `<`).

## Extracteur (RAW → STAGING)

Décision 011. Lit les captures de l'extension déposées dans RAW (`extension-dom`, statut `ok`) et en range le contenu
dans `staging.ranking_entry` : une ligne par livre classé (rang, ASIN, titre, prix, note, nombre d'évaluations,
couverture). Aucun auteur n'est extrait. Elle est lancée automatiquement après chaque ingestion d'un envoi de captures
(décision 012), et reste lançable seule, à la main :

```bash
docker compose --profile transformer run --rm transformer
```

- **Prérequis** : migration 005 appliquée, mot de passe de `books_transformer` défini et reporté dans `.env`
  (`BOOKS_TRANSFORMER_PASSWORD`, section « Mot de passe »), image reconstruite après une mise à jour du code
  (`docker compose build collector` : les deux services partagent l'image).
- **Ce qui est extrait** : les pages jamais extraites, extraites par une autre version de l'extracteur, ou en échec.
  Les autres sont « déjà à jour ». Réextraction complète : ajouter `--force` après `transformer`.
- **Sécurité** : rôle `books_transformer` seulement (tout autre rôle est refusé) ; RAW monté en **lecture seule** ;
  aucun accès au dossier des captures.
- **Codes de sortie** : 0 aucune anomalie (ou rien à extraire) ; 1 au moins une page en échec (intégrité du fichier
  RAW ou forme inconnue), CORE non reconstruite, extraction déjà en cours, ou erreur d'exécution ; 2 configuration
  invalide.
  Une page en échec est reprise à chaque exécution : le code 1 se répète tant que son problème n'est pas traité.
- **Bilan** affiché et enregistré dans `staging.extract_run.notes` : pages extraites, à jour, en échec (avec le
  motif), hors périmètre par motif, résultat de la construction de CORE.
- **CORE** (décision 020) : après les pages, à chaque exécution (même sans page à extraire), l'extracteur reconstruit
  en entier le schéma `core` par `core.rebuild()`, dans une seule transaction, à partir des seules pages extraites par
  sa version. Une ligne par (livre, catégorie, type de liste, jour de Paris) dans `core.ranking_day`, issue de la
  dernière capture du jour de chaque page de liste ; listes du jour et leur complétude (`core.list_day`) ; versions
  des noms de catégorie (`core.category_name`) ; livres et catégories ; journal des constructions (`core.build_run`,
  avec `core_version`). Construction refusée par la base : CORE garde son contenu précédent, et le code vaut 1.
  Les lecteurs voient l'ancien contenu jusqu'à la fin de la construction.

## Migrations

Appliquées par le propriétaire de la base (`POSTGRES_USER`), une par une, dans l'ordre :

```bash
docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < sql/migrations/003_statut_invalid.sql
```

(remplacer le nom du fichier par celui de chaque migration manquante.)

Migrations déjà appliquées : table `public.schema_migration`.

## Mot de passe des rôles books_collector et books_transformer

À faire une fois par environnement (PC, atlas) et pour chaque rôle : après la migration 002 pour
`books_collector` (collecteur), après la migration 005 pour `books_transformer` (extracteur, décision 011),
et après toute restauration. Les deux mots de passe sont différents ; aucun n'est jamais écrit dans le dépôt.
`books_reader` (explorations SQL, décision 016) n'a **pas de mot de passe** tant qu'aucun tunnel n'est décidé :
pas de secret sans usage.
La procédure est décrite pour `books_collector` ; pour `books_transformer`, remplacer son nom, et la variable
`BOOKS_COLLECTOR_PASSWORD` par `BOOKS_TRANSFORMER_PASSWORD`.

1. Ouvrir psql en tant que propriétaire :

   ```bash
   docker compose exec postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
   ```

2. Dans psql, définir le mot de passe (saisi deux fois, sans affichage) puis quitter :

   ```
   \password books_collector
   \q
   ```

   `\password` chiffre le mot de passe avant de l'envoyer : il n'apparaît ni dans l'historique,
   ni dans les journaux du serveur (contrairement à `ALTER ROLE … PASSWORD '…'`).

3. Recopier ce mot de passe dans `.env` : `BOOKS_COLLECTOR_PASSWORD=…`

## Explorations SQL (rôle books_reader)

Rôle de lecture seule (décision 016), sur atlas (après `ssh`) comme sur le PC :

```bash
cd ~/books && docker compose exec postgres sh -c 'psql -U books_reader -d "$POSTGRES_DB"'
```

- **Aucun mot de passe demandé** : dans le conteneur, la connexion locale (et même `-h 127.0.0.1`) est en `trust`
  (image officielle `postgres:17`). Le rôle protège contre les **erreurs humaines**, pas contre un intrus ; la barrière
  contre un intrus reste l'accès SSH à atlas (décision 016, section 1).
- **Ce qu'il lit** : toutes les tables de `staging` et de `core`, `raw.collect_run`, `raw.raw_page` sans ses adresses
  (`requested_url` et `final_url` : identifiant de session possible dans `ref=`), `public.schema_migration`.
  Un `SELECT *` sur `raw.raw_page` est refusé : nommer les colonnes. Il ne lira jamais la correspondance des
  auteurs (décision 013).
- **Garde-fous** : transactions en lecture seule par défaut ; requête interrompue après 2 minutes ; transaction
  inactive fermée après 5 minutes ; 2 connexions au plus. Aucune écriture ni création d'objet n'est permise, même
  en désactivant la lecture seule.
- **Par le port publié** (`127.0.0.1:5433` de l'hôte, par exemple via un tunnel SSH) : mot de passe exigé (SCRAM).
  Le rôle n'en ayant pas, cette connexion est impossible tant qu'aucun tunnel n'est décidé (décision 016, section 2).
- Sur le PC, une copie rapatriée (décision 009) restaurée en développement s'explore de la même façon, sans risque
  pour la production.

## Tests

Tests Python, dans un conteneur jetable (le dépôt est monté en lecture seule, et copié **sans `data/`** : les tests
ne dépendent jamais de vraies données) :

```bash
docker run --rm -v "${PWD}:/src:ro" python:3.12-slim sh -c 'mkdir /tmp/w && (cd /src && tar --exclude=./data -cf - .) | tar -xf - -C /tmp/w && cd /tmp/w && pip install -q --root-user-action=ignore ".[dev]" && pytest -v'
```

Cette commande **saute** les tests qui demandent une base de données (dépôt et orchestration de l'extracteur,
décision 011). Pour la suite **complète**, contre un PostgreSQL 17 jetable (migrations 001 à 005, rôle
`books_transformer`, une base neuve par test, tout supprimé à la fin, aucune autre base touchée) :

```bash
bash tests/lancer-tests-postgres.sh
```

Des arguments éventuels sont transmis à pytest (par exemple `-k extraction`).

Tests SQL de la migration 001 : voir l'en-tête de `tests/sql/test_001_couche_raw.sql`.

Tests SQL de la migration 002 (droits de `books_collector`), qui se vérifient eux-mêmes
(code de sortie 0 = tout est conforme) :

```bash
docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U books_collector -d "$POSTGRES_DB"' < tests/sql/test_002_role_collecteur.sql
```

Tests SQL de la migration 003 (statut `invalid`), même principe :

```bash
docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U books_collector -d "$POSTGRES_DB"' < tests/sql/test_003_statut_invalid.sql
```

Tests SQL de la migration 004 (méthode de capture), même principe :

```bash
docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U books_collector -d "$POSTGRES_DB"' < tests/sql/test_004_methode_de_capture.sql
```

Tests SQL de la migration 005 (couche STAGING, rôle `books_transformer`). Ils se lancent **en tant que
propriétaire** de la base : il prépare des lignes de test dans `raw`, puis endosse tour à tour `books_transformer`
et `books_collector` (`SET LOCAL ROLE`), pour vérifier les droits réels de chacun :

```bash
docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_005_couche_staging.sql
```

Tests SQL de la migration 006 (observation du nom des catégories, décision 014), même principe :

```bash
docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_006_observation_des_categories.sql
```

Tests SQL de la migration 007 (fiches produit dans STAGING, décision 015), même principe :

```bash
docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_007_fiches_produit.sql
```

Tests SQL de la migration 008 (rôle de lecture `books_reader`, décision 016), même principe. Ils contiennent la
**liste blanche** de ce que `books_reader` peut lire : toute migration qui crée ou modifie une table qu'il lit, ou lui
ouvre un accès, met cette liste à jour dans le même commit.

```bash
docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_008_role_lecture.sql
```

Tests SQL de la migration 009 (guide de veille, schéma `guide`, décision 017), même principe :

```bash
docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_009_guide.sql
```

Tests SQL de la migration 010 (correspondance des textes sensibles, schéma `mapping`, décision 019), même principe :

```bash
docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_010_correspondance.sql
```

Tests SQL de la migration 011 (rapports Amazon Ads dans RAW, décision 018), même principe :

```bash
docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_011_rapports_ads.sql
```

Tests SQL de la migration 012 (rapports Amazon Ads dans STAGING, décision 018), même principe :

```bash
docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_012_staging_ads.sql
```

Tests SQL de la migration 013 (ordre des rapports par leurs données, nom non jugé, meilleure estimation), même principe :

```bash
docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_013_ordre_des_rapports.sql
```

Tests SQL de la migration 014 (couche CORE, classements : déterminisme, jour de Paris, dernière capture du jour, p1 et
p2, versions des noms, absence de ligne, atomicité, droits, lignage ; décision 020), même principe. Les pages de test
sont extraites avec la version « test » : seules elles entrent dans CORE pendant le test, qui vérifie ensuite que CORE
a retrouvé son contenu d'avant :

```bash
docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_014_core_classements.sql
```

Les appels concurrents de `mapping.code_for` sont vérifiés par la suite Python
(`tests/python/test_correspondance_concurrence.py`, PostgreSQL jetable).

Les tests SQL supposent **toutes** les migrations appliquées : depuis la 004, leurs lignes de test portent
une méthode de capture.

Tests du script de réception (`scripts/recevoir-captures.sh`), dans un conteneur Debian jetable :

```bash
docker run --rm -v "${PWD}:/src:ro" debian:bookworm-slim bash /src/tests/shell/test_recevoir_captures.sh
```

Tests du script d'envoi (`scripts/envoyer-captures.ps1`), sur le PC, contre un faux atlas en conteneur
(publié sur `127.0.0.1:2222` le temps des tests), Docker Desktop démarré :

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\powershell\Test-EnvoyerCaptures.ps1
```

Tests du script d'export de la sauvegarde (`scripts/exporter-sauvegarde.sh`), dans un conteneur Debian jetable :

```bash
docker run --rm -v "${PWD}:/src:ro" debian:bookworm-slim bash /src/tests/shell/test_exporter_sauvegarde.sh
```

Tests du script de réception des rapports Amazon Ads (`scripts/recevoir-ads.sh`), dans un conteneur Debian jetable :

```bash
docker run --rm -v "${PWD}:/src:ro" debian:bookworm-slim bash /src/tests/shell/test_recevoir_ads.sh
```

Tests du script d'envoi des rapports (`scripts/envoyer-ads.ps1`), même principe que ceux du script d'envoi des
captures (faux atlas sur `127.0.0.1:2222`) :

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\powershell\Test-EnvoyerAds.ps1
```

Tests du script de rapatriement (`scripts/rapatrier-sauvegarde.ps1`), même principe que ceux du script d'envoi :

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\powershell\Test-RapatrierSauvegarde.ps1
```

Tests du script d'export du guide de veille (`scripts/exporter-guide.sh`), dans un conteneur Debian jetable :

```bash
docker run --rm -v "${PWD}:/src:ro" debian:bookworm-slim bash /src/tests/shell/test_exporter_guide.sh
```

Tests du script de réception du guide (`scripts/recevoir-guide.ps1`), même principe que ceux du script d'envoi :

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\powershell\Test-RecevoirGuide.ps1
```

## Envoi des captures vers atlas (PC)

Décisions 008 et 012. Après une séance de capture, double-cliquer sur `scripts\envoyer-captures.cmd`,
puis saisir le mot de passe d'atlas quand `ssh` le demande. Le script envoie les paires complètes,
atlas les vérifie, les place dans `inbox/`, lance l'ingestion, puis l'extraction vers STAGING (quel que soit le
résultat de l'ingestion) ; les deux bilans s'affichent.

- **Prérequis** : l'alias SSH `atlas` dans `C:\Users\<vous>\.ssh\config` (fichier sans extension),
  et le réglage local `scripts\envoyer-captures.local.psd1`, copié depuis `envoyer-captures.exemple.psd1`
  (ignoré par Git : il contient votre chemin personnel).
- **Issues** : transfert échoué (code 3) : rien n'est déplacé sur le PC, ni ingéré, ni extrait, relancer ;
  transfert réussi : les captures passent dans `envoyees\AAAA-MM\` dans tous les cas, et le code vaut 0 si
  l'ingestion **et** l'extraction sont sans anomalie, 1 sinon (anomalie, étape non effectuée, configuration invalide
  sur atlas, ou atlas pas à jour). Le code 2 signale un réglage invalide sur le PC (rien envoyé).
  Une page en échec d'extraction donne le code 1 à chaque envoi, tant qu'elle n'est pas traitée.
- `envoyees\` est une archive permanente : ne jamais la vider.

## Envoi des rapports Amazon Ads vers atlas (PC)

Décision 018, lot A. Télécharger chaque rapport à la main, par le lien de l'e-mail d'Amazon (aucun programme ne suit
ce lien), dans le dossier des rapports ; puis double-cliquer sur `scripts\envoyer-ads.cmd` et saisir le mot de passe
d'atlas quand `ssh` le demande. Atlas vérifie le lot, le place dans `~/books-data/ads/inbox/`, lance l'ingestion
(`docker compose --profile ads run --rm ads`, rôle `books_collector`), puis l'extraction vers STAGING quel que soit
le résultat de l'ingestion (`docker compose --profile ads-transformer run --rm ads-transformer`, rôle
`books_transformer`, RAW en lecture seule ; réextraction complète : ajouter `--force`) ; les deux bilans s'affichent.

- **Ne pas ouvrir les rapports dans Excel avant l'envoi** : un réenregistrement change leur forme (séparateur,
  identifiants `="…"`, encodage) ; le fichier serait refusé, ou pire, transformé.
- **Prérequis** : l'alias SSH `atlas`, et le réglage local `scripts\envoyer-ads.local.psd1`, copié depuis
  `envoyer-ads.exemple.psd1` (ignoré par Git).
- **Envoyés** : les fichiers `.csv` au nom fait de lettres, chiffres, `_`, `.` et `-`, suivi au plus du suffixe
  « (n) » qu'ajoute le navigateur à un second téléchargement de même nom (un rapport programmé garde le même nom à chaque
  livraison), de 20 Mo au plus. Les autres sont signalés et laissés sur place.
- **Sur atlas**, chaque fichier reçu est déposé dans RAW (`raw.ads_report_file`, fichier compressé sous
  `~/books-data/raw/amazon_ads/`), avec le statut `ok` ou `invalid` et son motif : RAW ne juge que la nature du fichier
  (vide, encodage, type, dimension « Date »), jamais son nom. L'horodatage du nom n'est pas une date d'export : c'est le
  nom proposé par Amazon Ads, modifiable (décision 018, note du 9 novembre 2026). Un fichier déjà reçu (même empreinte)
  est retiré sans nouvelle ligne.
- **Extraction** (lot B) : le contenu de chaque fichier `ok` est jugé (statuts recalculables `ok`, `no_activity`,
  `parse_failed`, `integrity_failed`), puis ses lignes sont écrites dans STAGING avec des identifiants, des codes
  (`mapping.code_for`) et des quantités, jamais un texte. Meilleure estimation de chaque jour : vues
  `staging.ads_product_day_best` et `staging.ads_search_term_day_best` (pour chaque type, l'export le plus récent
  par dernière date des données, puis par ingestion, qui contient un fichier de ce type et couvre le jour).
  Le bilan réconcilie les deux types de chaque export (même dernière date, sur l'intersection de leurs bornes). La
  fraîcheur (« Aucun rapport Amazon Ads de moins de 10 jours », d'après la dernière date des données) est signalée, en
  information, par le bilan de l'extraction des captures.
- **Issues** : transfert échoué (code 3) : rien n'est déplacé sur le PC, relancer ; transfert réussi : les rapports
  passent dans `envoyes\AAAA-MM\{lot}\` (mois d'envoi, puis lot) dans tous les cas, et le code vaut 0 si l'ingestion **et**
  l'extraction sont sans anomalie, 1 sinon (fichier `invalid` ou en échec, écart de réconciliation, élément laissé en
  place, étape non effectuée, configuration invalide ou atlas pas à jour). Le code 2
  signale un réglage invalide sur le PC, ou un nom déjà présent dans `envoyes\` (rien envoyé).
- `envoyes\` est une archive permanente : ne jamais la vider. Elle contient les termes de recherche en clair
  (décisions 013 et 018).

## Copie de la base sur le PC

Décision 009. Une fois par mois au moins, double-cliquer sur `scripts\rapatrier-sauvegarde.cmd`, puis saisir
le mot de passe d'atlas quand `ssh` le demande. Atlas fait une sauvegarde neuve de la base ; le PC la reçoit,
vérifie son empreinte SHA-256 et la range avec son manifeste (`books_….dump` et `books_….dump.sha256`).

- **Prérequis** : l'alias SSH `atlas` (comme pour l'envoi des captures), et le réglage local
  `scripts\rapatrier-sauvegarde.local.psd1`, copié depuis `rapatrier-sauvegarde.exemple.psd1`, qui désigne
  un dossier existant (ignoré par Git).
- **Issues** : code 0, copie reçue et vérifiée ; code 1, échec (rien n'est ajouté au dossier, relancer) ;
  code 2, réglage à corriger (aucune connexion).
- Aucune copie n'est supprimée ; le bilan signale le seuil de révision (24 copies ou 5 Go).
- Pour restaurer une copie : la remettre sur atlas, puis suivre la section suivante.

## Guide de veille (PC)

Décision 017. Après l'envoi des captures d'une séance, double-cliquer sur `scripts\recevoir-guide.cmd`, puis saisir
le mot de passe d'atlas quand `ssh` le demande. Atlas lit la référence du guide (schéma `guide`, sous `books_reader`) ;
le PC la reçoit, vérifie son empreinte SHA-256 et son format (version 1), et la range avec son manifeste
(`guide_….json` et `guide_….json.sha256`). Importer ensuite ce fichier dans l'extension (page d'options du guide)
avant la séance suivante.

- **Rythme** : envoyer, puis exporter le guide, puis l'importer. Une page réouverte juste après son envoi montre des
  écarts nuls : c'est normal.
- **Prérequis** : l'alias SSH `atlas`, et le réglage local `scripts\recevoir-guide.local.psd1`, copié depuis
  `recevoir-guide.exemple.psd1`, qui désigne un dossier existant (ignoré par Git). **Jamais le dossier des captures** :
  l'envoi y signalerait le guide comme fichier hors format.
- **Issues** : code 0, guide reçu et vérifié ; code 1, échec (rien n'est ajouté au dossier, relancer) ;
  code 2, réglage à corriger (aucune connexion).
- Aucun guide n'est supprimé ni écrasé. Le fichier contient des numéros de catégorie réels : il ne va jamais dans le
  dépôt.

## Restauration d'une sauvegarde

Une sauvegarde `pg_dump` (voir `scripts/backup.sh`) ne contient **ni les rôles, ni les droits portant
sur la base elle-même**. Après restauration sur un serveur neuf, `schema_migration` indiquerait les
migrations 002, 005, 008 et 010 comme appliquées, alors que `books_collector`, `books_transformer`, `books_reader` et
`books_mapping` n'existeraient pas (ni les réglages de `books_reader`), et que le retrait du droit `TEMPORARY` serait
perdu. Procédure, sur une base vide (serveur neuf, `.env` en place) :

1. Démarrer PostgreSQL :

   ```bash
   docker compose up -d postgres
   ```

2. Créer les quatre rôles **avant** la restauration (sinon leurs droits sur `raw` et `staging`, et la propriété du
   schéma `mapping`, ne peuvent pas être restaurés, et `--exit-on-error` arrête la restauration), avec la limite de
   connexions et les réglages de `books_reader` (migration 008, décision 016), absents de la sauvegarde.
   `books_mapping` est sans connexion (migration 010, décision 019) :

   ```bash
   docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE ROLE books_collector LOGIN" -c "CREATE ROLE books_transformer LOGIN" -c "CREATE ROLE books_reader LOGIN CONNECTION LIMIT 2" -c "ALTER ROLE books_reader SET default_transaction_read_only = on" -c "ALTER ROLE books_reader SET statement_timeout = '"'"'2min'"'"'" -c "ALTER ROLE books_reader SET idle_in_transaction_session_timeout = '"'"'5min'"'"'" -c "CREATE ROLE books_mapping NOLOGIN"'
   ```

3. Restaurer la sauvegarde choisie :

   ```bash
   docker compose exec -T postgres sh -c 'pg_restore --exit-on-error -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < ~/books-backup/postgres/books_AAAA-MM-JJTHH-MM-SSZ.dump
   ```

4. Retirer à nouveau le droit `TEMPORARY` (droit de la base, absent de la sauvegarde) :

   ```bash
   docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "REVOKE TEMPORARY ON DATABASE \"$POSTGRES_DB\" FROM PUBLIC"'
   ```

5. Définir les mots de passe de `books_collector` et de `books_transformer` (section ci-dessus) et les reporter
   dans `.env` ; `books_reader` reste sans mot de passe.

6. Vérifier avec les tests SQL des migrations 005 à 014 (section Tests) ; le test 008 contrôle les attributs, les
   réglages et la liste blanche de `books_reader`, le test 010 les droits de la correspondance. Comparer ensuite les
   comptes de lignes à ceux de la base d'origine, par la même requête lancée sous `books_reader` des deux côtés
   (comptes seulement, aucune donnée) :

   ```bash
   docker compose exec -T postgres sh -c 'psql -X -At -F " | " -U books_reader -d "$POSTGRES_DB"' < sql/observations/comptes_par_table.sql
   ```

   `books_reader` ne voit pas le schéma `mapping` : ses comptes par nature (aucune clé) se comparent par une requête
   lancée par le propriétaire des deux côtés :

   ```bash
   docker compose exec -T postgres sh -c 'psql -X -At -F " | " -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < sql/observations/comptes_correspondance.sql
   ```

   De même pour les rapports Amazon Ads (RAW et STAGING : exécutions, fichiers par statut, lignes ; décision 018) :

   ```bash
   docker compose exec -T postgres sh -c 'psql -X -At -F " | " -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < sql/observations/comptes_ads.sql
   ```

   CORE (décision 020) : empreintes de ses tables (comptes et md5, aucune donnée lisible), sous `books_reader`, des deux
   côtés ; elles doivent être égales :

   ```bash
   docker compose exec -T postgres sh -c 'psql -X -At -F " | " -U books_reader -d "$POSTGRES_DB"' < sql/observations/empreinte_core.sql
   ```

   Puis, sur la base restaurée seulement, les mêmes empreintes après une reconstruction de CORE faite par le
   propriétaire **dans une transaction annulée** (rien n'est conservé) : elles doivent être égales aux précédentes,
   ce qui prouve que CORE se reconstruit à l'identique à partir de STAGING :

   ```bash
   { echo 'BEGIN;'; echo 'SELECT ranking_rows FROM core.rebuild((SELECT extractor_version FROM core.build_run ORDER BY id DESC LIMIT 1));'; cat sql/observations/empreinte_core.sql; echo 'ROLLBACK;'; } | docker compose exec -T postgres sh -c 'psql -X -At -F " | " -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
   ```

Les pages brutes se restaurent à part, depuis `~/books-backup/raw` vers `~/books-data/raw` ; les rapports Amazon Ads
bruts (`amazon_ads/`) en font partie.

## Déploiement sur atlas

1. Créer le dossier des pages brutes **avant** le premier lancement du collecteur.
   Docker ne le crée pas (`create_host_path: false`) ; s'il le créait, ce serait au nom de root,
   et le collecteur (UID 1000) ne pourrait pas y écrire.

   ```bash
   mkdir -p ~/books-data/raw
   ```

   Faire de même pour le dossier des captures (décision 008) et ses trois sous-dossiers, réservés au seul
   propriétaire (UID 1000, celui du collecteur) :

   ```bash
   mkdir -p ~/books-data/captures/attente ~/books-data/captures/inbox ~/books-data/captures/quarantaine
   chmod 700 ~/books-data/captures ~/books-data/captures/attente ~/books-data/captures/inbox ~/books-data/captures/quarantaine
   stat -c '%U %u %a %n' ~/books-data/captures ~/books-data/captures/*
   ```

   Et pour le dossier des rapports Amazon Ads (décision 018) et ses deux sous-dossiers :

   ```bash
   mkdir -p ~/books-data/ads/attente ~/books-data/ads/inbox
   chmod 700 ~/books-data/ads ~/books-data/ads/attente ~/books-data/ads/inbox
   stat -c '%U %u %a %n' ~/books-data/ads ~/books-data/ads/*
   ```

2. Compléter `.env` à partir de `.env.example`, avec des chemins absolus
   (le `~` n'est pas interprété dans un `.env`) :

   ```
   BOOKS_ENV=prod
   BOOKS_RAW_DIR=/home/arnaud/books-data/raw
   BOOKS_CAPTURES_DIR=/home/arnaud/books-data/captures
   BOOKS_ADS_DIR=/home/arnaud/books-data/ads
   ```

   Sans `BOOKS_CAPTURES_DIR`, seul le lancement du collecteur échoue ; PostgreSQL et la sauvegarde
   continuent de fonctionner. Le dossier des captures n'entre pas dans la sauvegarde nocturne (décision 008).

3. Appliquer les migrations manquantes (section Migrations), puis définir le mot de passe
   de `books_collector` (section Mot de passe) et le reporter dans `.env`.

## Licence

© 2026 AJyeL — Tous droits réservés.
Ce code est publié à titre de démonstration (portfolio). Aucune licence de réutilisation n'est accordée.
