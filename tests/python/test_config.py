"""Tests de books.config : lecture et validation de l'environnement."""

from pathlib import Path

import pytest

from books.config import ConfigError, load_config

BASE_ENV = {
    "POSTGRES_HOST": "postgres",
    "POSTGRES_PORT": "5432",
    "POSTGRES_DB": "books",
    "POSTGRES_USER": "books",
    "POSTGRES_PASSWORD": "secret-de-test",
    "BOOKS_RAW_DIR": "/data/raw",
    "BOOKS_TARGETS_FILE": "/app/config/targets.toml",
}


@pytest.fixture
def base_env(monkeypatch):
    """Environnement valide, sans BOOKS_ENV : chaque test le complète."""
    monkeypatch.delenv("BOOKS_ENV", raising=False)
    for name, value in BASE_ENV.items():
        monkeypatch.setenv(name, value)
    return monkeypatch


def test_books_env_absent(base_env):
    with pytest.raises(ConfigError, match="BOOKS_ENV"):
        load_config()


def test_books_env_vide(base_env):
    base_env.setenv("BOOKS_ENV", "  ")
    with pytest.raises(ConfigError, match="BOOKS_ENV"):
        load_config()


@pytest.mark.parametrize("valeur", ["test", "production", "DEV", "Prod"])
def test_books_env_invalide(base_env, valeur):
    base_env.setenv("BOOKS_ENV", valeur)
    with pytest.raises(ConfigError, match="valeurs autorisées"):
        load_config()


def test_books_env_dev(base_env):
    base_env.setenv("BOOKS_ENV", "dev")
    config = load_config()
    assert config.env == "dev"
    assert config.db_host == "postgres"
    assert config.db_port == 5432
    assert config.raw_dir == Path("/data/raw")
    assert config.targets_file == Path("/app/config/targets.toml")


def test_books_env_prod(base_env):
    base_env.setenv("BOOKS_ENV", "prod")
    assert load_config().env == "prod"


def test_mot_de_passe_jamais_affiche(base_env):
    base_env.setenv("BOOKS_ENV", "dev")
    assert "secret-de-test" not in repr(load_config())


def test_variable_postgres_absente(base_env):
    base_env.setenv("BOOKS_ENV", "dev")
    base_env.delenv("POSTGRES_PASSWORD")
    with pytest.raises(ConfigError, match="POSTGRES_PASSWORD"):
        load_config()


def test_port_non_numerique(base_env):
    base_env.setenv("BOOKS_ENV", "dev")
    base_env.setenv("POSTGRES_PORT", "cinq")
    with pytest.raises(ConfigError, match="POSTGRES_PORT"):
        load_config()


def test_fichier_des_cibles_absent(base_env):
    base_env.setenv("BOOKS_ENV", "dev")
    base_env.delenv("BOOKS_TARGETS_FILE")
    with pytest.raises(ConfigError, match="BOOKS_TARGETS_FILE"):
        load_config()
