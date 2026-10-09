# B.O.O.K.S.

**Books Observatory & Optimization Knowledge System**

Observatoire historisé du marché du livre numérique, centré dans un premier temps sur Amazon Kindle France.

> 🚧 Projet en cours de construction.

## Collecteur

Le collecteur est un service Docker Compose rangé dans le profil `collector` :
`docker compose up` ne le lance jamais. Pour chaque catégorie de `config/targets.toml`, une tournée obtient
la page 1 du Top 100 payant et du Top 100 gratuit, et leur page 2 seulement si la page 1 compte 50 rangs et annonce
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
- Modifier `config/targets.toml` impose de reconstruire l'image (`docker compose build collector`).

Codes de sortie (décision 008) : 0 aucune anomalie (`success`) ; 1 au moins une anomalie (`partial`)
ou erreur d'exécution (`failed`) ; 2 configuration invalide. Une page bloquée ou non conforme est déposée
avec son statut, sans arrêt ; le bilan de fin d'ingestion détaille les anomalies.

Le collecteur se connecte avec le rôle `books_collector` (migration 002), aux droits limités,
jamais avec le propriétaire de la base.

Les commandes ci-dessous sont à lancer depuis le dossier du dépôt, dans bash
(sur atlas, ou Git Bash sur le PC : PowerShell ne comprend pas la redirection `<`).

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
La procédure est décrite pour `books_collector` ; pour l'autre rôle, remplacer son nom, et la variable
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

## Tests

Tests Python, dans un conteneur jetable (le dépôt est monté en lecture seule) :

```bash
docker run --rm -v "${PWD}:/src:ro" python:3.12-slim sh -c 'cp -r /src /tmp/w && cd /tmp/w && pip install -q --root-user-action=ignore ".[dev]" && pytest -v'
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

Tests du script de rapatriement (`scripts/rapatrier-sauvegarde.ps1`), même principe que ceux du script d'envoi :

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\powershell\Test-RapatrierSauvegarde.ps1
```

## Envoi des captures vers atlas (PC)

Décision 008. Après une séance de capture, double-cliquer sur `scripts\envoyer-captures.cmd`,
puis saisir le mot de passe d'atlas quand `ssh` le demande. Le script envoie les paires complètes,
atlas les vérifie, les place dans `inbox/` et lance l'ingestion ; le bilan s'affiche.

- **Prérequis** : l'alias SSH `atlas` dans `C:\Users\<vous>\.ssh\config` (fichier sans extension),
  et le réglage local `scripts\envoyer-captures.local.psd1`, copié depuis `envoyer-captures.exemple.psd1`
  (ignoré par Git : il contient votre chemin personnel).
- **Issues** : transfert échoué (code 3) : rien n'est déplacé sur le PC, relancer ; transfert réussi :
  les captures passent dans `envoyees\AAAA-MM\`, que l'ingestion soit sans anomalie (code 0) ou non (code 1).
- `envoyees\` est une archive permanente : ne jamais la vider.

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

## Restauration d'une sauvegarde

Une sauvegarde `pg_dump` (voir `scripts/backup.sh`) ne contient **ni les rôles, ni les droits portant
sur la base elle-même**. Après restauration sur un serveur neuf, `schema_migration` indiquerait les
migrations 002 et 005 comme appliquées, alors que `books_collector` et `books_transformer` n'existeraient pas
et que le retrait du droit `TEMPORARY` serait perdu. Procédure, sur une base vide (serveur neuf, `.env` en place) :

1. Démarrer PostgreSQL :

   ```bash
   docker compose up -d postgres
   ```

2. Créer les deux rôles **avant** la restauration (sinon leurs droits sur `raw` et `staging` ne peuvent pas être
   restaurés, et `--exit-on-error` arrête la restauration) :

   ```bash
   docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE ROLE books_collector LOGIN" -c "CREATE ROLE books_transformer LOGIN"'
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
   dans `.env`.

6. Vérifier avec les tests SQL des migrations 002 et 005 (section Tests).

Les pages brutes se restaurent à part, depuis `~/books-backup/raw` vers `~/books-data/raw`.

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

2. Compléter `.env` à partir de `.env.example`, avec des chemins absolus
   (le `~` n'est pas interprété dans un `.env`) :

   ```
   BOOKS_ENV=prod
   BOOKS_RAW_DIR=/home/arnaud/books-data/raw
   BOOKS_CAPTURES_DIR=/home/arnaud/books-data/captures
   ```

   Sans `BOOKS_CAPTURES_DIR`, seul le lancement du collecteur échoue ; PostgreSQL et la sauvegarde
   continuent de fonctionner. Le dossier des captures n'entre pas dans la sauvegarde nocturne (décision 008).

3. Appliquer les migrations manquantes (section Migrations), puis définir le mot de passe
   de `books_collector` (section Mot de passe) et le reporter dans `.env`.

## Licence

© 2026 AJyeL — Tous droits réservés.
Ce code est publié à titre de démonstration (portfolio). Aucune licence de réutilisation n'est accordée.
