"""Tests de books.collector.ingestion : dépôt des captures dans RAW, quarantaine, « déjà ingérée »,
et reprise après une interruption à chaque étape (décision 008)."""

import gzip
import hashlib
import os
import shutil
from datetime import UTC, datetime

import pytest

from books.collector.ingestion import ingest
from books.collector.run import EXIT_CODES
from books.collector.repository import RunInfo
from conftest import FIXTURES

CAPTURES = FIXTURES / "captures"
PAID_P1 = "amazon_fr_bestsellers_10000000001_paid_p1_2026-10-06T200000Z"
PAID_P2 = "amazon_fr_bestsellers_10000000001_paid_p2_2026-10-06T200010Z"
FREE_P1 = "amazon_fr_bestsellers_10000000001_free_p1_2026-10-06T200020Z"
CAPTCHA = "amazon_fr_bestsellers_10000000001_paid_p1_2026-10-06T200030Z"
OUTSIDE = "amazon_fr_bestsellers_10000000009_paid_p1_2026-10-06T200040Z"
LOT = "2026-10-06T201500Z"
PERIMETER = {("10000000001", "paid"), ("10000000001", "free")}


class FakeRepo:
    """Remplace PostgreSQL : garde en mémoire les lignes et les tournées ; numérote les ingestions."""

    def __init__(self):
        self.pages = []  # (run_id, PageRecord)
        self.runs = {}
        self.next_id = 41

    def open_run(self, collector_version):
        self.next_id += 1
        self.runs[self.next_id] = None
        return RunInfo(id=self.next_id, started_at=datetime(2026, 10, 6, 20, 30, tzinfo=UTC))

    def record_page(self, run_id, record):
        self.pages.append((run_id, record))
        return len(self.pages)

    def close_run(self, run_id, status, pages_ok, pages_failed, notes):
        self.runs[run_id] = dict(status=status, pages_ok=pages_ok, pages_failed=pages_failed, notes=notes)

    def find_capture(self, content_sha256):
        for index, (_, record) in enumerate(self.pages, start=1):
            if record.capture_method == "extension-dom" and record.stored.sha256 == content_sha256:
                return index
        return None

    @property
    def last(self):
        return self.runs[self.next_id]


@pytest.fixture
def dirs(tmp_path):
    """Dossier des captures (inbox/ vide) et dossier RAW."""
    captures, raw = tmp_path / "captures", tmp_path / "raw"
    (captures / "inbox").mkdir(parents=True)
    raw.mkdir()
    return captures, raw


def add(captures, *stems, lot=LOT, suffixes=(".html", ".json")):
    lot_dir = captures / "inbox" / lot
    lot_dir.mkdir(exist_ok=True)
    for stem in stems:
        for suffix in suffixes:
            shutil.copy(CAPTURES / f"{stem}{suffix}", lot_dir / f"{stem}{suffix}")
    return lot_dir


def run(dirs, repo, **kwargs):
    captures, raw = dirs
    return ingest(captures, PERIMETER, repo, raw, "0.1.0", log=lambda m: None, **kwargs)


def inbox_files(captures):
    return sorted(p.relative_to(captures / "inbox").as_posix() for p in (captures / "inbox").rglob("*"))


# --- Dépôt -------------------------------------------------------------------------------

def test_depot_d_une_capture(dirs):
    captures, raw = dirs
    add(captures, PAID_P1, PAID_P2)  # la page 1 (50 rangs) annonce une page 2 : elle est dans le lot
    repo = FakeRepo()
    result = run(dirs, repo)

    assert result.status == "success"
    (run_id, record), _ = repo.pages
    assert record.capture_method == "extension-dom"
    assert record.fetch_status == "ok"
    assert record.fetched_at == datetime(2026, 10, 6, 20, 0, 0, tzinfo=UTC)  # captured_at
    assert record.requested_url == "https://www.amazon.fr/gp/bestsellers/digital-text/10000000001"
    assert record.stored.relative_path == (
        f"amazon_fr/2026/10/06/run-{run_id}/bestsellers_10000000001_paid_p1_2026-10-06T200000Z.html.gz")
    assert record.metadata.relative_path.endswith("_2026-10-06T200000Z.json.gz")
    # Fichiers RAW identiques aux originaux, empreintes enregistrées exactes
    html = (CAPTURES / f"{PAID_P1}.html").read_bytes()
    meta = (CAPTURES / f"{PAID_P1}.json").read_bytes()
    assert gzip.decompress((raw / record.stored.relative_path).read_bytes()) == html
    assert gzip.decompress((raw / record.metadata.relative_path).read_bytes()) == meta
    assert record.stored.sha256 == hashlib.sha256(html).hexdigest()
    assert record.metadata.sha256 == hashlib.sha256(meta).hexdigest()
    # Retirée de inbox/, lot vide supprimé
    assert inbox_files(captures) == []


def test_requested_url_est_l_adresse_affichee(dirs):
    captures, _ = dirs
    add(captures, FREE_P1)
    repo = FakeRepo()
    run(dirs, repo)
    (_, record), = repo.pages
    # L'adresse affichée est enregistrée telle quelle (décision 008), et non une adresse reconstruite
    assert record.requested_url ==         "https://www.amazon.fr/gp/bestsellers/digital-text/10000000001/ref=zg_bs?ie=UTF8&tf=1"
    assert record.request.list_type == "free"


def test_plusieurs_lots_dans_l_ordre(dirs):
    captures, _ = dirs
    add(captures, FREE_P1, lot="2026-10-06T210000Z")
    add(captures, PAID_P1, PAID_P2, lot="2026-10-06T201500Z")
    repo = FakeRepo()
    assert run(dirs, repo).status == "success"
    assert [r.request.label for _, r in repo.pages] == [
        "10000000001 paid p1", "10000000001 paid p2", "10000000001 free p1"]


def test_deux_observations_de_la_meme_page(dirs):
    captures, _ = dirs
    add(captures, PAID_P1, PAID_P2)
    lot_dir = captures / "inbox" / LOT
    # Seconde capture de la même page, une minute plus tard : contenu différent, deux observations conservées
    stem2 = PAID_P1.replace("T200000Z", "T200100Z")
    html = (CAPTURES / f"{PAID_P1}.html").read_bytes() + b"<!-- autre affichage -->"
    (lot_dir / f"{stem2}.html").write_bytes(html)
    meta = (CAPTURES / f"{PAID_P1}.json").read_text(encoding="utf-8")
    import json
    data = json.loads(meta)
    data.update(captured_at="2026-10-06T20:01:00Z", html_sha256=hashlib.sha256(html).hexdigest(), html_bytes=len(html))
    (lot_dir / f"{stem2}.json").write_text(json.dumps(data), encoding="utf-8")
    repo = FakeRepo()
    assert run(dirs, repo).status == "success"
    paid_p1 = [r for _, r in repo.pages if r.request.page_number == 1]
    assert len(paid_p1) == 2
    assert len({r.stored.relative_path for r in paid_p1}) == 2  # deux fichiers RAW distincts


def test_inbox_vide(dirs):
    repo = FakeRepo()
    result = run(dirs, repo)
    assert result.status == "success" and repo.pages == []


# --- Quarantaine et anomalies --------------------------------------------------------------

def test_quarantaine_rien_dans_raw(dirs):
    captures, raw = dirs
    add(captures, OUTSIDE, PAID_P1)
    repo = FakeRepo()
    result = run(dirs, repo)
    assert result.status == "partial"  # une anomalie
    assert [r.request.node for _, r in repo.pages] == ["10000000001"]  # seule la capture conforme est déposée
    quarantined = captures / "quarantaine" / LOT
    assert sorted(p.name for p in quarantined.iterdir()) == [
        f"{OUTSIDE}.html", f"{OUTSIDE}.json", f"{OUTSIDE}.raison.txt"]
    assert "hors périmètre" in repo.last["notes"]
    assert inbox_files(captures) == []


def test_fichiers_hors_format_et_orphelins(dirs):
    captures, _ = dirs
    lot_dir = add(captures, PAID_P1)
    shutil.copy(CAPTURES / f"{FREE_P1}.html", lot_dir / f"{FREE_P1} (1).html")
    shutil.copy(CAPTURES / f"{PAID_P2}.json", lot_dir / f"{PAID_P2}.json")       # JSON orphelin
    shutil.copy(CAPTURES / f"{FREE_P1}.html", lot_dir / f"{FREE_P1}.html")       # HTML orphelin, jamais ingéré
    (captures / "inbox" / "perdu.txt").write_text("x")                           # hors de tout lot
    repo = FakeRepo()
    result = run(dirs, repo)
    assert result.status == "partial"
    assert len(repo.pages) == 1
    notes = repo.last["notes"]
    assert "nom hors format" in notes and "JSON orphelin" in notes and "HTML orphelin" in notes
    assert "perdu.txt : fichier hors de tout lot" in notes
    assert inbox_files(captures) == ["perdu.txt"]  # seul l'élément sans lot reste


def test_capture_blocked_deposee_et_ingestion_continue(dirs):
    captures, _ = dirs
    # Ordre des noms : …_paid_p1_… (page de vérification) avant …_paid_p2_…
    add(captures, CAPTCHA, PAID_P2)
    repo = FakeRepo()
    result = run(dirs, repo)
    # Déposée avec son statut, et la suite est traitée (décision 008)
    assert result.status == "partial" and EXIT_CODES[result.status] == 1
    assert [r.fetch_status for _, r in repo.pages] == ["blocked", "ok"]
    assert inbox_files(captures) == []
    assert len(result.report.rejected_pages) == 1
    assert result.report.rejected_pages[0].startswith(f"{LOT}/{CAPTCHA} : blocked : CAPTCHA détecté")


def test_plafond_de_captures(dirs):
    captures, _ = dirs
    add(captures, PAID_P1, PAID_P2, FREE_P1)
    repo = FakeRepo()
    result = run(dirs, repo, max_captures=2)
    assert len(repo.pages) == 2
    assert result.report.cap_reached.startswith("2 captures atteint")
    assert result.report.anomalies == 1
    assert repo.last["status"] == "partial"  # des captures restent dans inbox/ : anomalie
    assert len(inbox_files(captures)) == 3  # le lot et les deux fichiers de la troisième capture


# --- « Déjà ingérée » et reprise après interruption ----------------------------------------

def test_meme_fichier_recu_deux_fois(dirs):
    captures, _ = dirs
    add(captures, PAID_P1)
    repo = FakeRepo()
    run(dirs, repo)
    add(captures, PAID_P1, lot="2026-10-06T220000Z")  # renvoyé dans un nouveau lot
    result = run(dirs, repo)
    assert result.status == "success"  # sans anomalie
    assert len(repo.pages) == 1
    assert "déjà ingérée" in repo.last["notes"]
    assert inbox_files(captures) == []


def test_interruption_apres_les_fichiers_avant_la_ligne(dirs, monkeypatch):
    captures, raw = dirs
    add(captures, FREE_P1)  # aucune page 2 attendue : seule l'interruption est testée
    repo = FakeRepo()

    def broken(run_id, record):
        raise RuntimeError("panne simulée avant la ligne")
    monkeypatch.setattr(repo, "record_page", broken)
    with pytest.raises(RuntimeError):
        run(dirs, repo)
    assert repo.last["status"] == "failed"
    first_run = repo.next_id
    assert any((raw / "amazon_fr/2026/10/06" / f"run-{first_run}").iterdir())  # fichiers écrits, sans ligne
    assert len(inbox_files(captures)) == 3  # capture toujours dans inbox/

    monkeypatch.undo()
    result = run(dirs, repo)
    assert result.status == "success"
    (run_id, record), = repo.pages
    assert run_id == first_run + 1  # déposée normalement, dans un nouveau dossier run-{id}
    assert inbox_files(captures) == []


def test_interruption_apres_la_ligne_avant_le_retrait(dirs, monkeypatch):
    captures, _ = dirs
    add(captures, PAID_P1)
    repo = FakeRepo()

    def broken(path):
        raise OSError("panne simulée avant le retrait")
    monkeypatch.setattr(os, "remove", broken)
    with pytest.raises(OSError):
        run(dirs, repo)
    assert len(repo.pages) == 1 and len(inbox_files(captures)) == 3

    monkeypatch.undo()
    result = run(dirs, repo)
    assert result.status == "success"
    assert len(repo.pages) == 1  # aucune nouvelle ligne
    assert "déjà ingérée" in repo.last["notes"]
    assert inbox_files(captures) == []


def test_interruption_entre_le_json_et_le_html(dirs, monkeypatch):
    captures, _ = dirs
    add(captures, PAID_P1)
    repo = FakeRepo()
    real_remove = os.remove
    calls = []

    def remove_json_then_fail(path):
        calls.append(path)
        if len(calls) == 2:
            raise OSError("panne simulée entre le JSON et le HTML")
        real_remove(path)
    monkeypatch.setattr(os, "remove", remove_json_then_fail)
    with pytest.raises(OSError):
        run(dirs, repo)
    assert str(calls[0]).endswith(".json")
    assert inbox_files(captures) == [LOT, f"{LOT}/{PAID_P1}.html"]  # HTML resté seul

    monkeypatch.undo()
    result = run(dirs, repo)
    assert result.status == "success"  # reconnu « déjà ingérée », pas pris pour un orphelin
    assert len(repo.pages) == 1
    assert "déjà ingérée (HTML resté seul)" in repo.last["notes"]
    assert inbox_files(captures) == []
    assert not (captures / "quarantaine").exists()


def test_dossier_inbox_absent(tmp_path):
    with pytest.raises(FileNotFoundError, match="inbox"):
        ingest(tmp_path, PERIMETER, FakeRepo(), tmp_path, "0.1.0", log=lambda m: None)


# --- Page 2 manquante au sein du lot, bilan, statuts ---------------------------------------

def make_capture(lot_dir, fixture, node, list_type, page, stamp, url_tail=""):
    """Capture conforme (décision 007) construite à partir d'une fausse page : empreinte et taille exactes."""
    import json
    page_html = (FIXTURES / fixture).read_text(encoding="utf-8").replace("10000000001", node)
    html = ("<!DOCTYPE html>" + page_html[len("<!doctype html>"):]).encode("utf-8")
    stem = f"amazon_fr_bestsellers_{node}_{list_type}_p{page}_{stamp}"
    meta = {"schema_version": 1,
            "displayed_url": f"https://www.amazon.fr/gp/bestsellers/digital-text/{node}{url_tail}",
            "captured_at": f"{stamp[:13]}:{stamp[13:15]}:{stamp[15:17]}Z",
            "capture_method": "extension-dom", "extension_version": "0.1.1", "user_agent": "test",
            "html_sha256": hashlib.sha256(html).hexdigest(), "html_bytes": len(html)}
    lot_dir.mkdir(parents=True, exist_ok=True)
    (lot_dir / f"{stem}.html").write_bytes(html)
    (lot_dir / f"{stem}.json").write_text(json.dumps(meta), encoding="utf-8")
    return stem


def test_page_2_manquante_dans_le_lot(dirs):
    captures, _ = dirs
    add(captures, PAID_P1)  # 50 rangs, page 2 annoncée, mais pas de page 2 dans le lot
    repo = FakeRepo()
    result = run(dirs, repo)
    assert result.status == "partial"
    assert result.report.missing_page2 == [f"10000000001 paid : page 2 annoncée, absente du lot {LOT}"]
    assert result.report.anomalies == 1


def test_page_2_presente_dans_le_lot(dirs):
    captures, _ = dirs
    add(captures, PAID_P1, PAID_P2)
    repo = FakeRepo()
    result = run(dirs, repo)
    assert result.status == "success"
    assert result.report.missing_page2 == []


def test_page_2_dans_un_autre_lot_est_manquante(dirs):
    captures, _ = dirs
    add(captures, PAID_P1, lot="2026-10-06T201500Z")
    add(captures, PAID_P2, lot="2026-10-06T230000Z")  # autre séance
    repo = FakeRepo()
    result = run(dirs, repo)
    assert result.status == "partial"
    assert "absente du lot 2026-10-06T201500Z" in repo.last["notes"]
    assert len(repo.pages) == 2  # les deux pages sont déposées, l'absence est seulement signalée


def test_page_2_en_quarantaine_pas_comptee_deux_fois(dirs):
    import json
    captures, _ = dirs
    lot_dir = add(captures, PAID_P1, PAID_P2)
    meta = json.loads((lot_dir / f"{PAID_P2}.json").read_text(encoding="utf-8"))
    meta["html_bytes"] += 1  # page 2 non intègre : quarantaine
    (lot_dir / f"{PAID_P2}.json").write_text(json.dumps(meta), encoding="utf-8")
    repo = FakeRepo()
    result = run(dirs, repo)
    assert len(result.report.quarantined) == 1
    assert result.report.missing_page2 == []  # présente dans le lot : signalée une seule fois
    assert result.report.anomalies == 1


def test_signaux_divergents_information_sans_anomalie(dirs):
    captures, _ = dirs
    make_capture(captures / "inbox" / LOT, "bestsellers_page1_complete_sans_pagination.html",
                 "10000000001", "paid", 1, "2026-10-06T200000Z")
    repo = FakeRepo()
    result = run(dirs, repo)
    assert result.status == "success"  # 50 rangs sans annonce : information seulement
    assert result.report.missing_page2 == []
    assert any("50 rangs, mais la pagination n'annonce pas de page 2 : page 2 non attendue" in i
               for i in result.report.information)


def test_liste_courte_sans_page_2(dirs):
    captures, _ = dirs
    make_capture(captures / "inbox" / LOT, "bestsellers_liste_courte.html", "10000000001", "paid", 1,
                 "2026-10-06T200000Z")
    repo = FakeRepo()
    assert run(dirs, repo).status == "success"
    assert "liste courte (45 rangs sur 50)" in repo.last["notes"]


def test_page_1_deja_ingeree_pas_revérifiee(dirs):
    captures, _ = dirs
    add(captures, PAID_P1)
    repo = FakeRepo()
    run(dirs, repo)  # 1re fois : page 2 manquante signalée
    add(captures, PAID_P1, lot="2026-10-06T220000Z")
    result = run(dirs, repo)
    assert result.status == "success"  # 2e fois : déjà ingérée, pas de nouvelle alerte
    assert result.report.already == 1 and result.report.missing_page2 == []


def test_bilan_complet(dirs):
    captures, _ = dirs
    add(captures, CAPTCHA, PAID_P2, OUTSIDE)
    (captures / "inbox" / "perdu.txt").write_text("x")
    repo = FakeRepo()
    result = run(dirs, repo)
    report = result.report
    assert report.lots == [LOT]
    assert report.deposited == {"ok": 1, "blocked": 1, "invalid": 0}
    assert len(report.rejected_pages) == 1 and len(report.quarantined) == 1 and len(report.left_in_place) == 1
    assert report.missing_page2 == [] and report.anomalies == 3 and report.status == "partial"


def test_inbox_vide_bilan_success(dirs):
    repo = FakeRepo()
    run(dirs, repo)
    assert repo.last["notes"].splitlines()[-1] == "Résultat : success, 0 anomalie(s) — code de sortie 0"


def test_erreur_d_execution_statut_failed(dirs, monkeypatch):
    captures, _ = dirs
    add(captures, PAID_P1)
    repo = FakeRepo()
    monkeypatch.setattr(repo, "record_page", lambda run_id, record: (_ for _ in ()).throw(RuntimeError("panne")))
    with pytest.raises(RuntimeError):
        run(dirs, repo)
    assert repo.last["status"] == "failed"
    assert repo.last["notes"].splitlines()[-1] == "Résultat : failed, 0 anomalie(s) — code de sortie 1"
    assert "RuntimeError : panne" in repo.last["notes"]


# Bilan de référence, écrit en dur : il vérifie la mise en forme elle-même (alignement des libellés
# sur 19 caractères, ordre des rubriques, puces, ligne de résultat), que les autres tests ne vérifient pas.
BILAN_DE_REFERENCE = """\
Bilan de l'ingestion 42 — lot(s) : 2026-10-06T201500Z
  Déposées dans RAW  : 2 (ok 1, blocked 1, invalid 0)
  Déjà ingérées      : 0
  Pages anormales    : 1
    - 2026-10-06T201500Z/amazon_fr_bestsellers_10000000001_paid_p1_2026-10-06T200030Z : blocked : CAPTCHA détecté : lien canonical absent ; onglet actif introuvable ; aucune liste contenant render.zg.rank
  Quarantaine        : 1
    - 2026-10-06T201500Z/amazon_fr_bestsellers_10000000009_paid_p1_2026-10-06T200040Z : hors périmètre : catégorie 10000000009, liste paid absente de config/targets.toml
  Laissés en place   : 1
    - perdu.txt : fichier hors de tout lot
  Pages 2 manquantes : 1
    - 10000000001 paid : page 2 annoncée, absente du lot 2026-10-06T201500Z
  Informations       : 1
    - lots vidés et supprimés : 2026-10-06T201500Z
Résultat : partial, 4 anomalie(s) — code de sortie 1"""


def test_bilan_de_reference(dirs):
    captures, _ = dirs
    add(captures, PAID_P1, CAPTCHA, OUTSIDE)  # page 2 absente du lot, page de vérification, hors périmètre
    (captures / "inbox" / "perdu.txt").write_text("x")
    repo = FakeRepo()
    result = run(dirs, repo)
    assert result.notes == BILAN_DE_REFERENCE
    assert repo.last["notes"] == BILAN_DE_REFERENCE


# --- Liste classée malformée : page invalid, jamais un plantage ----------------------------

def make_modified_capture(captures, pattern, replacement, expected_count):
    """Capture intègre (décision 007) de la fausse page d'exemple (5 livres, Top payant p1), dont la liste classée
    est modifiée par une expression régulière ; empreinte et taille recalculées sur le HTML modifié."""
    import json
    import re
    lot_dir = captures / "inbox" / LOT
    stem = make_capture(lot_dir, "bestsellers_exemple.html", "10000000001", "paid", 1, "2026-10-06T200000Z")
    html, n = re.subn(pattern, replacement, (lot_dir / f"{stem}.html").read_text(encoding="utf-8"))
    assert n == expected_count
    content = html.encode("utf-8")
    meta = json.loads((lot_dir / f"{stem}.json").read_text(encoding="utf-8"))
    meta.update(html_sha256=hashlib.sha256(content).hexdigest(), html_bytes=len(content))
    (lot_dir / f"{stem}.html").write_bytes(content)
    (lot_dir / f"{stem}.json").write_text(json.dumps(meta), encoding="utf-8")


@pytest.mark.parametrize("valeur", ["5", "true", "[&quot;render.zg.rank&quot;]", "&quot;render.zg.rank&quot;"],
                         ids=["nombre", "booleen", "liste", "texte"])
def test_metadatamap_qui_n_est_pas_un_objet(dirs, valeur):
    """metadataMap nombre, booléen, liste ou texte : « pas de rang », capture déposée invalid, ingestion terminée."""
    captures, _ = dirs
    make_modified_capture(captures, r"&quot;metadataMap&quot;:\{[^}]*\}", f"&quot;metadataMap&quot;:{valeur}", 5)

    repo = FakeRepo()
    result = run(dirs, repo)

    (_, record), = repo.pages
    assert record.fetch_status == "invalid"
    assert "aucune liste contenant render.zg.rank" in record.error_message
    assert result.status == "partial" and EXIT_CODES[result.status] == 1
    assert result.report.error is None
    assert inbox_files(captures) == []  # retirée de inbox/ : elle ne bloque pas les ingestions suivantes


@pytest.mark.parametrize("valeur, statut", [
    ("1", "ok"),                       # entier JSON : rang valide
    ("&quot;1&quot;", "ok"),           # texte d'entier (forme des vraies pages) : rang valide
    ("true", "invalid"),               # booléen : int(True) vaudrait 1
    ("false", "invalid"),
    ("1.0", "invalid"),                # décimal : int(1.7) vaudrait 1
    ("&quot;1.0&quot;", "invalid"),
    ("&quot;\u0661&quot;", "invalid"),  # chiffre arabo-indien : int() l'accepterait
], ids=["entier", "texte-entier", "vrai", "faux", "decimal", "texte-decimal", "chiffre-non-ascii"])
def test_rang_qui_n_est_pas_un_entier(dirs, valeur, statut):
    """Valeur du premier rang : seuls un entier JSON (jamais un booléen) ou un texte de chiffres sont des rangs."""
    captures, _ = dirs
    make_modified_capture(captures, r"&quot;render\.zg\.rank&quot;:&quot;1&quot;",
                          f"&quot;render.zg.rank&quot;:{valeur}", 1)

    repo = FakeRepo()
    result = run(dirs, repo)

    (_, record), = repo.pages
    assert record.fetch_status == statut
    if statut == "invalid":
        assert "render.zg.rank non entier" in record.error_message
    assert result.report.error is None
    assert inbox_files(captures) == []
