#!/usr/bin/env bash
# Export d'une sauvegarde neuve de la base, pour sa copie hors d'atlas (décision 009).
#
# Appelé par scripts/rapatrier-sauvegarde.ps1 depuis le PC, dans une seule connexion SSH :
#   ssh atlas bash books/scripts/exporter-sauvegarde.sh > sauvegarde.tar
# 1. pg_dump neuf (format custom), même commande que scripts/backup.sh, dans un dossier temporaire.
# 2. Contrôles : dump non vide, commençant par la signature du format custom (PGDMP).
# 3. Manifeste MANIFEST.sha256 (format de sha256sum), puis archive tar (dump + manifeste) sur la sortie standard.
# La sortie standard ne porte QUE l'archive : tout autre message part sur la sortie d'erreur.
# Code de sortie non nul au moindre échec ; le dossier temporaire est supprimé dans tous les cas.
set -euo pipefail
umask 077

# Sortie standard réservée à l'archive : elle est mise de côté sur le descripteur 3, et la sortie standard
# est redirigée vers la sortie d'erreur pour tout le reste du script (messages, outils bavards).
exec 3>&1 1>&2

PROJECT_DIR="$HOME/books"
TIMESTAMP=$(date -u +%Y-%m-%dT%H-%M-%SZ)
NAME="books_$TIMESTAMP.dump"
TMP_DIR=""

cleanup() {
    if [[ -n "$TMP_DIR" ]]; then rm -rf -- "$TMP_DIR"; fi
}
trap cleanup EXIT
# Interruption (connexion coupée, Ctrl+C) : sortie avec un code non nul, qui déclenche le nettoyage
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    echo "Export échoué : $*"
    exit 1
}

TMP_DIR="$(mktemp -d)"
cd "$PROJECT_DIR" || fail "dossier du projet absent : $PROJECT_DIR"

# 1. Sauvegarde neuve ; l'entrée standard est fermée : rien ne doit lire la connexion SSH
docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
    < /dev/null > "$TMP_DIR/$NAME" || fail "pg_dump a échoué"

# 2. Contrôles du dump
[[ -s "$TMP_DIR/$NAME" ]] || fail "sauvegarde vide"
[[ "$(head -c 5 "$TMP_DIR/$NAME" | tr -d '\0')" == PGDMP ]] || fail "le fichier produit n'est pas une sauvegarde pg_dump -Fc"

# 3. Manifeste, puis archive sur la sortie standard mise de côté
cd "$TMP_DIR"
sha256sum "$NAME" > MANIFEST.sha256
SIZE=$(stat -c %s "$NAME")
tar --format=ustar -c -f - MANIFEST.sha256 "$NAME" >&3 || fail "écriture de l'archive interrompue"

echo "Export OK : $NAME, $SIZE octets, SHA-256 $(cut -c 1-64 MANIFEST.sha256)"
