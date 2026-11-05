"""Analyse du contenu d'un rapport Amazon Ads journalier, pour STAGING (décision 018, lot B).

Le fichier a déjà passé les contrôles de nature de RAW (books.ads.validation, lot A). Ici, le contenu, avec des
statuts recalculables à chaque version de l'extracteur. Le premier défaut rencontré donne le motif, dans cet ordre :
  3. forme CSV : guillemet non fermé, ou ligne au nombre de colonnes différent de l'en-tête ;
  4. libellé de colonne en double ;
  9. colonne requise absente ;
  (aucune ligne de données : NoActivity, « aucune activité rapportée », qui n'est pas une anomalie) ;
  puis ligne par ligne : 12. devise autre que EUR ; 13. date illisible ; 14. mesure invalide ;
     15. clé du grain incomplète ; texte de plus de 2 000 octets (refusé par mapping.code_for) ;
  15. doublon sur la clé du grain ;
  16. date d'export antérieure ou égale à la dernière date du fichier.
Les numéros sont ceux de la décision 018. Aucun motif ne recopie une cellule : seulement des libellés de colonne,
des numéros de ligne, des nombres de colonnes, des dates, et la devise si elle a la forme d'un code ISO.

Les textes (noms de campagne et de groupe, titre, terme, ciblage) sont rendus tels qu'Amazon les écrit, sans
normalisation, pour mapping.code_for ; seule la forme Excel « ="…" » des identifiants est retirée.
"""

import csv
import io
import re
from dataclasses import dataclass, field
from datetime import date
from decimal import Decimal

BOM = "﻿"
CURRENCY = "EUR"
TEXT_MAX_BYTES = 2000  # limite de mapping.code_for (décision 019, section 3)
# Séparateurs qui rendent un texte « vide » pour mapping.code_for (décision 019, section 3)
BLANK = " \t\r\n  "
MONTHS = {"janv.": 1, "févr.": 2, "mars": 3, "avr.": 4, "mai": 5, "juin": 6, "juil.": 7, "août": 8, "sept.": 9,
          "oct.": 10, "nov.": 11, "déc.": 12}
DATE_FORM = re.compile(r"([0-9]{1,2}) (\S+) ([0-9]{4})")
INTEGER = re.compile(r"[0-9]+")
DECIMAL = re.compile(r"[0-9]+(\.[0-9]{1,5})?")
EXCEL_TEXT = re.compile(r'="(.*)"', re.S)

# Mesures additives : libellé d'Amazon → (nom de colonne, entier ?)
MEASURES = {
    "Impressions": ("impressions", True),
    "Clics": ("clicks", True),
    "Coût total": ("cost", False),
    "Achats": ("purchases", True),
    "Ventes": ("sales", False),
    "Unités vendues": ("units_sold", True),
    "Lecture KENP": ("kenp_pages", True),
    "Emprunts éligibles à l'abonnement Kindle": ("borrows", True),
    "Estimation des redevances liées à l'abonnement Kindle": ("royalties", False),
}
CURRENCY_LABEL = "Devise du budget"
DAY = "Date"
CAMPAIGN_ID, CAMPAIGN_NAME = "Identifiant de la campagne", "Nom de la campagne"
AD_GROUP_ID, AD_GROUP_NAME = "Identifiant du groupe de publicités", "Nom du groupe de publicités"
PRODUCT_ID, PRODUCT_TITLE = "Identifiant du produit promu", "Nom du produit promu"
SEARCH_TERM, TARGETING, TARGET_ID = "Terme de recherche", "Ciblage", "ID cible"
TARGET_TYPE, MATCH_TYPE = "Type de cible", "Type de correspondance associé au ciblage"

COMMON_REQUIRED = [CURRENCY_LABEL, DAY, CAMPAIGN_ID, CAMPAIGN_NAME, AD_GROUP_ID, AD_GROUP_NAME, *MEASURES]
REQUIRED = {
    "advertised_product": COMMON_REQUIRED + [PRODUCT_ID, PRODUCT_TITLE],
    "search_term": COMMON_REQUIRED + [SEARCH_TERM, TARGETING, TARGET_ID, TARGET_TYPE, MATCH_TYPE],
}
# Colonnes clés du grain (décision 018, section 4), en plus du jour
KEY_COLUMNS = {
    "advertised_product": [CAMPAIGN_ID, AD_GROUP_ID, PRODUCT_ID],
    "search_term": [CAMPAIGN_ID, AD_GROUP_ID, TARGET_ID, MATCH_TYPE, SEARCH_TERM],
}
IDENTIFIERS = {CAMPAIGN_ID, AD_GROUP_ID, PRODUCT_ID, TARGET_ID}
# Colonnes connues mais non gardées (taux, compte, portefeuille, autres attributs du produit, colonnes vides ou
# toujours nulles de l'inventaire) : ni anomalie, ni information
KNOWN_IGNORED = [
    "Identifiant du compte de l'annonceur", "Nom du compte de l'annonceur", "Identifiant de portefeuille",
    "Nom du portefeuille", "Identifiant parent du produit promu", "Marque du produit promu",
    "Catégorie du produit promu", "Sous-catégorie du produit promu", "Groupe du produit promu",
    "SKU du produit promu-Advertised product SKU", "Marketplace du produit promu-Advertised product marketplace",
    "Taux de clics", "Coût par achat", "Taux d'achat", "ROAS", "Achats (promus)", "Ventes (sponsorisées)",
    "Unités vendues (promues)", "Coût par achat (sponsorisé)", "Taux d'achat (sponsorisé)", "ROAS (sponsorisé)",
    "Achats (halo)", "Ventes (halo)", "Unités vendues (halo)", "Achats (premier achat de la marque)",
    "Ventes (premier achat de la marque)", "Unités vendues (premier achat de la marque)",
    "Coût par achat (premier achat de la marque)", "Taux d'achat (premier achat de la marque)",
    "ROAS (premier achat de la marque)", "Vues de la page produit", "Coût par vue de page produit",
    "Taux de vues de la page produit",
]
KNOWN = set(REQUIRED["advertised_product"]) | set(REQUIRED["search_term"]) | set(KNOWN_IGNORED)


class AdsParseError(Exception):
    """Contenu refusé (parse_failed) ; le message est le motif, sans aucune valeur de cellule."""


class NoActivity(Exception):
    """Aucune ligne de données : « aucune activité rapportée », ni succès ni anomalie."""

    def __init__(self, unknown_columns: list[str]):
        super().__init__("aucune activité rapportée")
        self.unknown_columns = unknown_columns


@dataclass(frozen=True)
class AdsRow:
    day: date
    campaign_id: str
    ad_group_id: str
    campaign_name: str | None  # textes pour mapping.code_for ; None si vides
    ad_group_name: str | None
    measures: dict  # nom de colonne → int, Decimal ou None (cellule vide)
    # Advertised product
    advertised_product_id: str | None = None
    product_title: str | None = None
    # Search term
    target_id: str | None = None
    target_type: str | None = None
    match_type: str | None = None
    search_term: str | None = None
    targeting: str | None = None


@dataclass(frozen=True)
class ParsedReport:
    report_type: str
    rows: list[AdsRow]
    first_day: date
    last_day: date
    unknown_columns: list[str] = field(default_factory=list)


def _identifier(value: str) -> str:
    """Retire la seule forme Excel « ="…" » ; rien d'autre n'est modifié."""
    match = EXCEL_TEXT.fullmatch(value)
    return match.group(1) if match else value


def _text(value: str) -> str | None:
    """Texte tel qu'Amazon l'écrit ; None s'il ne contient que des séparateurs (refusé par mapping.code_for)."""
    return value if value.strip(BLANK) else None


def _day(value: str) -> date | None:
    match = DATE_FORM.fullmatch(value)
    if not match or match.group(2) not in MONTHS:
        return None
    try:
        return date(int(match.group(3)), MONTHS[match.group(2)], int(match.group(1)))
    except ValueError:
        return None


def parse_report(content: bytes, report_type: str, export_date: date) -> ParsedReport:
    """Lignes d'un rapport ; lève AdsParseError (motif) ou NoActivity."""
    text = content.decode("utf-8").removeprefix(BOM)
    reader = csv.reader(io.StringIO(text, newline=""), strict=True)
    try:
        records = []
        for record in reader:
            records.append((reader.line_num, record))
    except csv.Error:
        raise AdsParseError(f"CSV mal formé : guillemet non fermé ou caractère inattendu (ligne {reader.line_num})") from None
    header = records[0][1]
    for line, record in records[1:]:
        if len(record) != len(header):
            raise AdsParseError(f"CSV mal formé : ligne {line}, {len(record)} colonne(s) au lieu de {len(header)}")
    seen = set()
    for label in header:
        if label in seen:
            raise AdsParseError(f"libellé de colonne en double : « {label} »")
        seen.add(label)
    for label in REQUIRED[report_type]:
        if label not in seen:
            raise AdsParseError(f"colonne requise absente : « {label} »")
    unknown = [label for label in header if label not in KNOWN]
    if len(records) == 1:
        raise NoActivity(unknown)

    position = {label: i for i, label in enumerate(header)}
    rows, keys = [], {}
    for line, record in records[1:]:
        def cell(label: str) -> str:
            return record[position[label]]

        currency = cell(CURRENCY_LABEL)
        if currency != CURRENCY:
            shown = currency if re.fullmatch(r"[A-Z]{3}", currency) else "valeur non reconnue"
            raise AdsParseError(f"devise autre que {CURRENCY} (ligne {line} : {shown})")
        day = _day(cell(DAY))
        if day is None:
            raise AdsParseError(f"date illisible (ligne {line}, colonne « {DAY} »)")
        measures = {}
        for label, (name, integer) in MEASURES.items():
            value = cell(label)
            if value == "":
                measures[name] = None  # cellule vide : absence, jamais 0
            elif integer and INTEGER.fullmatch(value):
                measures[name] = int(value)
            elif not integer and DECIMAL.fullmatch(value):
                measures[name] = Decimal(value)
            else:
                expected = "entier positif ou nul" if integer else "nombre positif ou nul d'au plus 5 décimales"
                raise AdsParseError(f"mesure invalide (ligne {line}, colonne « {label} ») : {expected} attendu")
        key = []
        for label in KEY_COLUMNS[report_type]:
            value = _identifier(cell(label)) if label in IDENTIFIERS else cell(label)
            if not value.strip(BLANK):
                raise AdsParseError(f"clé du grain incomplète (ligne {line}, colonne « {label} » vide)")
            key.append(value)
        texts = [CAMPAIGN_NAME, AD_GROUP_NAME]
        texts += [PRODUCT_TITLE] if report_type == "advertised_product" else [SEARCH_TERM, TARGETING]
        for label in texts:
            if len(cell(label).encode("utf-8")) > TEXT_MAX_BYTES:
                raise AdsParseError(f"texte de plus de {TEXT_MAX_BYTES} octets (ligne {line}, colonne « {label} »)")
        grain = (day, *key)
        if grain in keys:
            raise AdsParseError(f"doublon sur la clé du grain : lignes {keys[grain]} et {line}")
        keys[grain] = line
        common = dict(day=day, campaign_id=_identifier(cell(CAMPAIGN_ID)), ad_group_id=_identifier(cell(AD_GROUP_ID)),
                      campaign_name=_text(cell(CAMPAIGN_NAME)), ad_group_name=_text(cell(AD_GROUP_NAME)),
                      measures=measures)
        if report_type == "advertised_product":
            rows.append(AdsRow(**common, advertised_product_id=_identifier(cell(PRODUCT_ID)),
                               product_title=_text(cell(PRODUCT_TITLE))))
        else:
            rows.append(AdsRow(**common, target_id=_identifier(cell(TARGET_ID)), target_type=_text(cell(TARGET_TYPE)),
                               match_type=cell(MATCH_TYPE), search_term=cell(SEARCH_TERM),
                               targeting=_text(cell(TARGETING))))

    first_day = min(r.day for r in rows)
    last_day = max(r.day for r in rows)
    if export_date <= last_day:
        raise AdsParseError(f"date d'export ({export_date.isoformat()}) antérieure ou égale à la dernière date du "
                            f"fichier ({last_day.isoformat()})")
    return ParsedReport(report_type, rows, first_day, last_day, unknown)
