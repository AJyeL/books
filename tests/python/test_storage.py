"""Tests de books.collector.storage : dépôt des pages brutes."""

import gzip
import hashlib
from datetime import UTC, datetime
from pathlib import PurePosixPath

import pytest

from books.collector.storage import raw_relative_path, store_raw
from books.amazon.ranking_page import PageRequest

REQUEST = PageRequest("10000000001", "paid", 1)
STARTED = datetime(2026, 10, 5, 23, 30, tzinfo=UTC)


def test_emplacement():
    assert raw_relative_path(12, STARTED, REQUEST) == PurePosixPath(
        "amazon_fr/2026/10/05/run-12/bestsellers_10000000001_paid_p1.html.gz")


def test_ecriture_empreinte_et_taille(tmp_path):
    content = "<html>Héritière</html>".encode()
    stored = store_raw(tmp_path, raw_relative_path(12, STARTED, REQUEST), content)
    assert stored.relative_path == "amazon_fr/2026/10/05/run-12/bestsellers_10000000001_paid_p1.html.gz"
    # Empreinte et taille du HTML d'origine, non compressé
    assert stored.sha256 == hashlib.sha256(content).hexdigest()
    assert stored.size == len(content)
    # Le fichier est compressé, et sa décompression redonne exactement le contenu reçu
    assert gzip.decompress((tmp_path / stored.relative_path).read_bytes()) == content


def test_compression_reproductible(tmp_path):
    # Sans date dans l'en-tête gzip, un même contenu donne toujours le même fichier compressé
    store_raw(tmp_path, PurePosixPath("a.html.gz"), b"page")
    store_raw(tmp_path, PurePosixPath("b.html.gz"), b"page")
    assert (tmp_path / "a.html.gz").read_bytes() == (tmp_path / "b.html.gz").read_bytes()


def test_jamais_d_ecrasement(tmp_path):
    path = raw_relative_path(12, STARTED, REQUEST)
    store_raw(tmp_path, path, b"premiere")
    with pytest.raises(FileExistsError):
        store_raw(tmp_path, path, b"seconde")
    # Le premier fichier est intact
    assert gzip.decompress((tmp_path / path.as_posix()).read_bytes()) == b"premiere"


def test_dossier_racine_absent(tmp_path):
    with pytest.raises(FileNotFoundError, match="introuvable"):
        store_raw(tmp_path / "absent", PurePosixPath("x.html.gz"), b"page")
    assert not (tmp_path / "absent").exists()  # jamais créé à la place de l'hôte
