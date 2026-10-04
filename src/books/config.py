"""Configuration de B.O.O.K.S., lue uniquement dans les variables d'environnement.

Aucune valeur par défaut : une variable absente arrête le programme avec un message clair,
plutôt que de le laisser tourner avec une configuration devinée.
"""

import os
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path

ENVIRONMENTS = ("dev", "prod")


class ConfigError(Exception):
    """Configuration absente ou invalide."""


@dataclass(frozen=True)
class Config:
    env: str
    db_host: str
    db_port: int
    db_name: str
    db_user: str
    db_password: str = field(repr=False)  # jamais affiché, ni dans les logs
    raw_dir: Path


def _require(environ: Mapping[str, str], name: str) -> str:
    value = environ.get(name)
    if value is None or not value.strip():
        raise ConfigError(f"La variable d'environnement {name} est absente ou vide.")
    return value


def load_config(environ: Mapping[str, str] | None = None) -> Config:
    """Construit la configuration à partir de l'environnement (os.environ par défaut)."""
    if environ is None:
        environ = os.environ

    env = _require(environ, "BOOKS_ENV")
    if env not in ENVIRONMENTS:
        raise ConfigError(
            f"BOOKS_ENV vaut {env!r} : valeurs autorisées : {', '.join(ENVIRONMENTS)}."
        )

    port_text = _require(environ, "POSTGRES_PORT")
    try:
        db_port = int(port_text)
    except ValueError:
        raise ConfigError(f"POSTGRES_PORT vaut {port_text!r} : un nombre entier est attendu.") from None
    if not 1 <= db_port <= 65535:
        raise ConfigError(f"POSTGRES_PORT vaut {db_port} : il doit être compris entre 1 et 65535.")

    return Config(
        env=env,
        db_host=_require(environ, "POSTGRES_HOST"),
        db_port=db_port,
        db_name=_require(environ, "POSTGRES_DB"),
        db_user=_require(environ, "POSTGRES_USER"),
        db_password=_require(environ, "POSTGRES_PASSWORD"),
        raw_dir=Path(_require(environ, "BOOKS_RAW_DIR")),
    )
