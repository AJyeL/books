"""Sources de pages interchangeables (décision 004).

- LocalSource : pages enregistrées à la main dans data/samples/ (développement uniquement).
- NetworkSource : requêtes vers amazon.fr (production uniquement), pas encore écrite.

Fail closed : chaque source vérifie elle-même BOOKS_ENV dans son constructeur.
En dev, la source réseau ne peut pas être construite ; en prod, la source locale non plus.
"""

from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from books.collector.targets import PageRequest


class SourceError(Exception):
    """Source impossible à construire (mauvais environnement, configuration absente)."""


@dataclass(frozen=True)
class Fetched:
    """Résultat d'une demande de page : un contenu reçu, ou l'explication de son absence."""

    content: bytes | None
    origin: str  # d'où vient la page (nom du fichier local, adresse demandée…), pour le journal
    http_status: int | None = None
    final_url: str | None = None
    error: str | None = None  # renseigné si aucun contenu n'a été obtenu
    error_status: str = "network_error"  # valeur de fetch_status si aucun contenu


class PageSource(Protocol):
    description: str

    def fetch(self, request: PageRequest) -> Fetched: ...


class LocalSource:
    """Lit le plus récent fichier amazon_fr_bestsellers_{node}_p{n}_{date}.html du dossier."""

    def __init__(self, env: str, samples_dir: Path) -> None:
        if env != "dev":
            raise SourceError(f"La source locale n'est autorisée qu'en dev (BOOKS_ENV={env!r}).")
        if not samples_dir.is_dir():
            raise SourceError(f"Dossier des pages enregistrées introuvable : {samples_dir}")
        self.samples_dir = samples_dir
        self.description = f"source locale ({samples_dir})"

    def fetch(self, request: PageRequest) -> Fetched:
        if request.list_type != "paid":
            return Fetched(content=None, origin=str(self.samples_dir),
                           error=f"liste {request.list_type!r} non prise en charge par la source locale")
        pattern = f"amazon_fr_bestsellers_{request.node}_p{request.page_number}_*.html"
        # La date AAAA-MM-JJ en fin de nom : l'ordre alphabétique est l'ordre chronologique
        candidates = sorted(self.samples_dir.glob(pattern))
        if not candidates:
            return Fetched(content=None, origin=str(self.samples_dir),
                           error=f"aucune page enregistrée ({pattern}) dans {self.samples_dir}")
        path = candidates[-1]
        return Fetched(content=path.read_bytes(), origin=path.name)


class NetworkSource:
    """Requêtes vers amazon.fr : production uniquement. Pas encore écrite."""

    def __init__(self, env: str) -> None:
        if env != "prod":
            raise SourceError(f"La source réseau n'est autorisée qu'en prod (BOOKS_ENV={env!r}).")
        raise SourceError("La source réseau n'est pas encore écrite : aucune collecte en prod pour l'instant.")


def make_source(env: str, environ: Mapping[str, str]) -> PageSource:
    """Choisit la source selon BOOKS_ENV. Toute autre valeur est refusée."""
    if env == "dev":
        samples_dir = environ.get("BOOKS_SAMPLES_DIR", "").strip()
        if not samples_dir:
            raise SourceError("BOOKS_SAMPLES_DIR est absente ou vide (fixée par docker-compose.dev.yml).")
        return LocalSource(env, Path(samples_dir))
    if env == "prod":
        return NetworkSource(env)
    raise SourceError(f"BOOKS_ENV={env!r} : aucune source autorisée.")
