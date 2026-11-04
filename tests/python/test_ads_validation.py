"""Tests de books.ads.validation : nature d'un rapport Amazon Ads avant son dépôt dans RAW (décision 018, lot A).

Chaque motif invalid du lot A (1, 2, 5, 6, 7, 8, 10) est produit par mutation des deux rapports inventés de
tests/fixtures/ads/ ; aucun motif ne doit recopier une cellule (mot « Sentinelle » des fichiers de test).
Les défauts de contenu (forme CSV, colonnes requises, valeurs, doublons) ne sont PAS jugés ici : un fichier qui n'a
que ceux-là est ok pour RAW, et sera jugé à l'extraction (lot B).
"""

from datetime import date, time

import pytest

from books.ads.validation import classify, read_export_stamp
from conftest import FIXTURES

ADS = FIXTURES / "ads"
AP_NAME = "Advertised_product_-_12_05_2026T19_59_56.csv"
ST_NAME = "Search_term_-_12_05_2026T20_05_45.csv"
AP = (ADS / AP_NAME).read_bytes()
ST = (ADS / ST_NAME).read_bytes()
BOM = b"\xef\xbb\xbf"


def replace_header_label(content: bytes, old: str, new: str) -> bytes:
    """Remplace un libellé dans la seule ligne d'en-tête (exactement une fois)."""
    header, rest = content.split(b"\r\n", 1)
    labels = header.decode("utf-8").split(",")
    assert labels.count(old) == 1, old
    labels[labels.index(old)] = new
    return ",".join(labels).encode("utf-8") + b"\r\n" + rest


def assert_invalid(verdict, fragment: str) -> None:
    assert verdict.status == "invalid"
    assert fragment in verdict.reason
    assert "sentinelle" not in verdict.reason.lower()  # aucune cellule recopiée


# --- Fichiers conformes ----------------------------------------------------------------------

def test_fixtures_inventees_ont_la_forme_reelle():
    for content in (AP, ST):
        assert content.startswith(BOM)
        assert b"\r\n" in content and b"\n" not in content.replace(b"\r\n", b"")
        assert b'"=""1000000000000' in content  # identifiant de campagne en ="…"
        assert "déc.".encode() in content
    assert b'"terme Sentinelle, avec virgule"' in ST


def test_advertised_product_ok():
    verdict = classify(AP_NAME, AP)
    assert (verdict.status, verdict.reason, verdict.report_type) == ("ok", None, "advertised_product")
    assert (verdict.export_date, verdict.export_time) == (date(2026, 12, 5), time(19, 59, 56))


def test_search_term_ok():
    verdict = classify(ST_NAME, ST)
    assert (verdict.status, verdict.reason, verdict.report_type) == ("ok", None, "search_term")
    assert (verdict.export_date, verdict.export_time) == (date(2026, 12, 5), time(20, 5, 45))


def test_sans_bom_et_fins_de_ligne_lf_acceptes():
    content = AP.removeprefix(BOM).replace(b"\r\n", b"\n")
    assert classify(AP_NAME, content).status == "ok"


def test_type_jamais_lu_dans_le_nom():
    # Contenu Search term sous un nom d'Advertised product : le type vient des en-têtes
    verdict = classify("Advertised_product_-_12_05_2026T19_59_56.csv", ST)
    assert (verdict.status, verdict.report_type) == ("ok", "search_term")
    assert classify("rapport_12_05_2026T19_59_56.csv", AP).report_type == "advertised_product"


@pytest.mark.parametrize("content", [
    AP + b"ligne,mal,formee,\"guillemet non ferme\r\n",           # forme CSV (motif 3, lot B)
    replace_header_label(AP, "Clics", "Impressions"),               # libellé en double (motif 4, lot B)
    replace_header_label(AP, "Coût total", "Colonne inconnue"),     # colonne requise absente (motif 9, lot B)
    AP.split(b"\r\n", 1)[0] + b"\r\n",                               # aucune ligne de données (lot B)
    AP.replace("1 déc. 2026".encode(), "1 decembre 2026".encode()),  # date illisible (motif 13, lot B)
    AP.replace(b",EUR,", b",USD,").replace(b"\r\nEUR,", b"\r\nUSD,"),  # devise (motif 12, lot B)
], ids=["csv-mal-forme", "en-tete-double", "colonne-requise-absente", "sans-ligne", "date-illisible", "devise"])
def test_le_contenu_n_est_pas_juge_dans_raw(content):
    # Ces défauts relèvent de l'extraction (statuts recalculables, lot B) : RAW ne juge que la nature
    assert classify(AP_NAME, content).status == "ok"


# --- Contre-épreuves : un motif invalid du lot A chacune ------------------------------------

def test_motif_1_fichier_vide():
    assert_invalid(classify(AP_NAME, b""), "fichier vide")


@pytest.mark.parametrize("content", [
    AP.removeprefix(BOM).decode("utf-8").encode("cp1252"),
    AP.removeprefix(BOM).decode("utf-8").encode("utf-16"),
    AP + b"\xff",
], ids=["windows-1252", "utf-16", "octet-invalide"])
def test_motif_2_encodage(content):
    verdict = classify(AP_NAME, content)
    assert_invalid(verdict, "encodage : UTF-8 attendu")
    assert verdict.report_type is None


def test_motif_5_aucune_colonne_de_type():
    content = replace_header_label(AP, "Identifiant du produit promu", "Identifiant du produit")
    assert_invalid(classify(AP_NAME, content), "type indétectable : aucune des colonnes")


def test_motif_5_deux_colonnes_de_type():
    content = replace_header_label(AP, "Nom du produit promu", "Terme de recherche")
    assert_invalid(classify(AP_NAME, content), "type indétectable : colonnes")


@pytest.mark.parametrize("content", [b"\r\nligne", BOM + b'"en-tete non fermee\r\n', b" , ,\r\n"],
                         ids=["premiere-ligne-vide", "guillemet-non-ferme", "libelles-blancs"])
def test_motif_5_en_tete_illisible(content):
    assert_invalid(classify(AP_NAME, content), "type indétectable : ligne d'en-tête illisible ou vide")


@pytest.mark.parametrize("content", [AP, ST], ids=["advertised_product", "search_term"])
def test_motif_6_plage_de_dates(content):
    verdict = classify("x_11_03_2026T19_21_35.csv", replace_header_label(content, "Date", "Plage de dates"))
    assert_invalid(verdict, "rapport en « Plage de dates »")
    assert verdict.report_type is not None  # type et date d'export conservés pour RAW
    assert verdict.export_date == date(2026, 11, 3)


def test_motif_7_jour_du_mois():
    assert_invalid(classify(ST_NAME, replace_header_label(ST, "Date", "Jour du mois")), "rapport en « Jour du mois »")


def test_motif_8_colonne_date_absente():
    verdict = classify(ST_NAME, replace_header_label(ST, "Date", "Jour"))
    assert_invalid(verdict, "colonne « Date » absente")
    assert verdict.report_type == "search_term"


@pytest.mark.parametrize("name", [
    "Search_term.csv",                                # aucun horodatage
    "Search_term_-_13_05_2026T20_05_45.csv",          # mois 13
    "Search_term_-_04_31_2026T20_05_45.csv",          # 31 avril
    "Search_term_-_12_05_2026T25_05_45.csv",          # 25 h
    "Search_term_-_2026-12-05T20_05_45.csv",          # autre ordre, autres séparateurs
    "Search_term_-_12_05_2026T20_05_45.csv.txt",      # horodatage qui n'est pas en fin de nom
], ids=["sans-horodatage", "mois-13", "31-avril", "25-h", "autre-format", "pas-en-fin"])
def test_motif_10_nom_hors_format(name):
    verdict = classify(name, ST)
    assert_invalid(verdict, "nom hors format")
    assert (verdict.report_type, verdict.export_date, verdict.export_time) == ("search_term", None, None)


def test_mois_puis_jour():
    # 05_12 : 12 mai, et non 5 décembre
    assert read_export_stamp("Search_term_-_05_12_2026T08_00_00.csv") == (date(2026, 5, 12), time(8, 0, 0))


def test_ordre_des_motifs_le_premier_l_emporte():
    # Encodage invalide ET nom hors format : le motif 2 passe avant le motif 10
    content = AP.removeprefix(BOM).decode("utf-8").encode("cp1252")
    assert_invalid(classify("sans-horodatage.csv", content), "encodage")
    # Plage de dates ET nom hors format : le motif 6 passe avant le motif 10
    assert_invalid(classify("sans-horodatage.csv", replace_header_label(AP, "Date", "Plage de dates")),
                   "Plage de dates")
