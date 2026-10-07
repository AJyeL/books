"""Tests de books.collector.sources : sources interchangeables et fail closed."""

import pytest

from books.collector.sources import LocalSource, SourceError, make_source
from books.collector.targets import PageRequest

REQUEST = PageRequest("10000000001", "paid", 1)


@pytest.fixture
def samples(tmp_path):
    """Dossier de pages enregistrées, avec deux dates pour la même catégorie."""
    (tmp_path / "amazon_fr_bestsellers_10000000001_paid_p1_2026-10-04.html").write_bytes(b"ancienne")
    (tmp_path / "amazon_fr_bestsellers_10000000001_paid_p1_2026-10-05.html").write_bytes(b"recente")
    (tmp_path / "amazon_fr_bestsellers_10000000002_paid_p1_2026-10-06.html").write_bytes(b"autre")
    return tmp_path


# --- Source locale ---------------------------------------------------------

def test_source_locale_prend_la_page_la_plus_recente(samples):
    fetched = LocalSource("dev", samples).fetch(REQUEST)
    assert fetched.content == b"recente"
    assert fetched.origin == "amazon_fr_bestsellers_10000000001_paid_p1_2026-10-05.html"
    assert fetched.error is None


def test_page_gratuite_jamais_prise_pour_une_page_payante(samples):
    # Page gratuite plus récente que la page payante : l'ancien motif (…_p1_*.html) l'aurait choisie
    (samples / "amazon_fr_bestsellers_10000000001_free_p1_2026-10-09.html").write_bytes(b"gratuite")
    source = LocalSource("dev", samples)
    assert source.fetch(PageRequest("10000000001", "paid", 1)).content == b"recente"
    assert source.fetch(PageRequest("10000000001", "free", 1)).content == b"gratuite"


def test_page_gratuite_seule_jamais_servie_pour_le_payant(tmp_path):
    (tmp_path / "amazon_fr_bestsellers_10000000001_free_p1_2026-10-05.html").write_bytes(b"gratuite")
    fetched = LocalSource("dev", tmp_path).fetch(PageRequest("10000000001", "paid", 1))
    assert fetched.content is None


def test_page_2_jamais_prise_pour_la_page_1(tmp_path):
    (tmp_path / "amazon_fr_bestsellers_10000000001_paid_p2_2026-10-05.html").write_bytes(b"page 2")
    source = LocalSource("dev", tmp_path)
    assert source.fetch(PageRequest("10000000001", "paid", 1)).content is None
    assert source.fetch(PageRequest("10000000001", "paid", 2)).content == b"page 2"


@pytest.mark.parametrize("name", [
    "amazon_fr_bestsellers_10000000001_p1_2026-10-05.html",           # ancienne convention, sans type
    "amazon_fr_bestsellers_10000000001_p1_gratuit_2026-10-05.html",   # ancienne page gratuite
    "amazon_fr_bestsellers_10000000001_paid_p1_gratuit_2026-10-05.html",
    "amazon_fr_bestsellers_10000000001_paid_p1_2026-10-05.html.bak.html",
    "amazon_fr_bestsellers_10000000001_paid_p1_5-10-2026.html",
])
def test_nom_hors_convention_ignore(tmp_path, name):
    (tmp_path / name).write_bytes(b"hors convention")
    assert LocalSource("dev", tmp_path).fetch(PageRequest("10000000001", "paid", 1)).content is None


def test_source_locale_page_absente(samples):
    fetched = LocalSource("dev", samples).fetch(PageRequest("10000000003", "paid", 1))
    assert fetched.content is None
    assert fetched.error_status == "network_error"
    assert "aucune page enregistrée" in fetched.error


def test_source_locale_page_2_absente(samples):
    assert LocalSource("dev", samples).fetch(PageRequest("10000000001", "paid", 2)).content is None


def test_source_locale_liste_gratuite_absente(samples):
    assert LocalSource("dev", samples).fetch(PageRequest("10000000001", "free", 1)).content is None


def test_source_locale_dossier_absent(tmp_path):
    with pytest.raises(SourceError, match="introuvable"):
        LocalSource("dev", tmp_path / "absent")


# --- Fail closed -----------------------------------------------------------

def test_source_locale_refusee_en_prod(samples):
    with pytest.raises(SourceError, match="qu'en dev"):
        LocalSource("prod", samples)


def test_choix_en_dev(samples):
    source = make_source("dev", {"BOOKS_SAMPLES_DIR": str(samples)})
    assert isinstance(source, LocalSource)


def test_dev_sans_dossier_des_pages(samples):
    with pytest.raises(SourceError, match="BOOKS_SAMPLES_DIR"):
        make_source("dev", {})


def test_prod_n_utilise_jamais_la_source_locale(samples):
    # Même si BOOKS_SAMPLES_DIR traîne dans l'environnement de prod, les pages enregistrées à la main
    # ne sont jamais lues : la prod ingère les captures de inbox/ (décision 008)
    with pytest.raises(SourceError, match="ingère les captures"):
        make_source("prod", {"BOOKS_SAMPLES_DIR": str(samples)})


@pytest.mark.parametrize("env", ["", "test", "DEV"])
def test_environnement_inconnu(samples, env):
    with pytest.raises(SourceError, match="aucune source"):
        make_source(env, {"BOOKS_SAMPLES_DIR": str(samples)})


def test_source_locale_methode_manual_html(samples):
    # Méthode enregistrée dans RAW (migration 004), y compris pour une page non trouvée
    source = LocalSource("dev", samples)
    assert source.fetch(REQUEST).capture_method == "manual-html"
    assert source.fetch(PageRequest("10000000003", "paid", 1)).capture_method == "manual-html"
