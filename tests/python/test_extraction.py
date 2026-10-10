"""Tests de books.transformer.extraction (décision 011).

Contre un PostgreSQL 17 jetable (migrations 001 à 005), sous le rôle books_transformer : lancement par
bash tests/lancer-tests-postgres.sh (sinon, ces tests sont sautés). Un faux dépôt ne sert qu'au cas difficile
à provoquer : la connexion perdue en cours d'extraction.
"""

import gzip

import psycopg
import pytest

from books.transformer import extraction
from books.transformer.extraction import EXIT_CODES, ExtractionBusy, extract
from books.transformer.parsing import EXTRACTOR_VERSION, ParseError
from books.transformer.repository import PgTransformerRepository, RawPageRef
from conftest import FIXTURES


def page(name: str) -> bytes:
    return (FIXTURES / name).read_bytes()


COMPLETE = page("extraction_page1_complete.html")
THIRTY = page("extraction_page1_30_cartes.html")
FREE = page("extraction_gratuit.html")


def run(pg, **kwargs):
    logs = []
    result = extract(PgTransformerRepository(pg.transformer), pg.raw_dir, log=logs.append, **kwargs)
    return result, logs


def pages_by_status(pg):
    return dict(pg.query("SELECT raw_page_id, status FROM staging.page_extraction ORDER BY raw_page_id"))


def rows_of(pg, page_id):
    return pg.query("SELECT extract_run_id, count(*) FROM staging.ranking_entry WHERE raw_page_id = %s "
                    "GROUP BY 1", (page_id,))


# --- Extraction normale, page à jour, changement de version ---------------------------------------

def test_extraction_de_trois_pages(pg):
    ids = [pg.add_page(COMPLETE), pg.add_page(THIRTY), pg.add_page(FREE, list_type="free")]
    result, logs = run(pg)
    assert result.status == "success" and EXIT_CODES[result.status] == 0
    report = result.report
    assert (report.to_extract, report.extracted, report.rows, report.rows_with_card) == (3, 3, 150, 130)
    assert pages_by_status(pg) == {i: "ok" for i in ids}
    assert pg.query("SELECT count(*), count(*) FILTER (WHERE has_card) FROM staging.ranking_entry") == [(150, 130)]
    # Exécution close, bilan enregistré et affiché
    assert pg.query("SELECT extractor_version, status, pages_extracted, pages_failed FROM staging.extract_run "
                    "WHERE id = %s", (result.run_id,)) == [(EXTRACTOR_VERSION, "success", 3, 0)]
    (notes,) = pg.query("SELECT notes FROM staging.extract_run WHERE id = %s", (result.run_id,))[0]
    assert notes == result.notes == "\n".join(logs)
    assert "Extraites            : 3 (150 lignes, dont 130 avec carte et 20 sans carte)" in notes


def test_seconde_execution_pages_deja_a_jour(pg):
    pg.add_page(COMPLETE)
    pg.add_page(THIRTY)
    first, _ = run(pg)
    second, _ = run(pg)
    assert (second.report.to_extract, second.report.up_to_date, second.report.extracted) == (0, 2, 0)
    assert second.status == "success"
    # Les lignes sont toujours celles de la première exécution
    assert {r[0] for r in pg.query("SELECT extract_run_id FROM staging.ranking_entry")} == {first.run_id}


def test_changement_de_version_reextrait(pg):
    ids = [pg.add_page(COMPLETE), pg.add_page(THIRTY)]
    run(pg)
    result, _ = run(pg, extractor_version="version-suivante")
    assert (result.report.to_extract, result.report.up_to_date, result.report.extracted) == (2, 0, 2)
    for page_id in ids:
        assert rows_of(pg, page_id) == [(result.run_id, 50)]  # nouvelles lignes seulement
    assert pg.query("SELECT DISTINCT er.extractor_version FROM staging.page_extraction pe "
                    "JOIN staging.extract_run er ON er.id = pe.extract_run_id") == [("version-suivante",)]


def test_reextraction_forcee(pg):
    page_id = pg.add_page(COMPLETE)
    run(pg)
    result, logs = run(pg, force=True)
    assert result.report.extracted == 1 and rows_of(pg, page_id) == [(result.run_id, 50)]
    assert "réextraction complète demandée" in logs[0]


# --- Pages en échec : n'arrêtent pas les suivantes ------------------------------------------------

def test_page_en_echec_d_analyse_n_arrete_pas_les_suivantes(pg):
    bad = pg.add_page(COMPLETE.replace("4,99&nbsp;€".encode(), "4,99 €".encode()))  # première page, en échec
    good = pg.add_page(THIRTY)
    result, _ = run(pg)
    assert result.status == "partial" and EXIT_CODES[result.status] == 1
    assert pages_by_status(pg) == {bad: "parse_failed", good: "ok"}
    assert rows_of(pg, bad) == [] and rows_of(pg, good) == [(result.run_id, 50)]
    (message,) = pg.query("SELECT error_message FROM staging.page_extraction WHERE raw_page_id = %s", (bad,))[0]
    assert message == "rang 1 : prix de forme inconnue '4,99 €'"
    assert f"(page RAW {bad}) : rang 1 : prix de forme inconnue" in result.notes
    assert pg.query("SELECT status, pages_extracted, pages_failed FROM staging.extract_run WHERE id = %s",
                    (result.run_id,)) == [("partial", 1, 1)]


def test_reextraction_en_echec_supprime_les_anciennes_lignes(pg, monkeypatch):
    page_id = pg.add_page(COMPLETE)
    run(pg)
    assert rows_of(pg, page_id)[0][1] == 50

    def failing(content):  # nouvelle version de l'extracteur, qui échoue sur cette page
        raise ParseError("rang 7 : forme nouvelle")
    monkeypatch.setattr(extraction, "parse_ranking_page", failing)
    result, _ = run(pg, extractor_version="version-suivante")
    assert result.status == "partial"
    assert rows_of(pg, page_id) == []  # aucune ligne de l'ancienne version ne subsiste
    assert pg.query("SELECT extract_run_id, status, error_message, entry_count FROM staging.page_extraction "
                    "WHERE raw_page_id = %s", (page_id,)) == [(result.run_id, "parse_failed", "rang 7 : forme nouvelle", 0)]


def test_page_en_echec_reprise_puis_reussie(pg, monkeypatch):
    page_id = pg.add_page(COMPLETE)
    monkeypatch.setattr(extraction, "parse_ranking_page", lambda content: (_ for _ in ()).throw(ParseError("x")))
    assert run(pg)[0].status == "partial"
    monkeypatch.undo()
    result, _ = run(pg)  # même version : la page en échec est reprise
    assert result.status == "success" and pages_by_status(pg) == {page_id: "ok"}


# --- Intégrité ---------------------------------------------------------------------------------------

def _rewrite(path, content: bytes) -> None:
    """Remplace un fichier RAW de la base de test (jamais un vrai fichier RAW) ; il est en lecture seule ailleurs."""
    path.chmod(0o644)
    path.write_bytes(content)


@pytest.mark.parametrize("alteration, motif", [
    ("octet-modifie", "empreinte SHA-256 différente"),
    ("taille-differente", "taille différente"),
    ("absent", "fichier RAW absent"),
    ("non-gzip", "fichier RAW non décompressible"),
])
def test_anomalie_d_integrite(pg, alteration, motif):
    altered = pg.add_page(COMPLETE)
    good = pg.add_page(THIRTY)
    path = pg.raw_file(altered)
    original = gzip.decompress(path.read_bytes())
    if alteration == "octet-modifie":  # même taille, un octet changé
        _rewrite(path, gzip.compress(original.replace(b"4,99", b"4,98", 1), mtime=0))
    elif alteration == "taille-differente":
        _rewrite(path, gzip.compress(original + b" ", mtime=0))
    elif alteration == "absent":
        path.unlink()
    else:
        _rewrite(path, original)
    result, _ = run(pg)
    assert result.status == "partial" and result.report.integrity_failures and not result.report.parse_failures
    assert pages_by_status(pg) == {altered: "integrity_failed", good: "ok"}
    (message,) = pg.query("SELECT error_message FROM staging.page_extraction WHERE raw_page_id = %s", (altered,))[0]
    assert motif in message
    assert rows_of(pg, altered) == []


# --- Hors périmètre, verrou ---------------------------------------------------------------------------

def test_pages_hors_perimetre_comptees_au_bilan(pg):
    pg.add_page(COMPLETE)
    pg.add_page(COMPLETE, method="manual-html")
    pg.add_page(COMPLETE, method=None)
    pg.add_page(COMPLETE, status="blocked")
    result, _ = run(pg)
    assert result.report.extracted == 1 and result.status == "success"  # hors périmètre : pas une anomalie
    assert result.report.out_of_scope == {"méthode manual-html": 1, "méthode non enregistrée": 1, "statut blocked": 1}
    assert ("Hors périmètre       : 3 (méthode manual-html : 1, méthode non enregistrée : 1, statut blocked : 1)"
            in result.notes)


def test_verrou_occupe_aucune_execution(pg):
    pg.add_page(COMPLETE)
    with pg.connect_transformer() as other:
        assert PgTransformerRepository(other).try_lock()
        with pytest.raises(ExtractionBusy, match="extraction déjà en cours"):
            run(pg)
    assert pg.query("SELECT count(*) FROM staging.extract_run") == [(0,)]
    assert pg.query("SELECT count(*) FROM staging.page_extraction") == [(0,)]


def test_rien_a_extraire(pg):
    result, _ = run(pg)
    assert result.status == "success" and result.report.to_extract == 0


# --- Connexion perdue (faux dépôt) ----------------------------------------------------------------------

class LostConnectionRepo:
    """Faux dépôt : la connexion est perdue à l'écriture de la première page, et ne permet plus la clôture."""

    def __init__(self, raw_page: RawPageRef):
        self.page = raw_page
        self.closed = None

    def try_lock(self):
        return True

    def open_run(self, version):
        return 7

    def out_of_scope(self):
        return {}

    def count_up_to_date(self, version):
        return 0

    def pages_to_extract(self, version, force):
        return [self.page]

    def save_extraction(self, run_id, raw_page_id, page):
        raise psycopg.OperationalError("connexion perdue")

    def save_failure(self, *args):
        raise AssertionError("non attendu")

    def close_run(self, *args):
        raise psycopg.OperationalError("connexion perdue")


def test_connexion_perdue_erreur_conservee_et_signalee(pg):
    page_id = pg.add_page(COMPLETE)
    ref = PgTransformerRepository(pg.transformer).pages_to_extract("1", force=False)[0]
    assert ref.id == page_id
    logs = []
    with pytest.raises(psycopg.OperationalError, match="connexion perdue"):
        extract(LostConnectionRepo(ref), pg.raw_dir, log=logs.append)
    assert "Erreur d'exécution : OperationalError : connexion perdue" in logs
    assert "Résultat : failed, 0 anomalie(s)" in logs
    assert logs[-1].startswith("Clôture de l'exécution 7 impossible")


# --- Noms de la catégorie (décision 014) ----------------------------------------------------------

H1 = b'<h1 class="a-size-large a-spacing-medium a-text-bold"> Les meilleures ventes en '


def test_noms_de_categorie_enregistres(pg):
    page_id = pg.add_page(COMPLETE)
    result, _ = run(pg)
    assert pg.query("SELECT display_name, short_name FROM staging.category_observation WHERE raw_page_id = %s",
                    (page_id,)) == [("Catégorie d'exemple - ebooks", "Catégorie d'exemple")]
    assert (result.report.without_display_name, result.report.without_short_name) == (0, 0)


def test_page_sans_nom_lu_comptee_sans_anomalie(pg):
    assert COMPLETE.count(H1) == 1
    without = pg.add_page(COMPLETE.replace(H1, b"<h1> Autre libell\xc3\xa9 : "))  # <h1> de la catégorie méconnaissable
    pg.add_page(THIRTY)
    result, _ = run(pg)
    assert result.status == "success" and EXIT_CODES[result.status] == 0  # information, jamais une anomalie
    assert (result.report.without_display_name, result.report.without_short_name) == (1, 0)
    assert "Sans nom d'affichage : 1" in result.notes and "Sans nom court       : 0" in result.notes
    assert pg.query("SELECT display_name FROM staging.category_observation WHERE raw_page_id = %s",
                    (without,)) == [(None,)]
    assert rows_of(pg, without)[0][1] == 50  # les lignes de la page sont extraites


def test_passage_de_la_version_1_a_la_version_2(pg):
    page_id = pg.add_page(COMPLETE)
    run(pg, extractor_version="1")  # pages extraites par la version 1
    result, _ = run(pg)  # version courante
    assert EXTRACTOR_VERSION == "2" and result.report.extracted == 1
    assert pg.query("SELECT extract_run_id FROM staging.category_observation WHERE raw_page_id = %s",
                    (page_id,)) == [(result.run_id,)]
