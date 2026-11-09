#!/usr/bin/env bash
# Réception d'un lot de rapports Amazon Ads sur atlas (décision 018, lot A), sur le modèle de recevoir-captures.sh.
#
# Appelé par scripts/envoyer-ads.ps1 depuis le PC, dans une seule connexion SSH :
#   ssh atlas bash books/scripts/recevoir-ads.sh {lot} < archive.tar
# L'archive tar arrive sur l'entrée standard ; elle contient les rapports (.csv) et MANIFEST.sha256.
#
# 1. Déballage dans ~/books-data/ads/attente/{lot}/ ; contrôles : fichiers ordinaires seulement, noms .csv au jeu de
#    caractères strict (suffixe « (n) » admis), exactement ceux du manifeste, empreintes SHA-256 exactes. En cas
#    d'échec, le lot reste dans attente/.
# 2. Déplacement atomique (renommage) vers inbox/{lot}/, puis repère « BOOKS:TRANSFERT:OK {lot} {n} ».
# 3. Ingestion dans la même connexion (service ads), puis repère « BOOKS:INGESTION:CODE {code} ».
# 4. Extraction vers STAGING (service ads-transformer, lot B), quel que soit le résultat de l'ingestion
#    (décision 012), puis repère « BOOKS:EXTRACTION:CODE {code} ». Rien de tout cela si le lot n'a pas été reçu.
set -euo pipefail
umask 077

ADS_DIR="$HOME/books-data/ads"
PROJECT_DIR="$HOME/books"
LOT="${1:-}"

fail() {
    echo "BOOKS:TRANSFERT:ECHEC $*"
    exit 3
}

# Nom de lot strict : aucun autre texte n'est accepté (pas d'injection de commande ni de chemin)
[[ "$LOT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z$ ]] || fail "nom de lot invalide : '$LOT'"
[[ -d "$ADS_DIR/attente" && -d "$ADS_DIR/inbox" ]] || fail "dossiers attente/ ou inbox/ absents dans $ADS_DIR"
WAIT="$ADS_DIR/attente/$LOT"
DEST="$ADS_DIR/inbox/$LOT"
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
# Rapports seulement : noms en .csv, au jeu de caractères strict, avec au plus le suffixe « (n) » d'un second
# téléchargement de même nom (un rapport programmé garde le même nom à chaque livraison)
if grep -qvE '^[0-9a-f]{64}  [A-Za-z0-9_.-]+( \([0-9]+\))?\.csv$' MANIFEST.sha256; then
    fail "MANIFEST.sha256 mal formé ou nom de rapport hors format ; lot laissé dans attente/$LOT"
fi
expected="$(sed -E 's/^[0-9a-f]{64}  //' MANIFEST.sha256 | LC_ALL=C sort)"
received="$(find . -maxdepth 1 -type f ! -name MANIFEST.sha256 -printf '%f\n' | LC_ALL=C sort)"
[[ -n "$expected" && "$expected" == "$received" ]] \
    || fail "fichiers reçus différents de MANIFEST.sha256 ; lot laissé dans attente/$LOT"
sha256sum --check --strict --quiet MANIFEST.sha256 >&2 \
    || fail "empreinte SHA-256 différente ; lot laissé dans attente/$LOT"
count="$(wc -l < MANIFEST.sha256)"
rm MANIFEST.sha256

cd "$ADS_DIR"
[[ ! -e "$DEST" ]] || fail "lot $LOT apparu dans inbox/ pendant la réception"
# -T : le lot ne peut pas atterrir à l'intérieur d'un dossier homonyme ; renommage atomique
mv -T "attente/$LOT" "inbox/$LOT"
echo "BOOKS:TRANSFERT:OK $LOT $count"

# Ingestion, puis extraction, quel que soit le résultat de l'ingestion (décision 012) : l'extracteur est idempotent,
# verrouillé, ne lit que ce qui est enregistré dans raw.ads_report_file et signale lui-même ses erreurs.
# Leurs codes sont rapportés au PC, sans changer le sort du transfert ; le plus élevé devient le code de sortie.
set +e
cd "$PROJECT_DIR" && docker compose --profile ads run --rm -T ads < /dev/null
code=$?
echo "BOOKS:INGESTION:CODE $code"
cd "$PROJECT_DIR" && docker compose --profile ads-transformer run --rm -T ads-transformer < /dev/null
extraction=$?
echo "BOOKS:EXTRACTION:CODE $extraction"
set -e
exit $(( code > extraction ? code : extraction ))
