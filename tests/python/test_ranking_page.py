"""Tests de books.amazon.ranking_page : la page de classement acceptable (décision 014).

Parcourt entièrement le contrat commun tests/fixtures/adresses_classement.json, dont l'extension garde une copie.
"""

import json

import pytest

from books.amazon.ranking_page import PageRequest, canonical_url, request_from_url
from conftest import FIXTURES

CONTRAT = json.loads((FIXTURES / "adresses_classement.json").read_text(encoding="utf-8"))


def test_contrat_non_vide():
    # Une table vide rendrait les tests suivants vides de sens
    assert len(CONTRAT["acceptees"]) >= 5 and len(CONTRAT["refusees"]) >= 10


@pytest.mark.parametrize("cas", CONTRAT["acceptees"], ids=[c["note"] for c in CONTRAT["acceptees"]])
def test_adresse_acceptee(cas):
    request, why = request_from_url(cas["adresse"])
    assert why is None
    assert request == PageRequest(cas["categorie"], cas["liste"], cas["page"])


@pytest.mark.parametrize("cas", CONTRAT["refusees"], ids=[c["note"] for c in CONTRAT["refusees"]])
def test_adresse_refusee(cas):
    request, why = request_from_url(cas["adresse"])
    assert request is None
    assert cas["motif"] in why


def test_adresse_reconstruite_acceptee():
    # L'adresse construite pour une demande est elle-même acceptée, et rend la même demande
    for request in (PageRequest("10000000001", "paid", 1), PageRequest("10000000001", "free", 2)):
        assert request_from_url(request.url) == (request, None)
    assert canonical_url("10000000001") == "https://www.amazon.fr/gp/bestsellers/digital-text/10000000001"
