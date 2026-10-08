#!/usr/bin/env bash
# Tests de scripts/exporter-sauvegarde.sh, autovérifiés (code de sortie 0 = tout est conforme).
# À lancer dans un conteneur Linux jetable, le dépôt monté en lecture seule sur /src :
#   docker run --rm -v "<dépôt>:/src:ro" debian:bookworm-slim bash /src/tests/shell/test_exporter_sauvegarde.sh
# PostgreSQL est remplacé par tests/shell/faux-docker ; aucune base de données n'est utilisée.
set -uo pipefail

SCRIPT=/src/scripts/exporter-sauvegarde.sh
NAME_RE='^books_[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z\.dump$'
FAILURES=0
BIN="$(mktemp -d)"
cp /src/tests/shell/faux-docker "$BIN/docker" && chmod +x "$BIN/docker"
export PATH="$BIN:$PATH"

ok()   { echo "OK   $1"; }
ko()   { echo "ÉCHEC $1"; FAILURES=$((FAILURES + 1)); }
check() { if eval "$2"; then ok "$1"; else ko "$1"; fi; }

new_home() {
    # Dossier personnel vierge avec le dépôt, et dossier temporaire propre (pour vérifier le nettoyage)
    export HOME="$(mktemp -d)"
    mkdir -p "$HOME/books"
    export TMPDIR="$(mktemp -d)"
}

run() {
    # Sortie standard dans OUT_FILE (octets exacts), sortie d'erreur dans ERR, code dans RC
    OUT_FILE="$(mktemp -p /tmp)"  # hors de TMPDIR, dont on vérifie qu'il reste vide
    ERR="$(bash "$SCRIPT" 2>&1 >"$OUT_FILE")"
    RC=$?
}

# 1. Export réussi, avec un faux dump contenant les 256 valeurs d'octets
new_home
{ printf 'PGDMP'; for i in $(seq 0 255); do printf "\\$(printf %03o "$i")"; done; printf '\r\n\032'; } > "$HOME/faux-dump"
run
X="$(mktemp -d -p /tmp)"; tar -x -f "$OUT_FILE" -C "$X" 2>/dev/null
MEMBERS="$(tar -t -f "$OUT_FILE" 2>/dev/null | LC_ALL=C sort)"
DUMP="$(grep -E "$NAME_RE" <<<"$MEMBERS")"
check "réussite : code 0" '[[ $RC -eq 0 ]]'
check "réussite : sortie standard = archive tar de deux fichiers (manifeste et dump au nom attendu)" \
    '[[ $(wc -l <<<"$MEMBERS") -eq 2 && -n "$DUMP" && "$MEMBERS" == *MANIFEST.sha256* ]]'
check "réussite : dump identique au faux dump, octet par octet" 'cmp -s "$HOME/faux-dump" "$X/$DUMP"'
check "réussite : manifeste d'une ligne, empreinte exacte" \
    '[[ $(wc -l < "$X/MANIFEST.sha256") -eq 1 ]] && (cd "$X" && sha256sum --check --strict --quiet MANIFEST.sha256)'
check "réussite : message sur la sortie d'erreur" 'grep -q "^Export OK : $DUMP" <<<"$ERR"'
check "réussite : aucun message dans la sortie standard" '! grep -aq "Export" "$OUT_FILE"'
check "réussite : dossier temporaire supprimé" '[[ -z "$(ls -A "$TMPDIR")" ]]'

# Échecs : code non nul, sortie standard vide, dossier temporaire supprimé
failure() {  # $1 = libellé, $2 = message attendu
    EXPECTED="$2"  # variable globale : l'expression est évaluée dans check, où $2 serait l'expression elle-même
    check "$1 : code non nul" '[[ $RC -ne 0 ]]'
    check "$1 : sortie standard vide" '[[ ! -s "$OUT_FILE" ]]'
    check "$1 : message" 'grep -q "Export échoué : .*$EXPECTED" <<<"$ERR"'
    check "$1 : dossier temporaire supprimé" '[[ -z "$(ls -A "$TMPDIR")" ]]'
}

new_home; echo 1 > "$HOME/code-pg-dump"
run
failure "pg_dump en échec" "pg_dump a échoué"
check "pg_dump en échec : erreur de l'outil visible" 'grep -q "erreur simulée" <<<"$ERR"'

new_home; : > "$HOME/faux-dump"
run
failure "dump vide" "sauvegarde vide"

new_home; printf 'pg_dump: error: connection failed\n' > "$HOME/faux-dump"
run
failure "dump sans signature PGDMP" "pas une sauvegarde pg_dump"

new_home; rmdir "$HOME/books"
run
failure "dossier du projet absent" "dossier du projet absent"

echo "---"
if [[ $FAILURES -eq 0 ]]; then echo "Tous les tests sont conformes."; else echo "$FAILURES échec(s)."; fi
exit $(( FAILURES > 0 ))
