#!/usr/bin/env bash
# Tests de scripts/recevoir-captures.sh, autovérifiés (code de sortie 0 = tout est conforme).
# À lancer dans un conteneur Linux jetable, le dépôt monté en lecture seule sur /src :
#   docker run --rm -v "<dépôt>:/src:ro" debian:bookworm-slim bash /src/tests/shell/test_recevoir_captures.sh
# Le collecteur est remplacé par tests/shell/faux-docker ; aucune base de données n'est utilisée.
set -uo pipefail

SCRIPT=/src/scripts/recevoir-captures.sh
LOT=2026-10-07T170000Z
STEM=amazon_fr_bestsellers_10000000001_paid_p1_2026-10-07T165900Z
FAILURES=0
BIN="$(mktemp -d)"
cp /src/tests/shell/faux-docker "$BIN/docker" && chmod +x "$BIN/docker"
export PATH="$BIN:$PATH"

ok()   { echo "OK   $1"; }
ko()   { echo "ÉCHEC $1"; FAILURES=$((FAILURES + 1)); }
check() { if eval "$2"; then ok "$1"; else ko "$1"; fi; }

new_home() {
    # Dossier personnel vierge, avec la disposition d'atlas
    export HOME="$(mktemp -d)"
    mkdir -p "$HOME/books" "$HOME/books-data/captures/attente" "$HOME/books-data/captures/inbox" \
             "$HOME/books-data/captures/quarantaine"
}

new_payload() {
    # Captures de test (octets quelconques, y compris un retour chariot) et leur manifeste
    PAYLOAD="$(mktemp -d)"
    printf '<!DOCTYPE html><html>\r\nexemple\n</html>' > "$PAYLOAD/$STEM.html"
    printf '{"schema_version": 1}\n' > "$PAYLOAD/$STEM.json"
    (cd "$PAYLOAD" && sha256sum "$STEM.html" "$STEM.json" > MANIFEST.sha256)
}

archive() { (cd "$PAYLOAD" && tar --format=ustar -cf - "$@"); }

run() {
    # Lance la réception avec l'archive sur l'entrée standard ; OUT = sortie, RC = code
    OUT="$(bash "$SCRIPT" "$1" 2>&1)"
    RC=$?
}

# 1. Lot valide, ingestion sans anomalie
new_home; new_payload
OUT="$(archive MANIFEST.sha256 "$STEM.html" "$STEM.json" | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
check "lot valide : code 0" '[[ $RC -eq 0 ]]'
check "lot valide : repère TRANSFERT:OK" 'grep -q "^BOOKS:TRANSFERT:OK $LOT 2$" <<<"$OUT"'
check "lot valide : repère INGESTION:CODE 0" 'grep -q "^BOOKS:INGESTION:CODE 0$" <<<"$OUT"'
check "lot valide : octets reçus identiques" \
    'cmp -s "$PAYLOAD/$STEM.html" "$HOME/recues/$LOT/$STEM.html" && cmp -s "$PAYLOAD/$STEM.json" "$HOME/recues/$LOT/$STEM.json"'
check "lot valide : manifeste retiré" '[[ ! -e "$HOME/recues/$LOT/MANIFEST.sha256" ]]'
check "lot valide : attente/ vide" '[[ -z "$(ls -A "$HOME/books-data/captures/attente")" ]]'
check "lot valide : droits 700 sur le lot, 600 sur les fichiers" \
    '[[ "$(stat -c %a "$HOME/recues/$LOT")" == 700 && "$(stat -c %a "$HOME/recues/$LOT/$STEM.html")" == 600 ]]'

# 2. Transfert réussi, ingestion avec anomalies
new_home; new_payload; echo 1 > "$HOME/code-ingestion"
OUT="$(archive MANIFEST.sha256 "$STEM.html" "$STEM.json" | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
check "anomalies : code 1" '[[ $RC -eq 1 ]]'
check "anomalies : transfert réussi quand même" 'grep -q "^BOOKS:TRANSFERT:OK $LOT 2$" <<<"$OUT"'
check "anomalies : repère INGESTION:CODE 1" 'grep -q "^BOOKS:INGESTION:CODE 1$" <<<"$OUT"'

# Échecs de transfert : code 3, jamais de repère TRANSFERT:OK, rien dans inbox/, ingestion non lancée
failure() {  # $1 = libellé, $2 = message attendu, $3 = lot laissé dans attente/ (oui/non)
    EXPECTED="$2"  # variable globale : l'expression est évaluée dans check, où $2 serait l'expression elle-même
    check "$1 : code 3" '[[ $RC -eq 3 ]]'
    check "$1 : message" 'grep -q "^BOOKS:TRANSFERT:ECHEC .*$EXPECTED" <<<"$OUT"'
    check "$1 : aucun repère TRANSFERT:OK ni ingestion" \
        '! grep -q "BOOKS:TRANSFERT:OK\|BOOKS:INGESTION" <<<"$OUT" && [[ ! -e "$HOME/recues" ]]'
    check "$1 : inbox/ vide" '[[ -z "$(ls -A "$HOME/books-data/captures/inbox")" ]]'
    if [[ "$3" == oui ]]; then
        check "$1 : lot laissé dans attente/" '[[ -d "$HOME/books-data/captures/attente/$LOT" ]]'
    fi
}

new_home; new_payload; printf 'x' >> "$PAYLOAD/$STEM.html"   # modifié après le calcul du manifeste
OUT="$(archive MANIFEST.sha256 "$STEM.html" "$STEM.json" | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
failure "empreinte fausse" "empreinte SHA-256 différente" oui

new_home; new_payload; echo x > "$PAYLOAD/intrus.txt"
OUT="$(archive MANIFEST.sha256 "$STEM.html" "$STEM.json" intrus.txt | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
failure "fichier en trop" "fichiers reçus différents" oui

new_home; new_payload
OUT="$(archive MANIFEST.sha256 "$STEM.html" | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
failure "fichier manquant" "fichiers reçus différents" oui

new_home; new_payload
OUT="$(archive "$STEM.html" "$STEM.json" | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
failure "manifeste absent" "MANIFEST.sha256 absent" oui

new_home; new_payload; mkdir "$PAYLOAD/sous-dossier"
OUT="$(archive MANIFEST.sha256 "$STEM.html" "$STEM.json" sous-dossier | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
failure "sous-dossier dans l'archive" "pas un fichier ordinaire" oui

new_home; new_payload
OUT="$( (cd "$PAYLOAD" && tar --format=ustar -cf - MANIFEST.sha256 "$STEM.html" "$STEM.json" \
        --transform 's,^MANIFEST,../MANIFEST,') | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
failure "membre avec .." "archive illisible ou refusée" oui
check "membre avec .. : rien écrit hors du lot" '[[ ! -e "$HOME/books-data/captures/attente/MANIFEST.sha256" ]]'

new_home
OUT="$(echo "pas une archive" | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
failure "entrée qui n'est pas une archive" "archive illisible ou refusée" oui

new_home; new_payload
OUT="$(archive MANIFEST.sha256 "$STEM.html" "$STEM.json" | bash "$SCRIPT" '2026-10-07T170000Z; touch ~/pirate' 2>&1)"; RC=$?
failure "nom de lot invalide" "nom de lot invalide" non
check "nom de lot invalide : rien d'exécuté ni créé" \
    '[[ ! -e "$HOME/pirate" && -z "$(ls -A "$HOME/books-data/captures/attente")" ]]'

new_home; new_payload; mkdir "$HOME/books-data/captures/inbox/$LOT"; touch "$HOME/books-data/captures/inbox/$LOT/existant"
OUT="$(archive MANIFEST.sha256 "$STEM.html" "$STEM.json" | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
check "lot déjà présent : code 3" '[[ $RC -eq 3 ]]'
check "lot déjà présent : message" 'grep -q "déjà présent" <<<"$OUT"'
check "lot déjà présent : contenu existant intact" '[[ "$(ls "$HOME/books-data/captures/inbox/$LOT")" == existant ]]'

new_home; rmdir "$HOME/books-data/captures/inbox"; new_payload
OUT="$(archive MANIFEST.sha256 "$STEM.html" "$STEM.json" | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
check "inbox/ absent : code 3" '[[ $RC -eq 3 ]]'
check "inbox/ absent : message" 'grep -q "dossiers attente/ ou inbox/ absents" <<<"$OUT"'

echo "---"
if [[ $FAILURES -eq 0 ]]; then echo "Tous les tests sont conformes."; else echo "$FAILURES échec(s)."; fi
exit $(( FAILURES > 0 ))
