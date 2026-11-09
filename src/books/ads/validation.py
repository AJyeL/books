"""Nature d'un fichier de rapport Amazon Ads, jugée avant le dépôt dans RAW (décision 018, lot A).

RAW ne juge que la nature du fichier, jamais son contenu : un verdict gravé dans une couche immuable, dédoublonnée
par empreinte, ne pourrait pas être corrigé si ce validateur avait un défaut. Six contrôles seulement, dans cet ordre
(le premier qui échoue donne le motif) :
  1. fichier vide ;
  2. encodage UTF-8 (BOM admis) ;
  5. type, détecté par les en-têtes, jamais par le nom ;
  6. rapport en « Plage de dates » ; 7. rapport en « Jour du mois » ; 8. colonne « Date » absente.
Les numéros sont ceux de la décision 018 ; les autres contrôles (forme CSV, colonnes requises, valeurs, doublons) sont
des statuts d'extraction recalculables (lot B, STAGING).

Le nom n'est jamais jugé (motif 10 supprimé, note du 9 novembre 2026 de la décision 018) : l'horodatage qu'il porte est
le nom du rapport proposé par défaut dans le formulaire d'Amazon Ads, modifiable par l'utilisateur. Il est lu s'il est
présent, pour mémoire, et n'intervient dans aucun calcul ; sinon la date et l'heure restent NULL.

Seule la ligne d'en-tête est lue ; aucun motif ne recopie une cellule.
"""

import csv
import re
from dataclasses import dataclass
from datetime import date, time

BOM = b"\xef\xbb\xbf"
# Colonne qui désigne chaque type de rapport (libellés de l'interface française d'Amazon Ads)
TYPE_MARKERS = {
    "advertised_product": "Identifiant du produit promu",
    "search_term": "Terme de recherche",
}
DAILY = "Date"
RANGE = "Plage de dates"
DAY_OF_MONTH = "Jour du mois"
# Horodatage du nom proposé par Amazon Ads, en fin de nom : mois, jour, année, puis heure, minute, seconde ; le suffixe
# « (n) » d'un second téléchargement est toléré à la lecture
EXPORT_STAMP = re.compile(r"_([0-9]{2})_([0-9]{2})_([0-9]{4})T([0-9]{2})_([0-9]{2})_([0-9]{2})(?: \([0-9]+\))?\.csv\Z")


@dataclass(frozen=True)
class Verdict:
    status: str  # ok ou invalid
    reason: str | None
    report_type: str | None  # renseigné dès qu'il est détecté, même si le fichier est invalid
    export_date: date | None  # horodatage du nom, s'il est présent ; pour mémoire, jamais utilisé dans un calcul
    export_time: time | None


def read_export_stamp(name: str) -> tuple[date, time] | None:
    """Horodatage lu dans le nom, mois puis jour ; None s'il est absent ou impossible (ce n'est jamais un motif)."""
    match = EXPORT_STAMP.search(name)
    if not match:
        return None
    month, day, year, hour, minute, second = (int(g) for g in match.groups())
    try:
        return date(year, month, day), time(hour, minute, second)
    except ValueError:  # mois 13, 31 avril, 25 h…
        return None


def _header(text: str) -> list[str] | None:
    """Libellés de la première ligne, lus comme une ligne CSV ; None si elle est illisible ou vide."""
    first_line = text.split("\n", 1)[0].removesuffix("\r")
    try:
        labels = next(csv.reader([first_line], strict=True), None)
    except csv.Error:
        return None
    if not labels or all(not label.strip() for label in labels):
        return None
    return labels


def _report_type(labels: list[str] | None) -> tuple[str | None, str | None]:
    """(type, motif) : le type si exactement une colonne de type est présente, sinon le motif du refus."""
    if labels is None:
        return None, "type indétectable : ligne d'en-tête illisible ou vide"
    found = [kind for kind, marker in TYPE_MARKERS.items() if marker in labels]
    if len(found) == 1:
        return found[0], None
    markers = " et ".join(f"« {m} »" for m in TYPE_MARKERS.values())
    if not found:
        return None, f"type indétectable : aucune des colonnes {markers} dans l'en-tête"
    return None, f"type indétectable : colonnes {markers} toutes deux présentes"


def classify(name: str, content: bytes) -> Verdict:
    """Verdict de nature d'un fichier de rapport ; le type et la date d'export sont rendus dès qu'ils sont lisibles."""
    stamp = read_export_stamp(name)
    export_date, export_time = stamp if stamp else (None, None)

    def verdict(reason: str | None, report_type: str | None = None) -> Verdict:
        return Verdict("invalid" if reason else "ok", reason, report_type, export_date, export_time)

    if not content:
        return verdict("fichier vide")
    try:
        text = content.removeprefix(BOM).decode("utf-8")
    except UnicodeDecodeError as exc:
        return verdict(f"encodage : UTF-8 attendu (octet invalide à la position {exc.start})")

    labels = _header(text)
    report_type, reason = _report_type(labels)
    if reason:
        return verdict(reason)
    if RANGE in labels:
        return verdict(f"rapport en « {RANGE} » : rapport journalier (colonne « {DAILY} ») attendu", report_type)
    if DAY_OF_MONTH in labels:
        return verdict(f"rapport en « {DAY_OF_MONTH} » : rapport journalier (colonne « {DAILY} ») attendu",
                       report_type)
    if DAILY not in labels:
        return verdict(f"colonne « {DAILY} » absente : rapport journalier attendu", report_type)
    return verdict(None, report_type)
