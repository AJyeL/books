"""Tests du point d'entrée de l'extracteur (python -m books.transformer) : configuration invalide → code 2,
avant toute connexion à la base (décision 011, section 10)."""

import pytest

from books.transformer.__main__ import main

VARIABLES = ("BOOKS_ENV", "POSTGRES_HOST", "POSTGRES_PORT", "POSTGRES_DB", "POSTGRES_USER", "POSTGRES_PASSWORD",
             "BOOKS_RAW_DIR", "BOOKS_TARGETS_FILE")


@pytest.fixture
def environ(monkeypatch, tmp_path):
    """Configuration complète et valide de l'extracteur ; chaque test en retire ou en fausse un élément."""
    for name in VARIABLES:
        monkeypatch.delenv(name, raising=False)
    values = {"BOOKS_ENV": "dev", "POSTGRES_HOST": "hote-inexistant.invalid", "POSTGRES_PORT": "5432",
              "POSTGRES_DB": "books", "POSTGRES_USER": "books_transformer", "POSTGRES_PASSWORD": "x",
              "BOOKS_RAW_DIR": str(tmp_path), "BOOKS_TARGETS_FILE": str(tmp_path / "targets.toml")}
    for name, value in values.items():
        monkeypatch.setenv(name, value)
    return monkeypatch


@pytest.mark.parametrize("name", ["BOOKS_ENV", "POSTGRES_DB", "BOOKS_RAW_DIR"])
def test_variable_absente_code_2(environ, name, capsys):
    environ.delenv(name)
    assert main([]) == 2
    assert f"Erreur de configuration : La variable d'environnement {name} est absente ou vide." in capsys.readouterr().err


def test_mot_de_passe_vide_code_2(environ, capsys):
    environ.setenv("POSTGRES_PASSWORD", "")  # ${BOOKS_TRANSFORMER_PASSWORD:-} absent de .env
    assert main([]) == 2
    assert "POSTGRES_PASSWORD" in capsys.readouterr().err


def test_dossier_raw_introuvable_code_2(environ, tmp_path, capsys):
    environ.setenv("BOOKS_RAW_DIR", str(tmp_path / "absent"))
    assert main([]) == 2
    assert "Dossier des pages brutes introuvable" in capsys.readouterr().err


def test_autre_role_refuse_code_2(environ, capsys):
    environ.setenv("POSTGRES_USER", "proprio")
    assert main([]) == 2
    assert "l'extracteur se connecte en books_transformer" in capsys.readouterr().err


def test_base_injoignable_code_1(environ, capsys):
    # Configuration valide, serveur injoignable : erreur d'exécution, et non de configuration
    assert main([]) == 1
    assert "Erreur PostgreSQL" in capsys.readouterr().err
