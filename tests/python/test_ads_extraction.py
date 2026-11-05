"""Tests de books.ads.extraction contre un PostgreSQL 17 jetable (migrations 001 à 012) : dépôt dans RAW sous
books_collector (lot A), puis extraction sous books_transformer (décision 018, lot B).

Lancement : bash tests/lancer-tests-postgres.sh (sinon, ces tests sont sautés).
"""

import gzip
from datetime import date
from pathlib import Path

import psycopg
import pytest

from books.ads.extraction import AdsExtractionBusy, extract_reports
from books.ads.ingestion import ingest_reports
from books.ads.repository import PgAdsRepository
from books.ads.transformer_repository import CODE_SQL, LOCK_KEY, PgAdsTransformerRepository
from books.transformer.extraction import ads_freshness, extract
from books.transformer.repository import PgTransformerRepository
from conftest import FIXTURES

ADS = FIXTURES / "ads"
AP_1205 = "Advertised_product_-_12_05_2026T19_59_56.csv"
ST_1205 = "Search_term_-_12_05_2026T20_05_45.csv"
AP_1220 = "Advertised_product_-_12_20_2026T09_00_00.csv"
ST_1220 = "Search_term_-_12_20_2026T09_00_00.csv"
LOT = "2026-12-21T080000Z"


def deposit(pg, tmp_path: Path, files: dict[str, bytes]) -> None:
    """Dépose des rapports dans RAW, comme l'ingestion du lot A (books_collector)."""
    ads = tmp_path / "ads"
    inbox = ads / "inbox" / LOT
    inbox.mkdir(parents=True, exist_ok=True)
    for name, content in files.items():
        (inbox / name).write_bytes(content)
    result = ingest_reports(ads, PgAdsRepository(pg.connect_collector()), pg.raw_dir, "0.9.0", log=lambda m: None)
    assert not result.report.deposited_invalid, result.report.deposited_invalid


def fixture(name: str) -> bytes:
    return (ADS / name).read_bytes()


def run(pg, **kwargs):
    logs = []
    result = extract_reports(PgAdsTransformerRepository(pg.transformer), pg.raw_dir, log=logs.append, **kwargs)
    return result, "\n".join(logs)


def file_id(pg, name: str) -> int:
    return pg.query("SELECT id FROM raw.ads_report_file WHERE original_name = %s", (name,))[0][0]


# --- Extraction, idempotence, versions -------------------------------------------------------------

def test_extraction_des_deux_types(pg, tmp_path):
    deposit(pg, tmp_path, {AP_1205: fixture(AP_1205), ST_1205: fixture(ST_1205)})
    result, logs = run(pg)
    assert result.status == "success", logs
    assert pg.query("SELECT f.original_name, e.status, e.row_count, e.first_day, e.last_day "
                    "FROM staging.ads_file_extraction e JOIN raw.ads_report_file f ON f.id = e.ads_report_file_id "
                    "ORDER BY 1") == [
        (AP_1205, "ok", 3, date(2026, 10, 15), date(2026, 12, 1)),
        (ST_1205, "ok", 3, date(2026, 10, 15), date(2026, 12, 1))]
    rows = pg.query("SELECT day, campaign_id, ad_group_id, advertised_product_id, campaign_name_code IS NOT NULL, "
                    "product_title_code IS NOT NULL, impressions, kenp_pages FROM staging.ads_product_day ORDER BY day")
    assert rows[0] == (date(2026, 10, 15), "100000000000001", "200000000000001", "B0FAUX0001", True, True, 1234, 0)
    assert rows[1][7] is None  # cellule vide : NULL, jamais 0
    assert pg.query("SELECT count(*), count(DISTINCT search_term_code), count(targeting_code) "
                    "FROM staging.ads_search_term_day") == [(3, 3, 3)]
    # Réconciliation sans écart ; une mesure non comparée (cellule vide d'un côté) ; emprunts jamais non nuls
    assert "Écarts de réconciliation  : 0" in logs
    assert "export du 2026-12-05, 2026-11-04 : « Lecture KENP » non comparée (cellule vide)" in logs
    assert "jamais vues non nulles" in logs
    assert pg.query("SELECT status, files_ok, files_no_activity, files_failed FROM staging.ads_extract_run") == [
        ("success", 2, 0, 0)]


def test_idempotence_meme_version(pg, tmp_path):
    deposit(pg, tmp_path, {AP_1205: fixture(AP_1205), ST_1205: fixture(ST_1205)})
    run(pg)
    codes = pg.query("SELECT count(*) FROM mapping.text_code")
    result, logs = run(pg)
    assert result.report.to_extract == 0 and result.report.up_to_date == 2
    assert result.status == "success"
    assert pg.query("SELECT count(*) FROM mapping.text_code") == codes
    assert pg.query("SELECT count(DISTINCT extract_run_id) FROM staging.ads_file_extraction") == [(1,)]


def test_nouvelle_version_reextrait_tout_et_retente_les_echecs(pg, tmp_path):
    usd = fixture(AP_1205).replace(b"\r\nEUR,", b"\r\nUSD,", 1)
    deposit(pg, tmp_path, {"Advertised_product_-_12_06_2026T10_00_00.csv": usd, ST_1205: fixture(ST_1205)})
    first, _ = run(pg)
    assert first.status == "partial" and len(first.report.failures) == 1
    # Même version : rien n'est réextrait, mais l'échec reste signalé (anomalie)
    again, logs = run(pg)
    assert again.report.to_extract == 0 and again.status == "partial"
    assert "Échecs connus (version)   : 1" in logs and "devise autre que EUR (ligne 2 : USD)" in logs
    # Nouvelle version : tout est réextrait, l'échec est retenté, aucune version mélangée
    second, _ = run(pg, extractor_version="2")
    assert second.report.to_extract == 2 and len(second.report.failures) == 1
    assert pg.query("SELECT DISTINCT r.extractor_version FROM staging.ads_file_extraction e "
                    "JOIN staging.ads_extract_run r ON r.id = e.extract_run_id") == [("2",)]
    assert pg.query("SELECT count(DISTINCT extract_run_id) FROM staging.ads_search_term_day") == [(1,)]


def test_aucune_activite_rapportee(pg, tmp_path):
    header = fixture(AP_1205).split(b"\r\n", 1)[0] + b"\r\n"
    deposit(pg, tmp_path, {"Advertised_product_-_12_07_2026T10_00_00.csv": header})
    result, logs = run(pg)
    assert result.status == "success"  # ni succès compté, ni anomalie
    assert pg.query("SELECT status, row_count, error_message FROM staging.ads_file_extraction") == [
        ("no_activity", 0, None)]
    assert "Aucune activité rapportée : 1" in logs


def test_integrity_failed(pg, tmp_path):
    deposit(pg, tmp_path, {AP_1205: fixture(AP_1205)})
    (path,) = pg.query("SELECT storage_path FROM raw.ads_report_file")[0]
    (pg.raw_dir / path).write_bytes(gzip.compress(b"modifie"))
    result, logs = run(pg)
    assert result.status == "partial"
    assert pg.query("SELECT status FROM staging.ads_file_extraction") == [("integrity_failed",)]
    assert "taille différente" in logs


def test_erreur_en_cours_d_ecriture_ne_laisse_rien(pg, tmp_path):
    deposit(pg, tmp_path, {ST_1205: fixture(ST_1205)})
    codes = pg.query("SELECT count(*) FROM mapping.text_code")

    class Interrompu(PgAdsTransformerRepository):
        calls = 0

        def _code(self, cache, nature, key):
            Interrompu.calls += 1
            if Interrompu.calls == 4:  # au milieu des codes du fichier
                raise RuntimeError("interruption simulée")
            return super()._code(cache, nature, key)

    with pytest.raises(RuntimeError, match="interruption simulée"):
        extract_reports(Interrompu(pg.transformer), pg.raw_dir, log=lambda m: None)
    assert pg.query("SELECT count(*) FROM mapping.text_code") == codes  # aucune correspondance gardée
    assert pg.query("SELECT count(*) FROM staging.ads_file_extraction") == [(0,)]
    assert pg.query("SELECT count(*) FROM staging.ads_search_term_day") == [(0,)]
    assert pg.query("SELECT status FROM staging.ads_extract_run") == [("failed",)]


def test_verrou_occupe(pg, tmp_path):
    with pg.connect_transformer() as other:
        other.execute("SELECT pg_advisory_lock(%s)", (LOCK_KEY,))
        with pytest.raises(AdsExtractionBusy):
            run(pg)
    assert pg.query("SELECT count(*) FROM staging.ads_extract_run") == [(0,)]


# --- Couverture par export et meilleure estimation ------------------------------------------------

def test_export_recent_l_emporte_pour_les_deux_types(pg, tmp_path):
    deposit(pg, tmp_path, {n: fixture(n) for n in (AP_1205, ST_1205, AP_1220, ST_1220)})
    result, logs = run(pg)
    # Couverture de l'export du 20 décembre : réunion des bornes de ses deux fichiers, du 15 octobre au 1er décembre
    assert pg.query("SELECT min(day), max(day), count(*), count(DISTINCT export_date) FROM staging.ads_day_source") == [
        (date(2026, 10, 15), date(2026, 12, 1), 48, 1)]
    assert pg.query("SELECT DISTINCT export_date FROM staging.ads_day_source") == [(date(2026, 12, 20),)]
    # Advertised product : le 4 novembre n'a pas de ligne dans l'export récent, et l'ancien n'est pas repris
    assert pg.query("SELECT day, impressions FROM staging.ads_product_day_best ORDER BY day") == [
        (date(2026, 10, 15), 1300), (date(2026, 12, 1), 5000)]
    # Search term récent sans ligne le 15 octobre : ce jour ne réapparaît pas depuis l'export du 5 décembre
    assert pg.query("SELECT day FROM staging.ads_search_term_day_best ORDER BY day") == [
        (date(2026, 11, 4),), (date(2026, 12, 1),)]
    # Rien n'est écrasé : les lignes de l'export ancien restent dans les tables
    assert pg.query("SELECT count(*) FROM staging.ads_search_term_day WHERE day = '2026-10-15'") == [(1,)]
    # Réconciliation de l'export du 20 décembre : un jour présent d'un seul côté est un écart
    assert result.status == "partial"
    assert "export du 2026-12-20, 2026-10-15 : jour présent dans le seul Advertised product" in logs
    assert "export du 2026-12-20, 2026-11-04 : jour présent dans le seul Search term" in logs


def test_jour_hors_couverture_recente_garde_l_export_ancien(pg, tmp_path):
    # Un export récent qui ne couvre que le 1er décembre : le 15 octobre reste à l'export du 5 décembre
    rows = fixture(AP_1220).split(b"\r\n")
    recent = b"\r\n".join([rows[0], rows[2], b""])  # seule la ligne du 1er décembre
    deposit(pg, tmp_path, {AP_1205: fixture(AP_1205), "Advertised_product_-_12_20_2026T09_00_00.csv": recent})
    run(pg)
    assert pg.query("SELECT day, export_date FROM staging.ads_product_day_best ORDER BY day") == [
        (date(2026, 10, 15), date(2026, 12, 5)), (date(2026, 11, 4), date(2026, 12, 5)),
        (date(2026, 12, 1), date(2026, 12, 20))]


def test_deux_fichiers_meme_type_meme_date(pg, tmp_path):
    later = fixture(AP_1205).replace(b",1234,", b",1250,", 1)
    deposit(pg, tmp_path, {AP_1205: fixture(AP_1205), "Advertised_product_-_12_05_2026T21_00_00.csv": later})
    _, logs = run(pg)
    assert "deux fichiers Advertised product ; retenu" in logs and "Advertised_product_-_12_05_2026T21_00_00.csv" in logs
    best = pg.query("SELECT f.original_name, p.impressions FROM staging.ads_product_day_best p "
                    "JOIN raw.ads_report_file f ON f.id = p.ads_report_file_id WHERE p.day = '2026-10-15'")
    assert best == [("Advertised_product_-_12_05_2026T21_00_00.csv", 1250)]


# --- Renommage de campagne --------------------------------------------------------------------------

def test_renommage_ne_fusionne_ni_ne_separe(pg, tmp_path):
    deposit(pg, tmp_path, {ST_1205: fixture(ST_1205), ST_1220: fixture(ST_1220)})
    run(pg)
    old, new = file_id(pg, ST_1205), file_id(pg, ST_1220)
    # Même identifiant, deux noms : deux codes de nom
    names_c1 = pg.query("SELECT DISTINCT campaign_name_code FROM staging.ads_search_term_day "
                        "WHERE campaign_id = '100000000000001'")
    assert len(names_c1) == 2
    # Deux identifiants, même nom : un seul code de nom, partagé
    old_c1 = pg.query("SELECT DISTINCT campaign_name_code FROM staging.ads_search_term_day "
                      "WHERE ads_report_file_id = %s AND campaign_id = '100000000000001'", (old,))
    new_c2 = pg.query("SELECT DISTINCT campaign_name_code FROM staging.ads_search_term_day "
                      "WHERE ads_report_file_id = %s AND campaign_id = '100000000000002'", (new,))
    assert old_c1 == new_c2
    # Regrouper par identifiant : deux campagnes, quels que soient les noms ; par code de nom, ce serait faux
    assert pg.query("SELECT count(DISTINCT campaign_id) FROM staging.ads_search_term_day") == [(2,)]
    by_id = dict(pg.query("SELECT campaign_id, sum(impressions) FROM staging.ads_search_term_day_best "
                          "GROUP BY campaign_id"))
    # 15 octobre : export du 5 décembre (hors couverture du 20) ; 4 novembre et 1er décembre : export du 20
    assert by_id == {"100000000000001": 1234 + 87, "100000000000002": 5000}


# --- Aucun texte hors de mapping ----------------------------------------------------------------------

SENTINELS = {
    b"Compte d'exemple": b"Sentinelle compte",
    b"Portefeuille d'exemple": b"Sentinelle portefeuille",
    b"Campagne d'exemple": b"Sentinelle campagne",
    b"Groupe d'exemple": b"Sentinelle groupe",
    b"Titre d'exemple pour les tests": b"Sentinelle titre",
    b"SKU-EXEMPLE": b"SENTINELLE-SKU",
    "Sous-catégorie d'exemple".encode(): "Sentinelle sous-catégorie".encode(),
    "category=\"\"Catégorie d'exemple\"\"".encode(): b'category=""Sentinelle ciblage""',
    "Catégorie d'exemple".encode(): "Sentinelle catégorie produit".encode(),
    b"Groupe de produits d'exemple": b"Sentinelle groupe de produits",
    b"Marketplace d'exemple": b"Sentinelle marketplace",
    b"terme d'exemple": b"terme Sentinelle",
}
NEVER_IN_MAPPING = ["Sentinelle compte", "Sentinelle portefeuille", "SENTINELLE-SKU", "Sentinelle sous-catégorie",
                    "Sentinelle catégorie produit", "Sentinelle groupe de produits", "Sentinelle marketplace"]


def sentinel(content: bytes) -> bytes:
    for old, new in SENTINELS.items():
        content = content.replace(old, new)
    return content


def text_columns_with(pg, schema: str, pattern: str) -> list[str]:
    """Colonnes texte (ou tableaux de texte) des tables du schéma qui contiennent le motif."""
    found = []
    columns = pg.query(
        "SELECT c.table_name, c.column_name FROM information_schema.columns c "
        "JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name "
        "WHERE c.table_schema = %s AND t.table_type = 'BASE TABLE' AND c.data_type IN ('text', 'ARRAY')",
        (schema,))
    for table, column in columns:
        (hit,) = pg.query(f"SELECT EXISTS (SELECT 1 FROM {schema}.{table} WHERE {column}::text ILIKE %s)",
                          (pattern,))[0]
        if hit:
            found.append(f"{table}.{column}")
    return found


def test_aucun_texte_n_atteint_staging(pg, tmp_path):
    ap, st = sentinel(fixture(AP_1205)), sentinel(fixture(ST_1205))
    for old in SENTINELS:
        assert old not in ap and old not in st
    deposit(pg, tmp_path, {AP_1205: ap, ST_1205: st})
    # Une colonne d'échec aussi : un fichier au motif refusé, dans un fichier qui contient des sentinelles
    deposit(pg, tmp_path, {"Search_term_-_12_08_2026T10_00_00.csv": st.replace(b"\r\nEUR,", b"\r\nXXX,", 1)})
    result, logs = run(pg)
    assert len(result.report.failures) == 1
    # Ni STAGING (toutes ses colonnes texte, y compris motifs et bilan), ni la sortie
    assert text_columns_with(pg, "staging", "%sentinelle%") == []
    assert "sentinelle" not in logs.lower()
    # Contrôle positif du détecteur : les textes à coder sont bien dans mapping (et seulement là)
    assert text_columns_with(pg, "mapping", "%sentinelle%") == ["text_code.key"]
    natures = {n for (n,) in pg.query("SELECT DISTINCT nature FROM mapping.text_code WHERE key ILIKE '%%sentinelle%%'")}
    assert natures == {"campaign", "ad_group", "product_title", "search_term", "targeting"}
    for value in NEVER_IN_MAPPING:  # écartés : jamais codés, jamais stockés
        assert pg.query("SELECT count(*) FROM mapping.text_code WHERE key LIKE %s", (f"%{value}%",)) == [(0,)]


class RecordingConnection:
    """Enregistre chaque requête transmise par conn.execute, avec ses paramètres."""

    def __init__(self, conn):
        self._conn = conn
        self.calls = []

    def execute(self, query, params=None):
        self.calls.append((query, params))
        return self._conn.execute(query, params)

    def __getattr__(self, name):
        return getattr(self._conn, name)


def test_textes_en_parametres_lies(pg, tmp_path):
    deposit(pg, tmp_path, {ST_1205: sentinel(fixture(ST_1205))})
    conn = RecordingConnection(pg.transformer)
    extract_reports(PgAdsTransformerRepository(conn), pg.raw_dir, log=lambda m: None)
    assert all("sentinelle" not in query.lower() for query, _ in conn.calls)
    coded = [params for query, params in conn.calls if query == CODE_SQL]
    assert ("search_term", "terme Sentinelle") in coded
    assert all(isinstance(p, tuple) and len(p) == 2 for p in coded)


# --- Fraîcheur, dans l'extraction des captures ---------------------------------------------------------

def test_fraicheur_regle():
    latest = {"advertised_product": date(2026, 12, 5), "search_term": None}
    assert ads_freshness(latest, date(2026, 12, 14)) == [
        "Aucun rapport Amazon Ads Search term de moins de 10 jours (aucun reçu)"]
    assert ads_freshness(latest, date(2026, 12, 15))[0] == (
        "Aucun rapport Amazon Ads Advertised product de moins de 10 jours (dernier : export du 2026-12-05)")


def test_fraicheur_dans_le_bilan_des_captures(pg, tmp_path):
    deposit(pg, tmp_path, {AP_1205: fixture(AP_1205), ST_1205: fixture(ST_1205)})
    logs = []
    result = extract(PgTransformerRepository(pg.transformer), pg.raw_dir, log=logs.append, today=date(2026, 12, 20))
    assert result.status == "success"  # information seulement, sans effet sur le code
    text = "\n".join(logs)
    assert "Aucun rapport Amazon Ads Advertised product de moins de 10 jours (dernier : export du 2026-12-05)" in text
    logs.clear()
    extract(PgTransformerRepository(pg.transformer), pg.raw_dir, log=logs.append, today=date(2026, 12, 10))
    assert "Aucun rapport Amazon Ads" not in "\n".join(logs)


def test_books_collector_sans_droit_sur_staging(pg):
    for conn in (pg.connect_collector(),):
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute("SELECT 1 FROM staging.ads_product_day")
