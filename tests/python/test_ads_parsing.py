"""Tests de books.ads.parsing : contenu d'un rapport Amazon Ads pour STAGING (décision 018, lot B).

Chaque motif parse_failed (3, 4, 9, 12 à 16) est produit par mutation des rapports inventés de tests/fixtures/ads/ ;
aucun motif ne recopie une cellule (mot « Sentinelle » des fichiers de test, et valeurs fautives injectées).
"""

import csv
import io
from datetime import date
from decimal import Decimal

import pytest

from books.ads.parsing import REQUIRED, AdsParseError, NoActivity, parse_report
from conftest import FIXTURES

ADS = FIXTURES / "ads"
AP = (ADS / "Advertised_product_-_12_05_2026T19_59_56.csv").read_bytes()
ST = (ADS / "Search_term_-_12_05_2026T20_05_45.csv").read_bytes()
EXPORT = date(2026, 12, 5)
BOM = b"\xef\xbb\xbf"


def rows_of(content: bytes) -> list[list[str]]:
    return list(csv.reader(io.StringIO(content.decode("utf-8").removeprefix("﻿"), newline="")))


def rebuild(rows: list[list[str]]) -> bytes:
    buffer = io.StringIO(newline="")
    csv.writer(buffer, lineterminator="\r\n").writerows(rows)
    return BOM + buffer.getvalue().encode("utf-8")


def mutate(content: bytes, row: int, label: str, value: str) -> bytes:
    """Remplace une cellule (row : 1 = première ligne de données)."""
    rows = rows_of(content)
    rows[row][rows[0].index(label)] = value
    return rebuild(rows)


def assert_refused(content: bytes, report_type: str, fragment: str, *forbidden: str, export=EXPORT) -> str:
    with pytest.raises(AdsParseError) as caught:
        parse_report(content, report_type, export)
    message = str(caught.value)
    assert fragment in message
    for value in ("sentinelle", *forbidden):
        assert value.lower() not in message.lower()  # aucune cellule recopiée
    return message


# --- Fichiers conformes ----------------------------------------------------------------------

def test_advertised_product():
    report = parse_report(AP, "advertised_product", EXPORT)
    assert (report.first_day, report.last_day, report.unknown_columns) == (date(2026, 10, 15), date(2026, 12, 1), [])
    assert len(report.rows) == 3
    first = report.rows[0]
    assert (first.campaign_id, first.ad_group_id, first.advertised_product_id) == (
        "100000000000001", "200000000000001", "B0FAUX0001")  # forme ="…" retirée
    assert (first.campaign_name, first.product_title) == ("Campagne d'exemple 1", "Titre d'exemple pour les tests 1")
    assert first.measures["impressions"] == 1234 and first.measures["cost"] == Decimal("0.40000")
    assert report.rows[1].measures["kenp_pages"] is None  # cellule vide : absence, jamais 0
    assert report.rows[2].measures["cost"] == Decimal("0.60")  # coût à 2 décimales


def test_search_term_textes_tels_quels():
    report = parse_report(ST, "search_term", EXPORT)
    assert [r.search_term for r in report.rows] == ["terme d'exemple", "terme Sentinelle, avec virgule", "b0faux0003"]
    assert report.rows[0].targeting == 'asin="B0FAUX0002"'  # aucune normalisation, guillemets compris
    assert (report.rows[0].target_id, report.rows[0].target_type, report.rows[0].match_type) == (
        "300000000000001", "rsf", "TARGETING_EXPRESSION")


def test_colonne_inconnue_signalee():
    rows = rows_of(AP)
    rows[0].append("Colonne nouvelle")
    for row in rows[1:]:
        row.append("x")
    assert parse_report(rebuild(rows), "advertised_product", EXPORT).unknown_columns == ["Colonne nouvelle"]


def test_aucune_activite_rapportee():
    with pytest.raises(NoActivity) as caught:
        parse_report(AP.split(b"\r\n", 1)[0] + b"\r\n", "advertised_product", EXPORT)
    assert caught.value.unknown_columns == []


def test_nom_vide_donne_none():
    report = parse_report(mutate(AP, 1, "Nom de la campagne", "  "), "advertised_product", EXPORT)
    assert report.rows[0].campaign_name is None


# --- Contre-épreuves : un motif chacune ------------------------------------------------------

def test_motif_3_guillemet_non_ferme():
    assert_refused(AP + b'EUR,"non ferme\r\n', "advertised_product", "CSV mal formé : guillemet non fermé")


def test_motif_3_ligne_trop_courte():
    assert_refused(AP + b"EUR,x\r\n", "advertised_product", "CSV mal formé : ligne 5, 2 colonne(s) au lieu de 50")


def test_motif_4_libelle_en_double():
    rows = rows_of(AP)
    rows[0][rows[0].index("Taux de clics")] = "Clics"
    assert_refused(rebuild(rows), "advertised_product", "libellé de colonne en double : « Clics »")


@pytest.mark.parametrize("report_type,content", [("advertised_product", AP), ("search_term", ST)])
def test_motif_9_chaque_colonne_requise(report_type, content):
    for label in REQUIRED[report_type]:
        rows = rows_of(content)
        rows[0][rows[0].index(label)] = "Libellé remplacé"
        assert_refused(rebuild(rows), report_type, f"colonne requise absente : « {label} »")


@pytest.mark.parametrize("value,shown", [("USD", "USD"), ("€uro", "valeur non reconnue")])
def test_motif_12_devise(value, shown):
    message = assert_refused(mutate(AP, 2, "Devise du budget", value), "advertised_product", "devise autre que EUR")
    assert f"ligne 3 : {shown}" in message
    if shown != value:
        assert value not in message


@pytest.mark.parametrize("value", ["4 novembre 2026", "31 nov. 2026", "4/11/2026", ""])
def test_motif_13_date_illisible(value):
    message = assert_refused(mutate(ST, 2, "Date", value), "search_term", "date illisible (ligne 3, colonne « Date »)")
    if value:
        assert value not in message


@pytest.mark.parametrize("label,value,expected", [
    ("Clics", "2x", "entier positif ou nul"),
    ("Impressions", "-5", "entier positif ou nul"),
    ("Achats", "1.0", "entier positif ou nul"),
    ("Coût total", "0.123456", "au plus 5 décimales"),
    ("Ventes", "2,99", "au plus 5 décimales"),
])
def test_motif_14_mesure_invalide(label, value, expected):
    message = assert_refused(mutate(AP, 1, label, value), "advertised_product",
                             f"mesure invalide (ligne 2, colonne « {label} »)")
    assert expected in message and value not in message


@pytest.mark.parametrize("report_type,content", [("advertised_product", AP), ("search_term", ST)])
def test_motif_15_doublon(report_type, content):
    rows = rows_of(content)
    rows.append(list(rows[1]))
    assert_refused(rebuild(rows), report_type, "doublon sur la clé du grain : lignes 2 et 5")


@pytest.mark.parametrize("label", ["Identifiant de la campagne", "Identifiant du groupe de publicités", "ID cible",
                                   "Type de correspondance associé au ciblage", "Terme de recherche"])
def test_motif_15_cle_incomplete(label):
    assert_refused(mutate(ST, 1, label, '=""' if label.startswith("Identifiant") else " "), "search_term",
                   f"clé du grain incomplète (ligne 2, colonne « {label} » vide)")


def test_texte_trop_long():
    assert_refused(mutate(ST, 1, "Terme de recherche", "Sentinelle " + "x" * 2000), "search_term",
                   "texte de plus de 2000 octets (ligne 2, colonne « Terme de recherche »)")


@pytest.mark.parametrize("export", [date(2026, 12, 1), date(2026, 11, 30)], ids=["egale", "anterieure"])
def test_motif_16_date_export(export):
    assert_refused(AP, "advertised_product", f"date d'export ({export.isoformat()}) antérieure ou égale à la "
                   "dernière date du fichier (2026-12-01)", export=export)


def test_ordre_des_motifs():
    # Libellé en double ET date illisible : le motif 4 passe avant le motif 13
    rows = rows_of(mutate(AP, 1, "Date", "jamais"))
    rows[0][rows[0].index("Taux de clics")] = "Clics"
    assert_refused(rebuild(rows), "advertised_product", "libellé de colonne en double")
    # Doublon ET date d'export trop ancienne : le motif 15 passe avant le motif 16
    rows = rows_of(AP)
    rows.append(list(rows[1]))
    assert_refused(rebuild(rows), "advertised_product", "doublon", export=date(2026, 11, 1))
