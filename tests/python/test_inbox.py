"""Tests de books.collector.inbox : lecture des lots, intégrité (décision 007, section 6), quarantaine."""

import json
import shutil

import pytest

from books.collector.inbox import (
    LoneHtml, Pair, QuarantineError, Rejected, Untouchable, Capture,
    check_capture, quarantine, scan_inbox,
)
from books.amazon.ranking_page import PageRequest
from conftest import FIXTURES

CAPTURES = FIXTURES / "captures"
PAID_P1 = "amazon_fr_bestsellers_10000000001_paid_p1_2026-10-06T200000Z"
FREE_P1 = "amazon_fr_bestsellers_10000000001_free_p1_2026-10-06T200020Z"
OUTSIDE = "amazon_fr_bestsellers_10000000009_paid_p1_2026-10-06T200040Z"
LOT = "2026-10-06T201500Z"


@pytest.fixture
def inbox(tmp_path):
    """Dossier inbox/ vide."""
    root = tmp_path / "inbox"
    root.mkdir()
    return root


def add(inbox_dir, *stems, lot=LOT, suffixes=(".html", ".json")):
    """Copie des captures de test dans inbox/{lot}/ ; renvoie le dossier du lot."""
    lot_dir = inbox_dir / lot
    lot_dir.mkdir(exist_ok=True)
    for stem in stems:
        for suffix in suffixes:
            shutil.copy(CAPTURES / f"{stem}{suffix}", lot_dir / f"{stem}{suffix}")
    return lot_dir


def only_pair(inbox_dir) -> Pair:
    items = scan_inbox(inbox_dir)
    assert len(items) == 1 and isinstance(items[0], Pair)
    return items[0]


def edit_json(lot_dir, stem, **changes):
    path = lot_dir / f"{stem}.json"
    meta = json.loads(path.read_text(encoding="utf-8"))
    for key, value in changes.items():
        if value is ...:
            del meta[key]
        else:
            meta[key] = value
    path.write_text(json.dumps(meta), encoding="utf-8")


# --- Inventaire de inbox/ ------------------------------------------------------------------

def test_lots_et_fichiers_dans_l_ordre(inbox):
    add(inbox, FREE_P1, lot="2026-10-06T210000Z")
    add(inbox, PAID_P1, FREE_P1, lot="2026-10-06T201500Z")
    items = scan_inbox(inbox)
    assert [(i.lot, i.stem) for i in items] == [
        ("2026-10-06T201500Z", FREE_P1), ("2026-10-06T201500Z", PAID_P1), ("2026-10-06T210000Z", FREE_P1)]


@pytest.mark.parametrize("name", [
    f"{PAID_P1} (1).html",                      # renommage de Chrome en cas de conflit
    f"{PAID_P1}.raison.txt",                    # fichier de raison replacé par erreur
    "amazon_fr_bestsellers_10000000001_paid_p1_2026-10-06.html",   # page enregistrée à la main
    f"{PAID_P1}.html.gz",
    "notes.txt",
])
def test_nom_hors_format_mis_en_quarantaine(inbox, name):
    lot_dir = add(inbox)
    (lot_dir / name).write_bytes(b"x")
    items = scan_inbox(inbox)
    assert len(items) == 1 and isinstance(items[0], Rejected)
    assert "nom hors format" in items[0].reason


def test_json_orphelin(inbox):
    add(inbox, PAID_P1, suffixes=(".json",))
    item, = scan_inbox(inbox)
    assert isinstance(item, Rejected) and "JSON orphelin" in item.reason


def test_html_seul(inbox):
    add(inbox, PAID_P1, suffixes=(".html",))
    item, = scan_inbox(inbox)
    assert isinstance(item, LoneHtml)


@pytest.mark.parametrize("make", ["fichier_racine", "lot_hors_format", "sous_dossier"])
def test_elements_laisses_en_place(inbox, make):
    if make == "fichier_racine":
        (inbox / f"{PAID_P1}.html").write_bytes(b"x")
    elif make == "lot_hors_format":
        (inbox / "2026-10-06").mkdir()
    else:
        (add(inbox) / "sous-dossier").mkdir()
    item, = scan_inbox(inbox)
    assert isinstance(item, Untouchable)


# Adresse affichée : testée sur le contrat commun tests/fixtures/adresses_classement.json (test_ranking_page.py)

# --- Contrôles d'intégrité -----------------------------------------------------------------

def test_capture_integre(inbox):
    add(inbox, PAID_P1)
    capture = check_capture(only_pair(inbox))
    assert isinstance(capture, Capture)
    assert capture.request == PageRequest("10000000001", "paid", 1)
    assert capture.captured_at.isoformat() == "2026-10-06T20:00:00+00:00"
    assert capture.html.startswith(b"<!DOCTYPE html><html")


@pytest.mark.parametrize("changes, reason", [
    ({"schema_version": 2}, "schema_version 2"),
    ({"schema_version": True}, "schema_version doit être de type int"),
    ({"html_bytes": "12"}, "html_bytes doit être de type int"),
    ({"user_agent": ...}, "champs manquants ['user_agent']"),
    ({"commentaire": "x"}, "champs inconnus ['commentaire']"),
    ({"capture_method": "manual-html"}, "'extension-dom' attendu"),
    ({"captured_at": "2026-10-06T20:00:01Z"}, "captured_at différent"),
    ({"displayed_url": "https://www.amazon.fr/gp/bestsellers/digital-text/10000000001?tf=1"}, "différente du nom"),
    ({"displayed_url": "https://www.amazon.fr/gp/bestsellers/digital-text/10000000002"}, "différente du nom"),
    ({"displayed_url": "https://www.amazon.fr/gp/bestsellers/digital-text/10000000001?pg=1&pg=2"}, "pg répété"),
    ({"html_sha256": "0" * 64}, "empreinte du HTML différente"),
    ({"html_sha256": "ABC"}, "html_sha256 mal formé"),
    ({"html_bytes": 1}, "taille du HTML"),
])
def test_capture_non_integre(inbox, changes, reason):
    lot_dir = add(inbox, PAID_P1)
    edit_json(lot_dir, PAID_P1, **changes)
    result = check_capture(only_pair(inbox))
    assert isinstance(result, Rejected) and reason in result.reason
    assert len(result.paths) == 2  # les deux fichiers partent ensemble en quarantaine


def test_html_modifie_apres_capture(inbox):
    lot_dir = add(inbox, PAID_P1)
    html = lot_dir / f"{PAID_P1}.html"
    html.write_bytes(html.read_bytes().replace(b"Top 100 payants", b"Top 100 payantz"))  # même taille
    result = check_capture(only_pair(inbox))
    assert isinstance(result, Rejected) and "empreinte du HTML" in result.reason


@pytest.mark.parametrize("raw, reason", [
    (b"\xef\xbb\xbf{}", "BOM"),
    (b"{pas du json", "JSON illisible"),
    (b"[]", "un objet est attendu"),
])
def test_json_illisible(inbox, raw, reason):
    lot_dir = add(inbox, PAID_P1)
    (lot_dir / f"{PAID_P1}.json").write_bytes(raw)
    result = check_capture(only_pair(inbox))
    assert isinstance(result, Rejected) and reason in result.reason


def test_horodatage_impossible(inbox):
    lot_dir = add(inbox)
    stem = "amazon_fr_bestsellers_10000000001_paid_p1_2026-13-06T200000Z"
    shutil.copy(CAPTURES / f"{PAID_P1}.html", lot_dir / f"{stem}.html")
    shutil.copy(CAPTURES / f"{PAID_P1}.json", lot_dir / f"{stem}.json")
    result = check_capture(only_pair(inbox))
    assert isinstance(result, Rejected) and "horodatage du nom impossible" in result.reason


@pytest.mark.parametrize("stem", [OUTSIDE, FREE_P1], ids=["autre-categorie", "top-gratuit"])
def test_toute_categorie_et_toute_liste_acceptees(inbox, stem):
    # Décision 014 : plus de liste de catégories ; l'adresse affichée suffit
    add(inbox, stem)
    assert isinstance(check_capture(only_pair(inbox)), Capture)


def rejected_capture(inbox):
    """Capture non intègre (taille annoncée fausse) : refusée, à mettre en quarantaine."""
    lot_dir = add(inbox, OUTSIDE)
    edit_json(lot_dir, OUTSIDE, html_bytes=1)
    rejected = check_capture(only_pair(inbox))
    assert isinstance(rejected, Rejected)
    return lot_dir, rejected


# --- Quarantaine ---------------------------------------------------------------------------

def test_quarantaine(inbox, tmp_path):
    lot_dir, rejected = rejected_capture(inbox)
    target = quarantine(rejected, tmp_path / "quarantaine")
    assert sorted(p.name for p in target.iterdir()) == [
        f"{OUTSIDE}.html", f"{OUTSIDE}.json", f"{OUTSIDE}.raison.txt"]
    assert not any(lot_dir.iterdir())  # plus rien dans inbox/
    assert "taille du HTML" in (target / f"{OUTSIDE}.raison.txt").read_text(encoding="utf-8")
    # Contenu intact : le HTML mis en quarantaine est celui reçu, octet pour octet
    assert (target / f"{OUTSIDE}.html").read_bytes() == (CAPTURES / f"{OUTSIDE}.html").read_bytes()


def test_quarantaine_jamais_d_ecrasement(inbox, tmp_path):
    lot_dir, rejected = rejected_capture(inbox)
    existing = tmp_path / "quarantaine" / LOT
    existing.mkdir(parents=True)
    (existing / f"{OUTSIDE}.html").write_bytes(b"deja la")
    with pytest.raises(QuarantineError, match="déjà présent"):
        quarantine(rejected, tmp_path / "quarantaine")
    assert (existing / f"{OUTSIDE}.html").read_bytes() == b"deja la"
    assert sorted(p.name for p in lot_dir.iterdir()) == [f"{OUTSIDE}.html", f"{OUTSIDE}.json"]  # laissés en place
