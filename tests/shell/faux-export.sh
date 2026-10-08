#!/usr/bin/env bash
# Doublure de test : export volontairement défectueux, à la place de scripts/exporter-sauvegarde.sh,
# pour vérifier que scripts/rapatrier-sauvegarde.ps1 refuse ce qu'il reçoit (tests uniquement).
# Usage : bash faux-export.sh {mode} > archive.tar
set -euo pipefail

MODE="${1:-}"
NAME=books_2026-10-08T10-00-00Z.dump
W="$(mktemp -d)"
trap 'rm -rf -- "$W"' EXIT
cd "$W"
printf 'PGDMP\001\016\000\r\n\032\377faux' > "$NAME"
sha256sum "$NAME" > MANIFEST.sha256

case "$MODE" in
    valide)             # archive correcte, au nom de dump fixe (test de collision)
        tar --format=ustar -cf - MANIFEST.sha256 "$NAME" ;;
    empreinte-fausse)   # dump modifié après le calcul du manifeste
        printf 'x' >> "$NAME"
        tar --format=ustar -cf - MANIFEST.sha256 "$NAME" ;;
    dump-vide)          # manifeste exact, mais dump vide
        : > "$NAME"; sha256sum "$NAME" > MANIFEST.sha256
        tar --format=ustar -cf - MANIFEST.sha256 "$NAME" ;;
    fichier-en-trop)
        echo intrus > intrus.txt
        tar --format=ustar -cf - MANIFEST.sha256 "$NAME" intrus.txt ;;
    manifeste-absent)
        tar --format=ustar -cf - "$NAME" ;;
    manifeste-autre-nom) # manifeste exact, mais pour un autre nom de fichier
        sed -i 's/T10-00-00Z/T11-00-00Z/' MANIFEST.sha256
        tar --format=ustar -cf - MANIFEST.sha256 "$NAME" ;;
    membre-parent)      # dump placé hors du dossier d'extraction
        tar --format=ustar -cf - MANIFEST.sha256 "$NAME" --transform "s,^$NAME,../$NAME," ;;
    pas-une-archive)
        echo "ceci n'est pas une archive" ;;
    code-non-nul)       # archive correcte, mais l'export se termine en échec
        tar --format=ustar -cf - MANIFEST.sha256 "$NAME"
        echo "Export échoué : simulé après l'archive" >&2
        exit 1 ;;
    *)
        echo "mode inconnu : $MODE" >&2; exit 64 ;;
esac
