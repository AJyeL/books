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

## Tests

Tests Python, dans un conteneur jetable (le dépôt est monté en lecture seule) :

```bash
docker run --rm -v "${PWD}:/src:ro" python:3.12-slim sh -c 'cp -r /src /tmp/w && cd /tmp/w && pip install -q --root-user-action=ignore ".[dev]" && pytest -v'
```

Tests SQL : voir l'en-tête de `tests/sql/test_001_couche_raw.sql`.

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

## Licence

© 2026 AJyeL — Tous droits réservés.
Ce code est publié à titre de démonstration (portfolio). Aucune licence de réutilisation n'est accordée.
