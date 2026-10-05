"""Éléments communs aux tests Python."""

from pathlib import Path

import pytest

from books.collector.targets import PageRequest

# Fausses pages de test, aux valeurs inventées (voir tests/fixtures/README.md)
FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"
# Catégorie inventée des fixtures
FIXTURE_NODE = "10000000001"


def demande(list_type: str = "paid", page_number: int = 1, node: str = FIXTURE_NODE) -> PageRequest:
    """Demande de page (par défaut : Top payant, page 1, catégorie des fixtures)."""
    return PageRequest(node, list_type, page_number)


@pytest.fixture
def fixture_page():
    """Contenu brut (octets) d'une fausse page, par son nom de fichier."""
    def read(name: str) -> bytes:
        return (FIXTURES / name).read_bytes()
    return read
