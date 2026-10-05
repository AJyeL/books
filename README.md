# B.O.O.K.S.

**Books Observatory & Optimization Knowledge System**

Observatoire historisé du marché du livre numérique, centré dans un premier temps sur Amazon Kindle France.

> 🚧 Projet en cours de construction.

## Collecteur

Le collecteur est un service Docker Compose rangé dans le profil `collector` :
`docker compose up` ne le lance jamais. À ce stade, il vérifie seulement sa configuration
et la connexion à PostgreSQL (aucune requête réseau). Voir `docs/decisions/003-collecteur-conteneurise.md`.

```bash
docker compose build collector
docker compose --profile collector run --rm collector
```

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

## Mot de passe du rôle books_collector

À faire une fois par environnement (PC, atlas), après la migration 002, et après toute restauration.
Le mot de passe n'est jamais écrit dans le dépôt.

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

## Restauration d'une sauvegarde

Une sauvegarde `pg_dump` (voir `scripts/backup.sh`) ne contient **ni les rôles, ni les droits portant
sur la base elle-même**. Après restauration sur un serveur neuf, `schema_migration` indiquerait la
migration 002 comme appliquée, alors que `books_collector` n'existerait pas et que le retrait du droit
`TEMPORARY` serait perdu. Procédure, sur une base vide (serveur neuf, `.env` en place) :

1. Démarrer PostgreSQL :

   ```bash
   docker compose up -d postgres
   ```

2. Créer le rôle **avant** la restauration (sinon ses droits sur `raw` ne peuvent pas être restaurés) :

   ```bash
   docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE ROLE books_collector LOGIN"'
   ```

3. Restaurer la sauvegarde choisie :

   ```bash
   docker compose exec -T postgres sh -c 'pg_restore --exit-on-error -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < ~/books-backup/postgres/books_AAAA-MM-JJTHH-MM-SSZ.dump
   ```

4. Retirer à nouveau le droit `TEMPORARY` (droit de la base, absent de la sauvegarde) :

   ```bash
   docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "REVOKE TEMPORARY ON DATABASE \"$POSTGRES_DB\" FROM PUBLIC"'
   ```

5. Définir le mot de passe de `books_collector` (section ci-dessus) et le reporter dans `.env`.

6. Vérifier avec les tests SQL de la migration 002 (section Tests).

Les pages brutes se restaurent à part, depuis `~/books-backup/raw` vers `~/books-data/raw`.

## Déploiement sur atlas

1. Créer le dossier des pages brutes **avant** le premier lancement du collecteur.
   Docker ne le crée pas (`create_host_path: false`) ; s'il le créait, ce serait au nom de root,
   et le collecteur (UID 1000) ne pourrait pas y écrire.

   ```bash
   mkdir -p ~/books-data/raw
   ```

2. Compléter `.env` à partir de `.env.example`, avec un chemin absolu
   (le `~` n'est pas interprété dans un `.env`) :

   ```
   BOOKS_ENV=prod
   BOOKS_RAW_DIR=/home/arnaud/books-data/raw
   ```

3. Appliquer les migrations manquantes (section Migrations), puis définir le mot de passe
   de `books_collector` (section Mot de passe) et le reporter dans `.env`.

## Licence

© 2026 AJyeL — Tous droits réservés.
Ce code est publié à titre de démonstration (portfolio). Aucune licence de réutilisation n'est accordée.
