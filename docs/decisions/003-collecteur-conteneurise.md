# 003 — Collecteur conteneurisé

Date : 4 octobre 2026

## Contexte

Le collecteur doit tourner à l'identique sur le PC de développement et sur atlas, à côté du
PostgreSQL de B.O.O.K.S., sans jamais démarrer par accident et sans emporter de secret.
Une erreur de configuration (par exemple un collecteur de développement qui se croirait en production)
doit être impossible à ignorer.

## Décision

- **Paquet Python** `books` dans `src/books/`, décrit par `pyproject.toml` (Python 3.12, `psycopg` v3).
  Le collecteur est le sous-module `books.collector`, lancé par `python -m books.collector`.
- **Configuration** uniquement par variables d'environnement (`src/books/config.py`), sans aucune valeur
  par défaut. `BOOKS_ENV` est obligatoire et vaut `dev` ou `prod` ; toute autre situation arrête
  le programme avec un message clair (code de sortie 2).
- **Image Docker** `python:3.12-slim`, utilisateur non-root `books` (UID 1000, identique à l'utilisateur
  d'atlas). Aucun secret dans l'image : `.dockerignore` exclut `.env`, `private/`, `CLAUDE.md` et `data/`.
- **Service Compose** `collector`, derrière le profil `collector` : jamais lancé par `docker compose up`.
  Lancement : `docker compose --profile collector run --rm collector`.
- **Une seule source de vérité pour la connexion** : hôte `postgres` et port `5432` (réseau interne de Compose)
  sont fixés dans `docker-compose.yml`, pas dans `.env`. Les identifiants viennent de `.env`.
- **Pages brutes** : `BOOKS_RAW_DIR` (dans `.env`) désigne le dossier de l'hôte, monté sur `/data/raw`
  dans le conteneur.
- **Le service `postgres` ne dépend jamais des variables du collecteur.** Compose valide tout le fichier,
  même les services d'un profil inactif. Vérifié le 4 octobre 2026 avec un `.env` limité aux trois variables
  PostgreSQL :
  - `${BOOKS_RAW_DIR}` en syntaxe courte : fichier invalide, toute commande Compose échoue (sauvegarde comprise) ;
  - `${BOOKS_RAW_DIR:?}` : même échec ;
  - source vide en syntaxe longue : Compose monte le dossier du dépôt à la place, ce qui est dangereux.

  Retenu : syntaxe longue, valeur de repli inexistante au nom explicite (`/BOOKS_RAW_DIR-non-defini`)
  et `create_host_path: false`. Si la variable manque, seul le lancement du collecteur échoue, avec un message
  lisible. Docker ne crée jamais le dossier (il le créerait au nom de root, inaccessible à l'UID 1000).

## Prérequis avant la première collecte en production

- **Rôle PostgreSQL dédié au collecteur**, à créer par une migration :
  - droits `SELECT` et `INSERT` sur les tables du schéma `raw` uniquement (`USAGE` sur le schéma), et rien d'autre ;
  - pour clore une tournée (décision 001), un privilège `UPDATE` **par colonne**, limité aux colonnes de clôture
    de `raw.collect_run` :
    `GRANT UPDATE (finished_at, status, pages_ok, pages_failed, notes) ON raw.collect_run TO …` ;
    `id`, `started_at` et `collector_version` restent non modifiables. Aucun `UPDATE` sur toute la table.
    Ce privilège est la seule protection de `collect_run` : la migration 001 ne pose aucun déclencheur
    sur cette table (ses deux déclencheurs ne visent que `raw.raw_page`) ;
  - aucun `UPDATE`, `DELETE` ni `TRUNCATE` sur `raw.raw_page` ;
  - **non propriétaire** des tables : le propriétaire d'une table peut désactiver ses déclencheurs
    (`ALTER TABLE … DISABLE TRIGGER`) et donc contourner la protection append-only de `raw.raw_page`.

  À ce stade, le collecteur utilise le compte propriétaire défini dans `.env` ; c'est acceptable
  tant qu'il ne fait qu'afficher la version de PostgreSQL.
- Le dossier `~/books-data/raw` doit exister sur atlas avant le premier lancement (voir README).

## Conséquences

- Le même code et la même image tournent en développement et en production ; seul `.env` change.
- Une variable manquante arrête le collecteur immédiatement, au lieu d'une collecte mal configurée.
- Les tests Python tournent dans un conteneur `python:3.12-slim` jetable : rien à installer sur le PC.
- Après un `git pull` sur atlas, le `.env` doit être complété (`BOOKS_ENV`, `BOOKS_RAW_DIR`) avant de lancer
  le collecteur ; en attendant, PostgreSQL et la sauvegarde continuent de fonctionner.
