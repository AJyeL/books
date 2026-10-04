#!/usr/bin/env bash
# Sauvegarde quotidienne de B.O.O.K.S. : base PostgreSQL et fichiers bruts
set -euo pipefail
umask 077

PROJECT_DIR="$HOME/books"
BACKUP_ROOT="$HOME/books-backup"
PG_BACKUP_DIR="$BACKUP_ROOT/postgres"
RAW_SOURCE_DIR="$HOME/books-data/raw"
RAW_BACKUP_DIR="$BACKUP_ROOT/raw"
KEEP=14
TIMESTAMP=$(date -u +%Y-%m-%dT%H-%M-%SZ)
FILE="$PG_BACKUP_DIR/books_$TIMESTAMP.dump"

mkdir -p "$PG_BACKUP_DIR" "$RAW_SOURCE_DIR" "$RAW_BACKUP_DIR"
cd "$PROJECT_DIR"

# 1. Sauvegarde de la base dans un fichier temporaire
docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$FILE.tmp"

# 2. Renommage seulement si tout s'est bien passé
mv "$FILE.tmp" "$FILE"

# 3. On garde les 14 sauvegardes de la base les plus récentes
ls -1t "$PG_BACKUP_DIR"/books_*.dump | tail -n +$((KEEP + 1)) | xargs -r rm --

# 4. Copie des nouveaux fichiers bruts : rien n'est jamais écrasé ni supprimé dans la sauvegarde
COPIED=$(rsync -a --ignore-existing --out-format='%n' "$RAW_SOURCE_DIR/" "$RAW_BACKUP_DIR/")
NEW_FILES=$(printf '%s\n' "$COPIED" | grep -c -v -e '/$' -e '^$' || true)

echo "$(date -u +%FT%TZ) Sauvegarde OK : $(basename "$FILE"), $NEW_FILES fichier(s) brut(s) copié(s)"
