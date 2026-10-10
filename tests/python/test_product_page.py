"""Tests de books.amazon.product_page : la fiche produit acceptable (décision 015, section 3).

Parcourt entièrement le contrat commun tests/fixtures/adresses_fiches.json, dont l'extension garde une copie, et
vérifie que les deux règles d'adresse (fiche, page de classement) ne se chevauchent pas.
"""

import json

import pytest

from books.amazon.product_page import ProductRequest, asin_from_url
from books.amazon.ranking_page import request_from_url
from conftest import FIXTURES

CONTRAT = json.loads((FIXTURES / "adresses_fiches.json").read_text(encoding="utf-8"))
CONTRAT_CLASSEMENT = json.loads((FIXTURES / "adresses_classement.json").read_text(encoding="utf-8"))


def test_contrat_non_vide():
    # Une table vide rendrait les tests suivants vides de sens
    assert len(CONTRAT["acceptees"]) >= 5 and len(CONTRAT["refusees"]) >= 10


@pytest.mark.parametrize("cas", CONTRAT["acceptees"], ids=[c["note"] for c in CONTRAT["acceptees"]])
def test_adresse_acceptee(cas):
    assert asin_from_url(cas["adresse"]) == (cas["asin"], None)


@pytest.mark.parametrize("cas", CONTRAT["refusees"], ids=[c["note"] for c in CONTRAT["refusees"]])
def test_adresse_refusee(cas):
    asin, why = asin_from_url(cas["adresse"])
    assert asin is None
    assert cas["motif"] in why


@pytest.mark.parametrize("cas", CONTRAT["acceptees"], ids=[c["note"] for c in CONTRAT["acceptees"]])
def test_fiche_jamais_page_de_classement(cas):
    request, why = request_from_url(cas["adresse"])
    assert request is None and why is not None


@pytest.mark.parametrize("cas", CONTRAT_CLASSEMENT["acceptees"],
                         ids=[c["note"] for c in CONTRAT_CLASSEMENT["acceptees"]])
def test_page_de_classement_jamais_fiche(cas):
    asin, why = asin_from_url(cas["adresse"])
    assert asin is None and why is not None


@pytest.mark.parametrize("adresse", [
    "https://[www.amazon.fr/dp/B0FAUX0001",
    "https://www.amazon.fr]/dp/B0FAUX0001",
], ids=["crochet-ouvrant", "crochet-fermant"])
def test_adresse_mal_formee_refusee_sans_exception(adresse):
    # urlsplit lève ValueError sur un crochet non apparié dans l'hôte : la règle doit rendre un motif de refus.
    # Cas hors du contrat commun (décision 015, section 3) : propre à l'analyse d'adresse de ce dépôt.
    assert asin_from_url(adresse) == (None, "adresse mal formée")


def test_adresse_construite_acceptee():
    # L'adresse construite pour une fiche est elle-même acceptée, et rend le même ASIN
    request = ProductRequest("B0FAUX0001")
    assert request.url == "https://www.amazon.fr/dp/B0FAUX0001"
    assert asin_from_url(request.url) == ("B0FAUX0001", None)
    assert request.label == "fiche B0FAUX0001"
