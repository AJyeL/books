"""Tests de books.collector.run : déroulement d'une tournée, avec une fausse base en mémoire."""

import gzip
import hashlib
from datetime import UTC, datetime

import pytest

from books.collector.repository import PageRecord, RunInfo
from books.collector.run import EXIT_CODES, collect
from books.collector.sources import Fetched
from books.amazon.ranking_page import PageRequest

# R1 : catégorie des fixtures. R2 et R3 : catégories inventées qu'aucune fixture ne désigne
# (10000000002 est le canonical de bestsellers_autre_categorie.html : ne pas l'utiliser ici).
R1 = PageRequest("10000000001", "paid", 1)
R2 = PageRequest("10000000005", "paid", 1)
R3 = PageRequest("10000000006", "paid", 1)


class FakeRepo:
    """Remplace PostgreSQL : garde en mémoire ce que le collecteur y écrirait."""

    def __init__(self):
        self.pages: list[PageRecord] = []
        self.closed: dict | None = None

    def open_run(self, collector_version):
        return RunInfo(id=7, started_at=datetime(2026, 10, 5, 23, 0, tzinfo=UTC))

    def record_page(self, run_id, record):
        self.pages.append(record)
        return len(self.pages)

    def close_run(self, run_id, status, pages_ok, pages_failed, notes):
        self.closed = dict(status=status, pages_ok=pages_ok, pages_failed=pages_failed, notes=notes)


class FakeSource:
    """Pages servies par demande complète (PageRequest), à défaut par numéro de catégorie ;
    garde la liste des demandes reçues."""

    description = "fausse source"

    def __init__(self, pages: dict):
        self.pages = pages
        self.asked: list[PageRequest] = []

    def fetch(self, request):
        self.asked.append(request)
        content = self.pages[request] if request in self.pages else self.pages.get(request.node)
        if content is None:
            return Fetched(content=None, origin="nulle part", capture_method="manual-html", error="absente")
        return Fetched(content=content, origin=f"page {request.node}", capture_method="manual-html")


def page_for(fixture_page, node: str, fixture: str = "bestsellers_exemple.html") -> bytes:
    """Fausse page valide pour une autre catégorie inventée (seule la catégorie change)."""
    return fixture_page(fixture).replace(b"10000000001", node.encode())


def run(requests, source, repo, tmp_path):
    return collect(requests, source, repo, tmp_path, "0.1.0", log=lambda message: None)


def test_tournee_reussie(fixture_page, tmp_path):
    repo = FakeRepo()
    source = FakeSource({R1.node: page_for(fixture_page, R1.node), R2.node: page_for(fixture_page, R2.node)})
    result = run([R1, R2], source, repo, tmp_path)

    assert result.status == "success" and EXIT_CODES[result.status] == 0
    assert repo.closed["status"] == "success"
    assert (repo.closed["pages_ok"], repo.closed["pages_failed"]) == (2, 0)
    assert [p.fetch_status for p in repo.pages] == ["ok", "ok"]
    # Chaque page est déposée, et l'empreinte enregistrée correspond au contenu reçu
    for request, record in zip([R1, R2], repo.pages):
        stored = record.stored
        assert stored.relative_path == f"amazon_fr/2026/10/05/run-7/bestsellers_{request.node}_paid_p1.html.gz"
        content = gzip.decompress((tmp_path / stored.relative_path).read_bytes())
        assert content == source.pages[request.node]
        assert stored.sha256 == hashlib.sha256(content).hexdigest()
    assert "liste courte (5 rangs sur 50)" in repo.closed["notes"]


def test_page_non_obtenue_tournee_partielle(fixture_page, tmp_path):
    repo = FakeRepo()
    result = run([R1, R2], FakeSource({R1.node: page_for(fixture_page, R1.node)}), repo, tmp_path)

    assert result.status == "partial" and EXIT_CODES[result.status] == 1
    assert [p.fetch_status for p in repo.pages] == ["ok", "network_error"]
    assert repo.pages[1].stored is None
    assert repo.pages[1].error_message == "absente"


def test_aucune_page_obtenue_tournee_en_echec(tmp_path):
    repo = FakeRepo()
    result = run([R1, R2], FakeSource({}), repo, tmp_path)
    # Le programme a fonctionné : anomalies, pas erreur d'exécution (décision 008)
    assert result.status == "partial" and EXIT_CODES[result.status] == 1
    assert (repo.closed["pages_ok"], repo.closed["pages_failed"]) == (0, 2)


@pytest.mark.parametrize("fixture, status", [
    ("bestsellers_captcha.html", "blocked"),
    ("bestsellers_sans_rang.html", "invalid"),
    ("bestsellers_autre_categorie.html", "invalid"),
])
def test_page_anormale_deposee_et_tournee_continue(fixture_page, tmp_path, fixture, status):
    repo = FakeRepo()
    source = FakeSource({
        R1.node: page_for(fixture_page, R1.node),
        R2.node: fixture_page(fixture),  # page anormale pour la 2e catégorie
        R3.node: page_for(fixture_page, R3.node),
    })
    result = run([R1, R2, R3], source, repo, tmp_path)

    assert result.status == "partial" and EXIT_CODES[result.status] == 1
    # La tournée continue : la 3e catégorie est demandée et déposée (décision 008)
    assert source.asked == [R1, R2, R3]
    assert [p.fetch_status for p in repo.pages] == ["ok", status, "ok"]
    # La page anormale est conservée dans RAW, avec la raison du rejet
    anomalous = repo.pages[1]
    assert anomalous.stored is not None
    assert (tmp_path / anomalous.stored.relative_path).exists()
    assert anomalous.error_message
    assert (repo.closed["pages_ok"], repo.closed["pages_failed"]) == (2, 1)
    assert f"Anomalie : {R2.label} : {status}" in repo.closed["notes"]


def test_titre_captcha_ne_bloque_pas(fixture_page, tmp_path):
    repo = FakeRepo()
    source = FakeSource({R1.node: fixture_page("bestsellers_titre_captcha.html")})
    assert run([R1], source, repo, tmp_path).status == "success"


def test_erreur_imprevue_tournee_close_en_echec(fixture_page, tmp_path):
    class BrokenSource(FakeSource):
        def fetch(self, request):
            if request == R2:
                raise RuntimeError("panne simulée")
            return super().fetch(request)

    repo = FakeRepo()
    source = BrokenSource({R1.node: page_for(fixture_page, R1.node)})
    with pytest.raises(RuntimeError, match="panne simulée"):
        run([R1, R2], source, repo, tmp_path)
    # La tournée est quand même close, avec la trace de l'erreur
    assert repo.closed["status"] == "failed"
    assert repo.closed["pages_ok"] == 1
    assert "panne simulée" in repo.closed["notes"]


def test_fichier_existant_jamais_ecrase(fixture_page, tmp_path):
    existing = tmp_path / "amazon_fr/2026/10/05/run-7/bestsellers_10000000001_paid_p1.html.gz"
    existing.parent.mkdir(parents=True)
    existing.write_bytes(b"deja la")
    repo = FakeRepo()
    with pytest.raises(FileExistsError):
        run([R1], FakeSource({R1.node: page_for(fixture_page, R1.node)}), repo, tmp_path)
    assert existing.read_bytes() == b"deja la"
    assert repo.pages == []  # aucune ligne ne pointe vers un fichier qui n'est pas le sien
    assert repo.closed["status"] == "failed"


def test_page_gratuite_servie_pour_le_payant_refusee(fixture_page, tmp_path):
    # Le cas qui a motivé la triangulation : même catégorie, même canonical, mauvaise liste
    repo = FakeRepo()
    source = FakeSource({R1.node: fixture_page("bestsellers_gratuit.html")})
    result = run([R1], source, repo, tmp_path)
    assert result.status == "partial"
    assert repo.pages[0].fetch_status == "invalid"
    assert "onglet actif" in repo.pages[0].error_message


def test_trou_de_rangs_note_sans_changer_le_statut(fixture_page, tmp_path):
    repo = FakeRepo()
    result = run([R1], FakeSource({R1.node: fixture_page("bestsellers_rang_trou.html")}), repo, tmp_path)
    assert result.status == "success"
    assert "suite de rangs non continue" in repo.closed["notes"]


# --- Page 2 conditionnelle : 50 rangs ET pagination annonçant la page 2 ------

P1 = R1
P2 = PageRequest(R1.node, "paid", 2)
F1 = PageRequest(R1.node, "free", 1)
F2 = PageRequest(R1.node, "free", 2)


def test_page_2_demandee_juste_apres_sa_page_1(fixture_page, tmp_path):
    repo = FakeRepo()
    source = FakeSource({
        P1: fixture_page("bestsellers_page1_complete.html"),
        P2: fixture_page("bestsellers_page2.html"),
        F1: fixture_page("bestsellers_gratuit.html"),
    })
    result = run([P1, F1], source, repo, tmp_path)

    # Ordre : payant p1, payant p2, puis gratuit p1 ; la fixture gratuite (5 rangs) n'entraîne pas de page 2
    assert source.asked == [P1, P2, F1]
    assert result.status == "success"
    assert [p.request for p in repo.pages] == [P1, P2, F1]
    assert repo.pages[1].stored.relative_path.endswith("bestsellers_10000000001_paid_p2.html.gz")
    assert "Requêtes : 3." in repo.closed["notes"]


def test_liste_courte_sans_page_2_ni_manquante(fixture_page, tmp_path):
    repo = FakeRepo()
    source = FakeSource({P1: fixture_page("bestsellers_liste_courte.html")})
    result = run([P1], source, repo, tmp_path)
    assert source.asked == [P1]
    assert result.status == "success"
    assert (repo.closed["pages_ok"], repo.closed["pages_failed"]) == (1, 0)
    assert "non attendue" not in repo.closed["notes"]  # signaux concordants : rien d'anormal


def test_50_rangs_sans_pagination_divergence_signalee(fixture_page, tmp_path):
    repo = FakeRepo()
    source = FakeSource({P1: fixture_page("bestsellers_page1_complete_sans_pagination.html")})
    result = run([P1], source, repo, tmp_path)
    # On ne demande jamais une page que le site n'annonce pas ; elle n'est pas comptée comme manquante
    assert source.asked == [P1]
    assert result.status == "success"
    assert repo.closed["pages_failed"] == 0
    assert "50 rangs, mais la pagination n'annonce pas de page 2 : page 2 non attendue" in repo.closed["notes"]


def test_page_2_annoncee_mais_moins_de_50_rangs_divergence_signalee(fixture_page, tmp_path):
    repo = FakeRepo()
    source = FakeSource({P1: fixture_page("bestsellers_exemple.html")})  # 5 rangs, lien « Page 2 »
    result = run([P1], source, repo, tmp_path)
    assert source.asked == [P1]
    assert result.status == "success"
    assert "page 2 annoncée par la pagination, mais seulement 5 rangs" in repo.closed["notes"]


def test_page_2_attendue_mais_absente(fixture_page, tmp_path):
    repo = FakeRepo()
    source = FakeSource({P1: fixture_page("bestsellers_page1_complete.html"), P2: None})
    result = run([P1], source, repo, tmp_path)
    assert source.asked == [P1, P2]
    assert result.status == "partial"
    assert [p.fetch_status for p in repo.pages] == ["ok", "network_error"]


def test_page_1_absente_page_2_jamais_demandee(tmp_path):
    repo = FakeRepo()
    source = FakeSource({P1: None})
    result = run([P1], source, repo, tmp_path)
    assert source.asked == [P1]
    assert result.status == "partial"
    assert repo.closed["pages_failed"] == 1  # seule la page 1 compte comme manquante


def test_page_2_non_conforme_tournee_continue(fixture_page, tmp_path):
    repo = FakeRepo()
    source = FakeSource({
        P1: fixture_page("bestsellers_page1_complete.html"),
        P2: fixture_page("bestsellers_exemple.html"),  # une page 1 reçue à la place de la page 2
        F1: fixture_page("bestsellers_gratuit.html"),
    })
    result = run([P1, F1], source, repo, tmp_path)
    assert result.status == "partial"
    assert source.asked == [P1, P2, F1]  # le Top gratuit est demandé malgré la page 2 non conforme
    assert [p.fetch_status for p in repo.pages] == ["ok", "invalid", "ok"]
    assert "page active 1, page demandée : 2" in repo.pages[1].error_message


def test_plafond_controle_pendant_la_tournee(fixture_page, tmp_path):
    repo = FakeRepo()
    source = FakeSource({
        P1: fixture_page("bestsellers_page1_complete.html"),
        P2: fixture_page("bestsellers_page2.html"),
        F1: fixture_page("bestsellers_gratuit.html"),
    })
    with pytest.raises(RuntimeError, match="plafond de 2 requêtes"):
        collect([P1, F1], source, repo, tmp_path, "0.1.0", log=lambda m: None, max_requests=2)
    # La page 2 compte dans le plafond : le Top gratuit n'est jamais demandé
    assert source.asked == [P1, P2]
    assert repo.closed["status"] == "failed"
    assert "plafond de 2 requêtes" in repo.closed["notes"]


def test_methode_de_capture_reportee_sur_chaque_ligne(fixture_page, tmp_path):
    repo = FakeRepo()
    source = FakeSource({P1: fixture_page("bestsellers_page1_complete.html"), P2: None})
    run([P1], source, repo, tmp_path)
    assert [(p.fetch_status, p.capture_method) for p in repo.pages] == [
        ("ok", "manual-html"), ("network_error", "manual-html")]


def test_codes_de_sortie():
    # Décision 008 : plus de code 3 ni de statut « aborted »
    assert EXIT_CODES == {"success": 0, "partial": 1, "failed": 1}
