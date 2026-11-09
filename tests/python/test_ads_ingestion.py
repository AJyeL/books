"""Tests de books.ads.ingestion : dépôt des rapports Amazon Ads dans RAW (décision 018, lot A).

En mémoire (FakeRepo), puis contre un PostgreSQL 17 jetable sous le rôle books_collector (migration 011) :
lancement par bash tests/lancer-tests-postgres.sh (sinon, ces derniers tests sont sautés).
"""

import gzip
import hashlib
import os
from datetime import UTC, date, datetime, time

import psycopg
import pytest

from books.ads import ingestion as ads_ingestion
from books.ads.ingestion import ingest_reports
from books.ads.repository import AdsRunInfo, PgAdsRepository
from books.collector.run import EXIT_CODES
from conftest import FIXTURES

ADS = FIXTURES / "ads"
AP_NAME = "Advertised_product_-_12_05_2026T19_59_56.csv"
ST_NAME = "Search_term_-_12_05_2026T20_05_45.csv"
LOT = "2026-12-05T201500Z"


class FakeRepo:
    """Remplace PostgreSQL : garde en mémoire les fichiers déposés et les exécutions."""

    def __init__(self):
        self.reports = []  # (run_id, ReportRecord)
        self.runs = {}
        self.next_id = 6

    def open_run(self, collector_version):
        self.next_id += 1
        self.runs[self.next_id] = None
        return AdsRunInfo(id=self.next_id, started_at=datetime(2026, 12, 5, 20, 30, tzinfo=UTC))

    def record_report(self, run_id, record):
        self.reports.append((run_id, record))
        return len(self.reports)

    def close_run(self, run_id, status, files_ok, files_invalid, notes):
        self.runs[run_id] = dict(status=status, files_ok=files_ok, files_invalid=files_invalid, notes=notes)

    def find_report(self, content_sha256):
        for index, (_, record) in enumerate(self.reports, start=1):
            if record.stored.sha256 == content_sha256:
                return index
        return None


@pytest.fixture
def dirs(tmp_path):
    ads = tmp_path / "ads"
    (ads / "inbox").mkdir(parents=True)
    raw = tmp_path / "raw-ads"  # « raw » est pris par la fixture pg
    raw.mkdir()
    return ads, raw


def put(ads, name, content, lot=LOT):
    folder = ads / "inbox" / lot
    folder.mkdir(exist_ok=True)
    (folder / name).write_bytes(content)
    return folder / name


def run(ads, raw, repo, journal=None):
    return ingest_reports(ads, repo, raw, "0.9.0", log=(journal.append if journal is not None else lambda m: None))


# --- En mémoire --------------------------------------------------------------------------------

def test_depot_ok_et_invalid(dirs):
    ads, raw = dirs
    ap = (ADS / AP_NAME).read_bytes()
    put(ads, AP_NAME, ap)
    put(ads, "Termes_hebdo.csv", (ADS / ST_NAME).read_bytes())  # nom choisi librement : jamais jugé
    put(ads, "Search_term_-_11_03_2026T19_21_35.csv",
        (ADS / ST_NAME).read_bytes().replace(b",Date,", b",Plage de dates,"))
    repo = FakeRepo()
    result = run(ads, raw, repo)
    assert result.status == "partial"  # un fichier invalid est une anomalie
    records = {r.original_name: r for _, r in repo.reports}
    assert records[AP_NAME].status == "ok"
    assert (records[AP_NAME].report_type, records[AP_NAME].export_date, records[AP_NAME].export_time) == (
        "advertised_product", date(2026, 12, 5), time(19, 59, 56))
    libre = records["Termes_hebdo.csv"]
    assert (libre.status, libre.report_type, libre.export_date, libre.export_time) == ("ok", "search_term", None, None)
    invalid = records["Search_term_-_11_03_2026T19_21_35.csv"]
    assert (invalid.status, invalid.report_type) == ("invalid", "search_term")
    assert "Plage de dates" in invalid.reason
    # Fichier déposé intact (octet pour octet une fois décompressé), empreinte de l'original, rangé par exécution
    stored = records[AP_NAME].stored
    sha = hashlib.sha256(ap).hexdigest()
    assert (stored.sha256, stored.size) == (sha, len(ap))
    assert stored.relative_path == f"amazon_ads/2026/12/05/run-7/{sha}.csv.gz"
    assert gzip.decompress((raw / stored.relative_path).read_bytes()) == ap
    # inbox/ vidée, lot supprimé ; bilan et compteurs
    assert not any((ads / "inbox").iterdir())
    assert repo.runs[7]["files_ok"] == 2 and repo.runs[7]["files_invalid"] == 1
    assert "Déposés invalid    : 1" in repo.runs[7]["notes"]
    assert f"{LOT}/{AP_NAME} : Advertised product, horodatage du nom 2026-12-05" in repo.runs[7]["notes"]
    assert f"{LOT}/Termes_hebdo.csv : Search term, sans horodatage dans le nom" in repo.runs[7]["notes"]


def test_tout_ok_code_0(dirs):
    ads, raw = dirs
    put(ads, AP_NAME, (ADS / AP_NAME).read_bytes())
    put(ads, ST_NAME, (ADS / ST_NAME).read_bytes())
    result = run(ads, raw, FakeRepo())
    assert (result.status, EXIT_CODES[result.status]) == ("success", 0)


def test_bilan_sans_valeur_des_lignes(dirs):
    ads, raw = dirs
    put(ads, ST_NAME, (ADS / ST_NAME).read_bytes())
    content = (ADS / ST_NAME).read_bytes().replace(b",Date,", b",Plage de dates,")
    put(ads, "Search_term_-_11_03_2026T19_21_35.csv", content)
    journal = []
    repo = FakeRepo()
    run(ads, raw, repo, journal)
    texte = "\n".join(journal) + repo.runs[7]["notes"]
    assert "Plage de dates" in texte
    for valeur in ("Sentinelle", "Campagne d'exemple", "B0FAUX", "SKU-EXEMPLE", "terme d'exemple"):
        assert valeur not in texte


def test_deja_ingere_retire_sans_anomalie(dirs):
    ads, raw = dirs
    ap = (ADS / AP_NAME).read_bytes()
    repo = FakeRepo()
    put(ads, AP_NAME, ap)
    run(ads, raw, repo)
    # Le même fichier revient, sous un autre nom et dans un autre lot, et deux fois dans le même lot
    put(ads, "copie_12_05_2026T19_59_56.csv", ap, lot="2026-12-06T080000Z")
    put(ads, "copie2_12_05_2026T19_59_56.csv", ap, lot="2026-12-06T080000Z")
    result = run(ads, raw, repo)
    assert result.status == "success"
    assert len(repo.reports) == 1
    assert len(result.report.already) == 2
    assert not any((ads / "inbox").iterdir())


def test_meme_fichier_deux_fois_dans_un_lot(dirs):
    ads, raw = dirs
    ap = (ADS / AP_NAME).read_bytes()
    put(ads, AP_NAME, ap)
    put(ads, "doublon_12_05_2026T19_59_56.csv", ap)
    repo = FakeRepo()
    result = run(ads, raw, repo)
    assert len(repo.reports) == 1 and len(result.report.already) == 1


def test_laisses_en_place(dirs, monkeypatch):
    ads, raw = dirs
    monkeypatch.setattr(ads_ingestion, "MAX_FILE_BYTES", 100)  # 20 Mo, ramenés à 100 octets pour le test
    put(ads, AP_NAME, (ADS / AP_NAME).read_bytes())  # plus de 100 octets
    (ads / "inbox" / LOT / "sous-dossier").mkdir()
    (ads / "inbox" / "hors-lot.csv").write_bytes(b"x")
    (ads / "inbox" / "lot-mal-nomme").mkdir()
    repo = FakeRepo()
    result = run(ads, raw, repo)
    assert result.status == "partial"
    assert repo.reports == []
    texte = "\n".join(result.report.left_in_place)
    for attendu in ("plus de 20 Mo", "sous-dossier dans un lot", "hors-lot.csv : élément hors de tout lot",
                    "lot-mal-nomme : dossier de lot au nom hors format"):
        assert attendu in texte
    assert (ads / "inbox" / LOT / AP_NAME).exists()  # rien n'est supprimé


@pytest.mark.skipif(not hasattr(os, "symlink") or os.name == "nt", reason="liens symboliques : Linux seulement")
def test_lien_symbolique_laisse_en_place(dirs, tmp_path):
    ads, raw = dirs
    cible = tmp_path / "ailleurs.csv"
    cible.write_bytes((ADS / AP_NAME).read_bytes())
    (ads / "inbox" / LOT).mkdir()
    os.symlink(cible, ads / "inbox" / LOT / AP_NAME)
    repo = FakeRepo()
    result = run(ads, raw, repo)
    assert repo.reports == [] and "pas un fichier ordinaire" in result.report.left_in_place[0]


def test_lots_dans_l_ordre(dirs):
    ads, raw = dirs
    put(ads, ST_NAME, (ADS / ST_NAME).read_bytes(), lot="2026-12-06T080000Z")
    put(ads, AP_NAME, (ADS / AP_NAME).read_bytes(), lot="2026-12-05T080000Z")
    repo = FakeRepo()
    run(ads, raw, repo)
    assert [r.lot for _, r in repo.reports] == ["2026-12-05T080000Z", "2026-12-06T080000Z"]


def test_fichier_brut_jamais_ecrase(dirs):
    ads, raw = dirs
    ap = (ADS / AP_NAME).read_bytes()
    sha = hashlib.sha256(ap).hexdigest()
    existant = raw / "amazon_ads/2026/12/05/run-7" / f"{sha}.csv.gz"
    existant.parent.mkdir(parents=True)
    existant.write_bytes(b"deja la")
    put(ads, AP_NAME, ap)
    repo = FakeRepo()
    with pytest.raises(FileExistsError):
        run(ads, raw, repo)
    assert existant.read_bytes() == b"deja la"
    assert repo.runs[7]["status"] == "failed"
    assert (ads / "inbox" / LOT / AP_NAME).exists()  # le fichier attend l'ingestion suivante


def test_dossiers_absents(tmp_path):
    with pytest.raises(FileNotFoundError):
        ingest_reports(tmp_path, FakeRepo(), tmp_path, "0.9.0", log=lambda m: None)


# --- PostgreSQL 17 jetable, rôle books_collector -------------------------------------------------

def test_pg_depot_sous_books_collector(pg, dirs):
    ads, raw = dirs
    ap = (ADS / AP_NAME).read_bytes()
    put(ads, AP_NAME, ap)
    put(ads, "Search_term_-_11_03_2026T19_21_35.csv", (ADS / ST_NAME).read_bytes().replace(b",Date,", b",Plage de dates,"))
    conn = pg.connect_collector()
    assert conn.execute("SELECT current_user").fetchone() == ("books_collector",)
    result = ingest_reports(ads, PgAdsRepository(conn), raw, "0.9.0", log=lambda m: None)
    assert result.status == "partial"
    rows = pg.query("SELECT original_name, status, report_type, export_date, export_time, reason IS NULL, "
                    "content_sha256, lot FROM raw.ads_report_file ORDER BY original_name")
    assert rows[0][:6] == (AP_NAME, "ok", "advertised_product", date(2026, 12, 5), time(19, 59, 56), True)
    assert rows[0][6:] == (hashlib.sha256(ap).hexdigest(), LOT)
    assert rows[1][:5] == ("Search_term_-_11_03_2026T19_21_35.csv", "invalid", "search_term", date(2026, 11, 3),
                           time(19, 21, 35))
    assert pg.query("SELECT status, files_ok, files_invalid, finished_at IS NOT NULL, notes LIKE '%Plage de dates%' "
                    "FROM raw.ads_ingest_run") == [("partial", 1, 1, True, True)]


def test_pg_deja_ingere(pg, dirs):
    ads, raw = dirs
    ap = (ADS / AP_NAME).read_bytes()
    repo = PgAdsRepository(pg.connect_collector())
    put(ads, AP_NAME, ap)
    ingest_reports(ads, repo, raw, "0.9.0", log=lambda m: None)
    put(ads, AP_NAME, ap, lot="2026-12-06T080000Z")
    result = ingest_reports(ads, repo, raw, "0.9.0", log=lambda m: None)
    assert result.status == "success" and len(result.report.already) == 1
    assert pg.query("SELECT count(*) FROM raw.ads_report_file") == [(1,)]


def test_pg_ajout_seul_et_droits(pg, dirs):
    ads, raw = dirs
    put(ads, AP_NAME, (ADS / AP_NAME).read_bytes())
    conn = pg.connect_collector()
    ingest_reports(ads, PgAdsRepository(conn), raw, "0.9.0", log=lambda m: None)
    # books_collector : ni modification ni suppression ; le propriétaire non plus (déclencheurs d'ajout seul)
    for sql in ("UPDATE raw.ads_report_file SET reason = 'x'", "DELETE FROM raw.ads_report_file"):
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute(sql)
        with pytest.raises(psycopg.errors.RaiseException, match="ajout seul"):
            pg.owner.execute(sql)
    # books_transformer : lecture seulement (accordée par la migration 12, lot B), jamais d'écriture
    assert pg.transformer.execute("SELECT count(*) FROM raw.ads_report_file").fetchone() == (1,)
    for sql in ("UPDATE raw.ads_report_file SET reason = 'x'", "DELETE FROM raw.ads_report_file",
                "SELECT 1 FROM raw.ads_ingest_run"):
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            pg.transformer.execute(sql)
