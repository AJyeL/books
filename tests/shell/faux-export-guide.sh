#!/usr/bin/env bash
# Doublure de test : export du guide volontairement défectueux, à la place de scripts/exporter-guide.sh,
# pour vérifier que scripts/recevoir-guide.ps1 refuse ce qu'il reçoit (tests uniquement, valeurs inventées).
# Usage : bash faux-export-guide.sh {mode} > archive.tar
set -euo pipefail

MODE="${1:-}"
NAME=guide_2026-10-11T170000Z.json
DOC='{"schema_version": 1, "generated_at": "2026-10-11T17:00:00Z", "lists": [{"category_node": "10000000001", "list_type": "paid", "entries": [{"asin": "B0FAUX0001", "rank": 1, "observed_at": "2026-10-10T19:00:00Z"}]}], "kindle_asins": ["B0FAUX0001"]}'
W="$(mktemp -d)"
trap 'rm -rf -- "$W"' EXIT
cd "$W"

archive() {  # manifeste exact du document, puis archive des fichiers donnés
    sha256sum "$NAME" > MANIFEST.sha256
    tar --format=ustar -cf - MANIFEST.sha256 "$@"
}

printf '%s\n' "$DOC" > "$NAME"
case "$MODE" in
    valide)              # archive correcte, au nom fixe (test de collision)
        archive "$NAME" ;;
    empreinte-fausse)    # document modifié après le calcul du manifeste
        sha256sum "$NAME" > MANIFEST.sha256; printf ' ' >> "$NAME"
        tar --format=ustar -cf - MANIFEST.sha256 "$NAME" ;;
    document-vide)
        : > "$NAME"; archive "$NAME" ;;
    fichier-en-trop)
        echo intrus > intrus.txt; archive "$NAME" intrus.txt ;;
    manifeste-absent)
        tar --format=ustar -cf - "$NAME" ;;
    manifeste-autre-nom) # manifeste exact, mais pour un autre nom de fichier
        sha256sum "$NAME" | sed 's/T170000Z/T170001Z/' > MANIFEST.sha256
        tar --format=ustar -cf - MANIFEST.sha256 "$NAME" ;;
    membre-parent)       # document placé hors du dossier d'extraction
        sha256sum "$NAME" > MANIFEST.sha256
        tar --format=ustar -cf - MANIFEST.sha256 "$NAME" --transform "s,^$NAME,../$NAME," ;;
    pas-une-archive)
        echo "ceci n'est pas une archive" ;;
    code-non-nul)        # archive correcte, mais l'export se termine en échec
        archive "$NAME"
        echo "Export du guide échoué : simulé après l'archive" >&2
        exit 1 ;;
    champ-inconnu)       # champ « title » dans une entrée : le format version 1 n'en a pas
        sed -i 's/"rank": 1,/"rank": 1, "title": "Titre invente",/' "$NAME"; archive "$NAME" ;;
    rang-hors-plage)
        sed -i 's/"rank": 1,/"rank": 101,/' "$NAME"; archive "$NAME" ;;
    avec-bom)
        printf '\357\273\277%s\n' "$DOC" > "$NAME"; archive "$NAME" ;;
    pas-utf8)            # octet 0xFF dans une chaîne
        sed -i 's/\["B0FAUX0001"\]/["B0FAUX0001", "\xff"]/' "$NAME"; archive "$NAME" ;;
    json-invalide)       # accolade finale retirée
        sed -i 's/}$//' "$NAME"; archive "$NAME" ;;
    nom-date-differente) # document conforme, mais nommé d'après une autre date que generated_at
        mv "$NAME" guide_2026-10-11T170001Z.json; NAME=guide_2026-10-11T170001Z.json; archive "$NAME" ;;
    *)
        echo "mode inconnu : $MODE" >&2; exit 64 ;;
esac
