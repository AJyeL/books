#!/usr/bin/env bash
# Sauvegarde quotidienne de la base PostgreSQL de B.O.O.K.S.
set -euo pipefail
umask 077

PROJECT_DIR="$HOME/books"
BACKUP_DIR="$HOME/books-data/backups"
KEEP=14
TIMESTAMP=$(date -u +%Y-%m-%dT%H-%M-%SZ)
FILE="$BACKUP_DIR/books_$TIMESTAMP.dump"

mkdir -p "$BACKUP_DIR"
cd "$PROJECT_DIR"

# 1. Sauvegarde dans un fichier temporaire
docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$FILE.tmp"

# 2. Renommage seulement si tout s'est bien passé
mv "$FILE.tmp" "$FILE"

# 3. On garde les 14 sauvegardes les plus récentes
ls -1t "$BACKUP_DIR"/books_*.dump | tail -n +$((KEEP + 1)) | xargs -r rm --

echo "$(date -u +%FT%TZ) Sauvegarde OK : $(basename "$FILE")"
