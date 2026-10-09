#!/usr/bin/env bash
# Suite Python complète, y compris les tests contre un PostgreSQL 17 jetable (extracteur, décision 011).
#
# Depuis le dossier du dépôt, Docker démarré (Git Bash sur le PC, ou bash sous Linux) :
#   bash tests/lancer-tests-postgres.sh            (arguments facultatifs transmis à pytest, ex. : -k extraction)
#
# 1. Réseau Docker et PostgreSQL 17 jetables, sans port publié : seul le conteneur des tests les joint.
# 2. Migrations 001 à 005 appliquées à la base modèle books_test_template ; mot de passe de TEST de books_transformer.
# 3. Suite Python dans un conteneur jetable relié à ce réseau ; chaque test de base de données travaille sur une copie
#    neuve de la base modèle (fixture « pg » de tests/python/conftest.py).
# 4. Tout est supprimé à la fin, même en cas d'échec. Aucune base de développement ou de production n'est touchée.
# Les mots de passe ci-dessous ne protègent que ces conteneurs jetables : ce ne sont pas des secrets.
set -euo pipefail
export MSYS_NO_PATHCONV=1  # Git Bash : chemins transmis tels quels à Docker

cd "$(dirname "$0")/.."
REPO="$(pwd -W 2>/dev/null || pwd)"  # chemin Windows sous Git Bash, chemin Unix ailleurs
NET=books-tests-net
PG=books-tests-pg
TEMPLATE=books_test_template

cleanup() {
    docker rm -f "$PG" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

docker network create "$NET" >/dev/null
docker run -d --name "$PG" --network "$NET" \
    -e POSTGRES_USER=proprio -e POSTGRES_PASSWORD=proprio-test -e POSTGRES_DB="$TEMPLATE" postgres:17 >/dev/null
# -h 127.0.0.1 : le serveur provisoire de l'initialisation n'écoute pas en TCP ; on attend le serveur définitif
for _ in $(seq 1 60); do
    docker exec "$PG" pg_isready -q -h 127.0.0.1 -U proprio -d "$TEMPLATE" && break
    sleep 1
done
docker exec "$PG" pg_isready -q -h 127.0.0.1 -U proprio -d "$TEMPLATE"

for migration in sql/migrations/*.sql; do
    docker exec -i "$PG" psql -X -q -v ON_ERROR_STOP=1 -U proprio -d "$TEMPLATE" < "$migration" >/dev/null
done
docker exec "$PG" psql -X -q -v ON_ERROR_STOP=1 -U proprio -d "$TEMPLATE" \
    -c "ALTER ROLE books_transformer PASSWORD 'transformer-test'" >/dev/null
echo "PostgreSQL 17 jetable prêt : migrations $(docker exec "$PG" psql -X -At -U proprio -d "$TEMPLATE" \
    -c "SELECT string_agg(version::text, ' ' ORDER BY version) FROM public.schema_migration")"

docker run --rm --network "$NET" -v "$REPO:/src:ro" \
    -e BOOKS_TEST_PG_HOST="$PG" -e BOOKS_TEST_PG_PORT=5432 -e BOOKS_TEST_PG_TEMPLATE="$TEMPLATE" \
    -e BOOKS_TEST_PG_OWNER=proprio -e BOOKS_TEST_PG_OWNER_PASSWORD=proprio-test \
    -e BOOKS_TEST_PG_TRANSFORMER_PASSWORD=transformer-test \
    -e PIP_DISABLE_PIP_VERSION_CHECK=1 python:3.12-slim sh -c 'cp -r /src /tmp/w && cd /tmp/w \
        && pip install -q --root-user-action=ignore ".[dev]" && pytest -q -rfEs "$@"' sh "$@"
