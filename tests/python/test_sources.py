"""Tests de books.collector.sources : sources interchangeables et fail closed."""

import pytest

from books.collector.sources import LocalSource, NetworkSource, SourceError, make_source
from books.collector.targets import PageRequest

REQUEST = PageRequest("10000000001", "paid", 1)


@pytest.fixture
def samples(tmp_path):
    """Dossier de pages enregistrées, avec deux dates pour la même catégorie."""
    (tmp_path / "amazon_fr_bestsellers_10000000001_p1_2026-10-04.html").write_bytes(b"ancienne")
    (tmp_path / "amazon_fr_bestsellers_10000000001_p1_2026-10-05.html").write_bytes(b"recente")
    (tmp_path / "amazon_fr_bestsellers_10000000002_p1_2026-10-06.html").write_bytes(b"autre")
    return tmp_path


# --- Source locale ---------------------------------------------------------

def test_source_locale_prend_la_page_la_plus_recente(samples):
    fetched = LocalSource("dev", samples).fetch(REQUEST)
    assert fetched.content == b"recente"
    assert fetched.origin == "amazon_fr_bestsellers_10000000001_p1_2026-10-05.html"
    assert fetched.error is None


def test_source_locale_page_absente(samples):
    fetched = LocalSource("dev", samples).fetch(PageRequest("10000000003", "paid", 1))
    assert fetched.content is None
    assert fetched.error_status == "network_error"
    assert "aucune page enregistrée" in fetched.error


def test_source_locale_page_2_absente(samples):
    assert LocalSource("dev", samples).fetch(PageRequest("10000000001", "paid", 2)).content is None


def test_source_locale_dossier_absent(tmp_path):
    with pytest.raises(SourceError, match="introuvable"):
        LocalSource("dev", tmp_path / "absent")


# --- Fail closed -----------------------------------------------------------

def test_source_locale_refusee_en_prod(samples):
    with pytest.raises(SourceError, match="qu'en dev"):
        LocalSource("prod", samples)


def test_source_reseau_refusee_en_dev():
    with pytest.raises(SourceError, match="qu'en prod"):
        NetworkSource("dev")


def test_source_reseau_pas_encore_ecrite():
    with pytest.raises(SourceError, match="pas encore écrite"):
        NetworkSource("prod")


def test_choix_en_dev(samples):
    source = make_source("dev", {"BOOKS_SAMPLES_DIR": str(samples)})
    assert isinstance(source, LocalSource)


def test_dev_sans_dossier_des_pages(samples):
    with pytest.raises(SourceError, match="BOOKS_SAMPLES_DIR"):
        make_source("dev", {})


def test_prod_n_utilise_jamais_la_source_locale(samples):
    # Même si BOOKS_SAMPLES_DIR traîne dans l'environnement de prod, la source locale n'est pas choisie
    with pytest.raises(SourceError, match="source réseau"):
        make_source("prod", {"BOOKS_SAMPLES_DIR": str(samples)})


@pytest.mark.parametrize("env", ["", "test", "DEV"])
def test_environnement_inconnu(samples, env):
    with pytest.raises(SourceError, match="aucune source"):
        make_source(env, {"BOOKS_SAMPLES_DIR": str(samples)})
