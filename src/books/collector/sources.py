"""Source des pages enregistrées à la main, pour le développement (décisions 004, 005 et 007).

- LocalSource : pages enregistrées à la main dans data/samples/ (manual-html), développement uniquement.
- En production, aucune source de ce type : le collecteur ingère les captures de l'extension déposées
  dans inbox/ (books.collector.ingestion, décision 008). La source réseau, abandonnée par la décision 005,
  n'existe plus.

Fail closed : LocalSource refuse de se construire hors de dev, et make_source refuse toute autre valeur.
"""

import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from books.amazon.ranking_page import PageRequest


# Pages enregistrées à la main (Ctrl+S, « HTML uniquement ») : développement uniquement (décision 007)
MANUAL_HTML = "manual-html"


class SourceError(Exception):
    """Source impossible à construire (mauvais environnement, configuration absente)."""


@dataclass(frozen=True)
class Fetched:
    """Résultat d'une demande de page : un contenu reçu, ou l'explication de son absence."""

    content: bytes | None
    origin: str  # d'où vient la page (nom du fichier local, adresse demandée…), pour le journal
    # Méthode de capture enregistrée dans RAW (migration 004) : « manual-html » pour une page
    # enregistrée à la main, « extension-dom » pour une capture de l'extension (décision 007)
    capture_method: str
    http_status: int | None = None
    final_url: str | None = None
    error: str | None = None  # renseigné si aucun contenu n'a été obtenu
    error_status: str = "network_error"  # valeur de fetch_status si aucun contenu


class PageSource(Protocol):
    description: str

    def fetch(self, request: PageRequest) -> Fetched: ...

    def first_pages(self) -> list[PageRequest]: ...


class LocalSource:
    """Lit le plus récent fichier amazon_fr_bestsellers_{node}_{paid|free}_p{n}_{AAAA-MM-JJ}.html du dossier.

    Le type de liste est toujours explicite dans le nom : une page gratuite ne peut pas être prise
    pour une page payante. Tout nom qui ne respecte pas exactement la convention est ignoré.
    """

    def __init__(self, env: str, samples_dir: Path) -> None:
        if env != "dev":
            raise SourceError(f"La source locale n'est autorisée qu'en dev (BOOKS_ENV={env!r}).")
        if not samples_dir.is_dir():
            raise SourceError(f"Dossier des pages enregistrées introuvable : {samples_dir}")
        self.samples_dir = samples_dir
        self.description = f"source locale ({samples_dir})"

    def fetch(self, request: PageRequest) -> Fetched:
        prefix = f"amazon_fr_bestsellers_{request.node}_{request.list_type}_p{request.page_number}_"
        pattern = prefix + "*.html"
        exact = re.compile(re.escape(prefix) + r"\d{4}-\d{2}-\d{2}\.html")
        # La date AAAA-MM-JJ en fin de nom : l'ordre alphabétique est l'ordre chronologique
        candidates = sorted(p for p in self.samples_dir.glob(pattern) if exact.fullmatch(p.name))
        if not candidates:
            return Fetched(content=None, origin=str(self.samples_dir), capture_method=MANUAL_HTML,
                           error=f"aucune page enregistrée ({pattern}) dans {self.samples_dir}")
        path = candidates[-1]
        return Fetched(content=path.read_bytes(), origin=path.name, capture_method=MANUAL_HTML)

    def first_pages(self) -> list[PageRequest]:
        """Pages 1 à demander : une par couple (catégorie, liste) ayant une page 1 enregistrée, Top payant d'abord.
        Remplace config/targets.toml (décision 014) : les pages présentes dans le dossier font le périmètre de dev.
        La page 2 n'est pas planifiée ici : elle dépend de la page 1 reçue (books.collector.run)."""
        page1 = re.compile(r"amazon_fr_bestsellers_([0-9]+)_(paid|free)_p1_\d{4}-\d{2}-\d{2}\.html")
        found = {(m.group(1), m.group(2)) for p in self.samples_dir.iterdir() if (m := page1.fullmatch(p.name))}
        return [PageRequest(node, list_type, 1)
                for node, list_type in sorted(found, key=lambda c: (c[0], c[1] != "paid"))]


def make_source(env: str, environ: Mapping[str, str]) -> PageSource:
    """Source des pages enregistrées à la main : dev uniquement. Toute autre valeur est refusée."""
    if env == "dev":
        samples_dir = environ.get("BOOKS_SAMPLES_DIR", "").strip()
        if not samples_dir:
            raise SourceError("BOOKS_SAMPLES_DIR est absente ou vide (fixée par docker-compose.dev.yml).")
        return LocalSource(env, Path(samples_dir))
    if env == "prod":
        raise SourceError("En prod, aucune page enregistrée à la main : le collecteur ingère les captures "
                          "de inbox/ (décision 008).")
    raise SourceError(f"BOOKS_ENV={env!r} : aucune source autorisée.")
