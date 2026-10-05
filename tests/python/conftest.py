"""Éléments communs aux tests Python."""

from pathlib import Path

import pytest

# Fausses pages de test, aux valeurs inventées (voir tests/fixtures/README.md)
FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"
# Catégorie inventée des fixtures
FIXTURE_NODE = "10000000001"


@pytest.fixture
def fixture_page():
    """Contenu brut (octets) d'une fausse page, par son nom de fichier."""
    def read(name: str) -> bytes:
        return (FIXTURES / name).read_bytes()
    return read
