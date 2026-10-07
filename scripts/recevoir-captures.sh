#!/usr/bin/env bash
# Réception d'un lot de captures sur atlas (décision 008, étape 5 du code).
#
# Appelé par scripts/envoyer-captures.ps1 depuis le PC, dans une seule connexion SSH :
#   ssh atlas bash books/scripts/recevoir-captures.sh {lot} < archive.tar
# L'archive tar arrive sur l'entrée standard ; elle contient les captures et MANIFEST.sha256.
#
# 1. Déballage dans ~/books-data/captures/attente/{lot}/ ; contrôles : fichiers ordinaires seulement,
#    exactement ceux du manifeste, empreintes SHA-256 exactes. En cas d'échec, le lot reste dans attente/.
# 2. Déplacement atomique (renommage) vers inbox/{lot}/, puis repère « BOOKS:TRANSFERT:OK {lot} {n} ».
# 3. Ingestion dans la même connexion (collecteur), puis repère « BOOKS:INGESTION:CODE {code} ».
# Le PC lit ces repères pour distinguer transfert échoué, ingestion sans anomalie, ingestion avec anomalies.
set -euo pipefail
umask 077

CAPTURES_DIR="$HOME/books-data/captures"
PROJECT_DIR="$HOME/books"
LOT="${1:-}"

fail() {
    echo "BOOKS:TRANSFERT:ECHEC $*"
    exit 3
}

# Nom de lot strict : aucun autre texte n'est accepté (pas d'injection de commande ni de chemin)
[[ "$LOT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z$ ]] || fail "nom de lot invalide : '$LOT'"
[[ -d "$CAPTURES_DIR/attente" && -d "$CAPTURES_DIR/inbox" ]] \
    || fail "dossiers attente/ ou inbox/ absents dans $CAPTURES_DIR"
WAIT="$CAPTURES_DIR/attente/$LOT"
DEST="$CAPTURES_DIR/inbox/$LOT"
[[ ! -e "$WAIT" && ! -e "$DEST" ]] || fail "lot $LOT déjà présent dans attente/ ou inbox/"

mkdir "$WAIT"
# GNU tar refuse les membres contenant « .. » et retire le « / » initial ; propriétaire et droits ignorés
tar -x -f - -C "$WAIT" --no-same-owner --no-same-permissions 2>&1 \
    || fail "archive illisible ou refusée ; lot laissé dans attente/$LOT"

cd "$WAIT"
[[ -f MANIFEST.sha256 ]] || fail "MANIFEST.sha256 absent ; lot laissé dans attente/$LOT"
if [[ -n "$(find . -mindepth 1 ! -type f -print -quit)" ]]; then
    fail "élément qui n'est pas un fichier ordinaire ; lot laissé dans attente/$LOT"
fi
if grep -qvE '^[0-9a-f]{64}  [A-Za-z0-9_.-]+$' MANIFEST.sha256; then
    fail "MANIFEST.sha256 mal formé ; lot laissé dans attente/$LOT"
fi
expected="$(sed -E 's/^[0-9a-f]{64}  //' MANIFEST.sha256 | LC_ALL=C sort)"
received="$(find . -maxdepth 1 -type f ! -name MANIFEST.sha256 -printf '%f\n' | LC_ALL=C sort)"
[[ -n "$expected" && "$expected" == "$received" ]] \
    || fail "fichiers reçus différents de MANIFEST.sha256 ; lot laissé dans attente/$LOT"
sha256sum --check --strict --quiet MANIFEST.sha256 >&2 \
    || fail "empreinte SHA-256 différente ; lot laissé dans attente/$LOT"
count="$(wc -l < MANIFEST.sha256)"
rm MANIFEST.sha256

cd "$CAPTURES_DIR"
[[ ! -e "$DEST" ]] || fail "lot $LOT apparu dans inbox/ pendant la réception"
# -T : le lot ne peut pas atterrir à l'intérieur d'un dossier homonyme ; renommage atomique
mv -T "attente/$LOT" "inbox/$LOT"
echo "BOOKS:TRANSFERT:OK $LOT $count"

# Ingestion : son code de sortie est rapporté au PC, sans changer le sort du transfert
set +e
cd "$PROJECT_DIR" && docker compose --profile collector run --rm -T collector < /dev/null
code=$?
set -e
echo "BOOKS:INGESTION:CODE $code"
exit "$code"
