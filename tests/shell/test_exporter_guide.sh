#!/usr/bin/env bash
# Tests de scripts/exporter-guide.sh (décision 017), autovérifiés (code de sortie 0 = tout est conforme).
# À lancer dans un conteneur Linux jetable, le dépôt monté en lecture seule sur /src :
#   docker run --rm -v "<dépôt>:/src:ro" debian:bookworm-slim bash /src/tests/shell/test_exporter_guide.sh
# PostgreSQL est remplacé par tests/shell/faux-docker ; aucune base de données n'est utilisée. Valeurs inventées.
# Variable facultative SCRIPT : version du script à tester (contre-épreuves).
set -uo pipefail

SCRIPT="${SCRIPT:-/src/scripts/exporter-guide.sh}"
NAME=guide_2026-10-11T180000Z.json
FAILURES=0
BIN="$(mktemp -d)"
cp /src/tests/shell/faux-docker "$BIN/docker" && chmod +x "$BIN/docker"
export PATH="$BIN:$PATH"

ok()   { echo "OK   $1"; }
ko()   { echo "ÉCHEC $1"; FAILURES=$((FAILURES + 1)); }
check() { if eval "$2"; then ok "$1"; else ko "$1"; fi; }

new_home() {
    # Dossier personnel vierge avec le dépôt, dossier temporaire propre (pour vérifier le nettoyage),
    # et repère de date pour vérifier qu'aucun fichier n'est créé sur « atlas »
    export HOME="$(mktemp -d)"
    mkdir -p "$HOME/books"
    export TMPDIR="$(mktemp -d)"
    MARK="$(mktemp -p /tmp)"
    sleep 1
}

run() {
    # Sortie standard dans OUT_FILE (octets exacts), sortie d'erreur dans ERR, code dans RC
    OUT_FILE="$(mktemp -p /tmp)"  # hors de TMPDIR et de HOME, dont on vérifie qu'ils restent propres
    ERR="$(bash "$SCRIPT" 2>&1 >"$OUT_FILE")"
    RC=$?
}

no_file_left() {
    # Aucun fichier durable : dossier temporaire vide, aucun fichier créé ou modifié dans le dossier personnel
    [[ -z "$(ls -A "$TMPDIR")" && -z "$(find "$HOME" -newer "$MARK" -type f ! -name 'faux-guide' ! -name 'code-guide')" ]]
}

# 1. Export réussi : document de l'exemple du contrat, mis sur une ligne (forme de la sortie de psql -At)
new_home
tr -d '\n' < /src/tests/fixtures/guide_exemple.json > "$HOME/faux-guide"; echo >> "$HOME/faux-guide"
run
X="$(mktemp -d -p /tmp)"; tar -x -f "$OUT_FILE" -C "$X" 2>/dev/null
MEMBERS="$(tar -t -f "$OUT_FILE" 2>/dev/null | LC_ALL=C sort)"
check "réussite : code 0" '[[ $RC -eq 0 ]]'
check "réussite : sortie standard = archive tar de deux fichiers (manifeste et $NAME)" \
    '[[ "$MEMBERS" == "MANIFEST.sha256"$'"'"'\n'"'"'"$NAME" ]]'
check "réussite : document identique à la sortie de PostgreSQL, octet par octet" 'cmp -s "$HOME/faux-guide" "$X/$NAME"'
check "réussite : manifeste d'une ligne, empreinte exacte" \
    '[[ $(wc -l < "$X/MANIFEST.sha256") -eq 1 ]] && (cd "$X" && sha256sum --check --strict --quiet MANIFEST.sha256)'
check "réussite : message sur la sortie d'erreur" 'grep -q "^Export du guide OK : $NAME" <<<"$ERR"'
check "réussite : aucun message dans la sortie standard" '! grep -aq "Export" "$OUT_FILE"'
check "réussite : aucun fichier laissé sur atlas" 'no_file_left'

# 2. Forme exacte de json_build_object (espaces autour des deux-points), nom tiré de generated_at
new_home
echo '{"schema_version" : 1, "generated_at" : "2026-01-02T03:04:05Z", "lists" : [], "kindle_asins" : []}' > "$HOME/faux-guide"
run
check "forme de json_build_object : code 0, nom d'après generated_at" \
    '[[ $RC -eq 0 && "$(tar -t -f "$OUT_FILE" 2>/dev/null | LC_ALL=C sort | tail -1)" == guide_2026-01-02T030405Z.json ]]'

# Échecs : code non nul, sortie standard vide, aucun fichier laissé
failure() {  # $1 = libellé, $2 = message attendu
    EXPECTED="$2"  # variable globale : l'expression est évaluée dans check, où $2 serait l'expression elle-même
    check "$1 : code non nul" '[[ $RC -ne 0 ]]'
    check "$1 : sortie standard vide" '[[ ! -s "$OUT_FILE" ]]'
    check "$1 : message" 'grep -q "Export du guide échoué : .*$EXPECTED" <<<"$ERR"'
    check "$1 : aucun fichier laissé sur atlas" 'no_file_left'
}

new_home; echo 1 > "$HOME/code-guide"
run
failure "lecture en échec" "lecture de guide.export_document échouée"
check "lecture en échec : erreur de l'outil visible" 'grep -q "erreur simulée" <<<"$ERR"'

new_home; : > "$HOME/faux-guide"
run
failure "document vide" "document vide"

new_home; printf '%s\n%s\n' '{"schema_version" : 1, "generated_at" : "2026-10-11T18:00:00Z", "lists" : [], "kindle_asins" : []}' \
    '{"schema_version" : 1, "generated_at" : "2026-10-11T18:00:00Z", "lists" : [], "kindle_asins" : []}' > "$HOME/faux-guide"
run
failure "deux lignes (deux documents)" "une seule ligne"

new_home; echo '{"schema_version" : 2, "generated_at" : "2026-10-11T18:00:00Z", "lists" : [], "kindle_asins" : []}' > "$HOME/faux-guide"
run
failure "version 2" "début du document inattendu"

new_home; echo '{"schema_version" : 1, "generated_at" : "2026-10-11 18:00:00", "lists" : [], "kindle_asins" : []}' > "$HOME/faux-guide"
run
failure "date d'export mal formée" "début du document inattendu"

new_home; echo 'ERROR:  permission denied for schema guide' > "$HOME/faux-guide"
run
failure "sortie qui n'est pas un document" "début du document inattendu"

new_home; rmdir "$HOME/books"
run
failure "dossier du projet absent" "dossier du projet absent"

echo "---"
if [[ $FAILURES -eq 0 ]]; then echo "Tous les tests sont conformes."; else echo "$FAILURES échec(s)."; fi
exit $(( FAILURES > 0 ))
