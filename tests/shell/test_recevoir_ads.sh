#!/usr/bin/env bash
# Tests de scripts/recevoir-ads.sh (décision 018, lots A et B), autovérifiés (code de sortie 0 = tout est conforme).
# À lancer dans un conteneur Linux jetable, le dépôt monté en lecture seule sur /src :
#   docker run --rm -v "<dépôt>:/src:ro" debian:bookworm-slim bash /src/tests/shell/test_recevoir_ads.sh
# L'ingestion et l'extraction sont remplacées par tests/shell/faux-docker ; aucune base de données n'est utilisée.
set -uo pipefail

SCRIPT=/src/scripts/recevoir-ads.sh
LOT=2026-12-05T201500Z
AP=Advertised_product_-_12_05_2026T19_59_56.csv
ST=Search_term_-_12_05_2026T20_05_45.csv
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
    mkdir -p "$HOME/books" "$HOME/books-data/ads/attente" "$HOME/books-data/ads/inbox"
}

new_payload() {
    # Les deux rapports inventés des tests (BOM, CRLF) et leur manifeste
    PAYLOAD="$(mktemp -d)"
    cp "/src/tests/fixtures/ads/$AP" "/src/tests/fixtures/ads/$ST" "$PAYLOAD/"
    chmod 644 "$PAYLOAD/$AP" "$PAYLOAD/$ST"  # le dépôt monté depuis Windows donne des droits 777, jamais envoyés ainsi
    (cd "$PAYLOAD" && sha256sum "$AP" "$ST" > MANIFEST.sha256)
}

archive() { (cd "$PAYLOAD" && tar --format=ustar -cf - "$@"); }

# 1. Lot valide, ingestion sans anomalie
new_home; new_payload
OUT="$(archive MANIFEST.sha256 "$AP" "$ST" | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
check "lot valide : code 0" '[[ $RC -eq 0 ]]'
check "lot valide : repère TRANSFERT:OK" 'grep -q "^BOOKS:TRANSFERT:OK $LOT 2$" <<<"$OUT"'
check "lot valide : repère INGESTION:CODE 0" 'grep -q "^BOOKS:INGESTION:CODE 0$" <<<"$OUT"'
check "lot valide : octets reçus identiques (BOM et CRLF compris)" \
    'cmp -s "$PAYLOAD/$AP" "$HOME/recues/$LOT/$AP" && cmp -s "$PAYLOAD/$ST" "$HOME/recues/$LOT/$ST"'
check "lot valide : manifeste retiré" '[[ ! -e "$HOME/recues/$LOT/MANIFEST.sha256" ]]'
check "lot valide : attente/ vide" '[[ -z "$(ls -A "$HOME/books-data/ads/attente")" ]]'
check "lot valide : droits 700 sur le lot, 600 sur les fichiers" \
    '[[ "$(stat -c %a "$HOME/recues/$LOT")" == 700 && "$(stat -c %a "$HOME/recues/$LOT/$AP")" == 600 ]]'
check "lot valide : ingestion puis extraction des rapports (lot B, décision 012)" \
    '[[ "$(cat "$HOME/appels")" == $'"'"'ingestion-ads\nextraction-ads'"'"' ]]'
check "lot valide : repère EXTRACTION:CODE 0, après celui de l'ingestion" \
    '[[ "$(grep -o "^BOOKS:[A-Z]*:CODE [0-9]*$" <<<"$OUT" | tr "\n" ";")" == "BOOKS:INGESTION:CODE 0;BOOKS:EXTRACTION:CODE 0;" ]]'
check "lot valide : bilans de l'ingestion et de l'extraction transmis" \
    'grep -q "Bilan factice de l.ingestion des rapports Ads : 2 fichier" <<<"$OUT" && grep -q "Bilan factice de l.extraction des rapports Ads" <<<"$OUT"'

# 2. Ingestion avec anomalies, puis mal configurée : extraction lancée quand même, le plus grave l'emporte
new_home; new_payload; echo 1 > "$HOME/code-ingestion"
OUT="$(archive MANIFEST.sha256 "$AP" "$ST" | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
check "anomalies : code 1, transfert réussi, repère INGESTION:CODE 1" \
    '[[ $RC -eq 1 ]] && grep -q "^BOOKS:TRANSFERT:OK $LOT 2$" <<<"$OUT" && grep -q "^BOOKS:INGESTION:CODE 1$" <<<"$OUT"'
check "anomalies : extraction lancée quand même" 'grep -q "^BOOKS:EXTRACTION:CODE 0$" <<<"$OUT" && grep -qx extraction-ads "$HOME/appels"'
new_home; new_payload; echo 2 > "$HOME/code-ingestion"
OUT="$(archive MANIFEST.sha256 "$AP" "$ST" | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
check "ingestion mal configurée : code 2, repère INGESTION:CODE 2, extraction lancée" \
    '[[ $RC -eq 2 ]] && grep -q "^BOOKS:INGESTION:CODE 2$" <<<"$OUT" && grep -q "^BOOKS:EXTRACTION:CODE 0$" <<<"$OUT"'

# 3. Extraction en échec ou mal configurée après une ingestion sans anomalie : le code remonte
new_home; new_payload; echo 1 > "$HOME/code-extraction"
OUT="$(archive MANIFEST.sha256 "$AP" "$ST" | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
check "extraction en échec : repères INGESTION 0 et EXTRACTION 1, code 1" \
    'grep -q "^BOOKS:INGESTION:CODE 0$" <<<"$OUT" && grep -q "^BOOKS:EXTRACTION:CODE 1$" <<<"$OUT" && [[ $RC -eq 1 ]]'
new_home; new_payload; echo 2 > "$HOME/code-extraction"
OUT="$(archive MANIFEST.sha256 "$AP" "$ST" | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
check "extraction mal configurée : repère EXTRACTION 2, code 2" 'grep -q "^BOOKS:EXTRACTION:CODE 2$" <<<"$OUT" && [[ $RC -eq 2 ]]'

# Échecs de transfert : code 3, jamais de repère TRANSFERT:OK, rien dans inbox/, ingestion non lancée
failure() {  # $1 = libellé, $2 = message attendu, $3 = lot laissé dans attente/ (oui/non)
    EXPECTED="$2"
    check "$1 : code 3" '[[ $RC -eq 3 ]]'
    check "$1 : message" 'grep -q "^BOOKS:TRANSFERT:ECHEC .*$EXPECTED" <<<"$OUT"'
    check "$1 : aucun repère TRANSFERT:OK, ni ingestion, ni extraction" \
        '! grep -q "BOOKS:TRANSFERT:OK\|BOOKS:INGESTION\|BOOKS:EXTRACTION" <<<"$OUT" && [[ ! -e "$HOME/recues" && ! -e "$HOME/appels" ]]'
    check "$1 : inbox/ vide" '[[ -z "$(ls -A "$HOME/books-data/ads/inbox")" ]]'
    if [[ "$3" == oui ]]; then
        check "$1 : lot laissé dans attente/" '[[ -d "$HOME/books-data/ads/attente/$LOT" ]]'
    fi
}

new_home; new_payload; printf 'x' >> "$PAYLOAD/$AP"   # modifié après le calcul du manifeste
OUT="$(archive MANIFEST.sha256 "$AP" "$ST" | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
failure "empreinte fausse" "empreinte SHA-256 différente" oui

new_home; new_payload; echo x > "$PAYLOAD/intrus.csv"
OUT="$(archive MANIFEST.sha256 "$AP" "$ST" intrus.csv | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
failure "fichier en trop" "fichiers reçus différents" oui

new_home; new_payload
OUT="$(archive MANIFEST.sha256 "$AP" | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
failure "fichier manquant" "fichiers reçus différents" oui

new_home; new_payload
OUT="$(archive "$AP" "$ST" | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
failure "manifeste absent" "MANIFEST.sha256 absent" oui

# Suffixe « (n) » d'un second téléchargement de même nom : admis (un rapport programmé garde son nom), octets intacts
new_home; new_payload; cp "$PAYLOAD/$ST" "$PAYLOAD/${ST%.csv} (1).csv"
(cd "$PAYLOAD" && sha256sum "$AP" "$ST" "${ST%.csv} (1).csv" > MANIFEST.sha256)
OUT="$(archive MANIFEST.sha256 "$AP" "$ST" "${ST%.csv} (1).csv" | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
check "suffixe « (1) » : admis, 3 fichiers transférés" '[[ $RC -eq 0 ]] && grep -q "^BOOKS:TRANSFERT:OK $LOT 3$" <<<"$OUT"'
check "suffixe « (1) » : octets reçus identiques" 'cmp -s "$PAYLOAD/${ST%.csv} (1).csv" "$HOME/recues/$LOT/${ST%.csv} (1).csv"'

# Noms hors format : suffixe mal formé, espace ailleurs, autre extension que .csv
for nom in "Search_term (1a).csv" "Search_term (1)(2).csv" "Search term.csv" "Search_term (1) b.csv"; do
    new_home; new_payload; mv "$PAYLOAD/$ST" "$PAYLOAD/$nom"
    (cd "$PAYLOAD" && sha256sum "$AP" "$nom" > MANIFEST.sha256)
    OUT="$(archive MANIFEST.sha256 "$AP" "$nom" | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
    failure "nom « $nom »" "nom de rapport hors format" oui
done

new_home; new_payload; mv "$PAYLOAD/$ST" "$PAYLOAD/rapport.txt"
(cd "$PAYLOAD" && sha256sum "$AP" rapport.txt > MANIFEST.sha256)
OUT="$(archive MANIFEST.sha256 "$AP" rapport.txt | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
failure "extension autre que .csv" "nom de rapport hors format" oui

new_home; new_payload; mkdir "$PAYLOAD/sous-dossier"
OUT="$(archive MANIFEST.sha256 "$AP" "$ST" sous-dossier | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
failure "sous-dossier dans l'archive" "pas un fichier ordinaire" oui

new_home; new_payload; ln -s "$AP" "$PAYLOAD/lien.csv"
OUT="$(archive MANIFEST.sha256 "$AP" "$ST" lien.csv | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
failure "lien symbolique dans l'archive" "pas un fichier ordinaire" oui

new_home; new_payload
OUT="$( (cd "$PAYLOAD" && tar --format=ustar -cf - MANIFEST.sha256 "$AP" "$ST" \
        --transform 's,^MANIFEST,../MANIFEST,') | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
failure "membre avec .." "archive illisible ou refusée" oui
check "membre avec .. : rien écrit hors du lot" '[[ ! -e "$HOME/books-data/ads/attente/MANIFEST.sha256" ]]'

new_home
OUT="$(echo "pas une archive" | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
failure "entrée qui n'est pas une archive" "archive illisible ou refusée" oui

new_home; new_payload
OUT="$(archive MANIFEST.sha256 "$AP" "$ST" | bash "$SCRIPT" '2026-12-05T201500Z; touch ~/pirate' 2>&1)"; RC=$?
failure "nom de lot invalide" "nom de lot invalide" non
check "nom de lot invalide : rien d'exécuté ni créé" \
    '[[ ! -e "$HOME/pirate" && -z "$(ls -A "$HOME/books-data/ads/attente")" ]]'

new_home; new_payload; mkdir "$HOME/books-data/ads/inbox/$LOT"; touch "$HOME/books-data/ads/inbox/$LOT/existant"
OUT="$(archive MANIFEST.sha256 "$AP" "$ST" | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
check "lot déjà présent : code 3" '[[ $RC -eq 3 ]]'
check "lot déjà présent : message" 'grep -q "déjà présent" <<<"$OUT"'
check "lot déjà présent : contenu existant intact" '[[ "$(ls "$HOME/books-data/ads/inbox/$LOT")" == existant ]]'

new_home; rmdir "$HOME/books-data/ads/inbox"; new_payload
OUT="$(archive MANIFEST.sha256 "$AP" "$ST" | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
check "inbox/ absent : code 3" '[[ $RC -eq 3 ]]'
check "inbox/ absent : message" 'grep -q "dossiers attente/ ou inbox/ absents" <<<"$OUT"'

# Les captures ne sont jamais touchées : le script ne connaît que ~/books-data/ads
new_home; mkdir -p "$HOME/books-data/captures/inbox/$LOT"; touch "$HOME/books-data/captures/inbox/$LOT/capture.html"
new_payload
OUT="$(archive MANIFEST.sha256 "$AP" "$ST" | bash "$SCRIPT" "$LOT" 2>&1)"; RC=$?
check "captures intactes" '[[ $RC -eq 0 && -f "$HOME/books-data/captures/inbox/$LOT/capture.html" ]]'

echo "---"
if [[ $FAILURES -eq 0 ]]; then echo "Tous les tests sont conformes."; else echo "$FAILURES échec(s)."; fi
exit $(( FAILURES > 0 ))
