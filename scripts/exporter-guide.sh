#!/usr/bin/env bash
# Export du guide de veille (décision 017, sections 4 et 5), pour l'extension.
#
# Appelé par scripts/recevoir-guide.ps1 depuis le PC, dans une seule connexion SSH :
#   ssh atlas bash books/scripts/exporter-guide.sh > guide.tar
# 1. Lecture de guide.export_document sous books_reader (lecture seule, connexion locale du conteneur, décision 016),
#    dans un dossier temporaire.
# 2. Contrôles : une seule ligne, document du format version 1 (début attendu), date d'export lisible ; le fichier
#    est nommé guide_{AAAA-MM-JJ}T{HHMMSS}Z.json d'après cette date. Le format complet est contrôlé sur le PC.
# 3. Manifeste MANIFEST.sha256 (format de sha256sum), puis archive tar (document + manifeste) sur la sortie standard.
# La sortie standard ne porte QUE l'archive : tout autre message part sur la sortie d'erreur.
# Aucun fichier durable n'est créé sur atlas : le dossier temporaire est supprimé dans tous les cas.
# Code de sortie non nul au moindre échec.
set -euo pipefail
umask 077

# Sortie standard réservée à l'archive : elle est mise de côté sur le descripteur 3, et la sortie standard
# est redirigée vers la sortie d'erreur pour tout le reste du script (messages, outils bavards).
exec 3>&1 1>&2

PROJECT_DIR="$HOME/books"
TMP_DIR=""
# Début du document produit par PostgreSQL (json_build_object), avec la date d'export
START_RE='^\{"schema_version" ?: ?1, ?"generated_at" ?: ?"([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z",'

cleanup() {
    if [[ -n "$TMP_DIR" ]]; then rm -rf -- "$TMP_DIR"; fi
}
trap cleanup EXIT
# Interruption (connexion coupée, Ctrl+C) : sortie avec un code non nul, qui déclenche le nettoyage
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    echo "Export du guide échoué : $*"
    exit 1
}

TMP_DIR="$(mktemp -d)"
cd "$PROJECT_DIR" || fail "dossier du projet absent : $PROJECT_DIR"

# 1. Lecture sous books_reader ; l'entrée standard est fermée : rien ne doit lire la connexion SSH
docker compose exec -T postgres sh -c \
    'psql -X -At -v ON_ERROR_STOP=1 -U books_reader -d "$POSTGRES_DB" -c "SELECT document FROM guide.export_document"' \
    < /dev/null > "$TMP_DIR/document.json" || fail "lecture de guide.export_document échouée"

# 2. Contrôles et nom
[[ -s "$TMP_DIR/document.json" ]] || fail "document vide"
[[ "$(wc -l < "$TMP_DIR/document.json")" -eq 1 ]] || fail "le document doit tenir sur une seule ligne"
FIRST="$(head -c 200 "$TMP_DIR/document.json")"
[[ "$FIRST" =~ $START_RE ]] || fail "début du document inattendu (format version 1 et date d'export attendus)"
NAME="guide_${BASH_REMATCH[1]}T${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}Z.json"
mv "$TMP_DIR/document.json" "$TMP_DIR/$NAME"

# 3. Manifeste, puis archive sur la sortie standard mise de côté
cd "$TMP_DIR"
sha256sum "$NAME" > MANIFEST.sha256
SIZE=$(stat -c %s "$NAME")
tar --format=ustar -c -f - MANIFEST.sha256 "$NAME" >&3 || fail "écriture de l'archive interrompue"

echo "Export du guide OK : $NAME, $SIZE octets, SHA-256 $(cut -c 1-64 MANIFEST.sha256)"
