"""Cibles de collecte : catégories lues dans config/targets.toml, et pages à demander."""

import re
import tomllib
from dataclasses import dataclass
from pathlib import Path

# Décision 002 : plafond dur de requêtes par tournée
MAX_REQUESTS_PER_RUN = 200
# Une liste de classement compte au plus 2 pages (docs/exploration-amazon.md)
MAX_PAGES_PER_LIST = 2
# Top 100 payant et Top 100 gratuit (décision 004)
SUPPORTED_LISTS = ("paid", "free")

BESTSELLERS_URL = "https://www.amazon.fr/gp/bestsellers/digital-text/"


class TargetsError(Exception):
    """Fichier des cibles absent ou invalide."""


@dataclass(frozen=True)
class Category:
    node: str
    name: str
    lists: tuple[str, ...]


@dataclass(frozen=True)
class PageRequest:
    """Une page de classement à obtenir."""

    node: str
    list_type: str
    page_number: int

    @property
    def url(self) -> str:
        """Adresse Amazon de la page (docs/exploration-amazon.md) : adresse canonique, plus pg=2 pour la page 2
        et tf=1 pour le Top gratuit. Page 1 du Top payant : adresse canonique seule."""
        params = []
        if self.page_number != 1:
            params.append(f"pg={self.page_number}")
        if self.list_type == "free":
            params.append("tf=1")
        return canonical_url(self.node) + ("?" + "&".join(params) if params else "")

    @property
    def label(self) -> str:
        return f"{self.node} {self.list_type} p{self.page_number}"


def canonical_url(node: str) -> str:
    """Lien canonical attendu dans une page de classement de cette catégorie."""
    return BESTSELLERS_URL + node


def load_targets(path: Path) -> list[Category]:
    """Lit et vérifie le fichier des cibles. Toute anomalie arrête le collecteur."""
    try:
        with open(path, "rb") as f:
            data = tomllib.load(f)
    except FileNotFoundError:
        raise TargetsError(f"Fichier des cibles introuvable : {path}") from None
    except tomllib.TOMLDecodeError as exc:
        raise TargetsError(f"Fichier des cibles illisible ({path}) : {exc}") from None

    entries = data.get("categorie")
    if not isinstance(entries, list) or not entries:
        raise TargetsError(f"Aucune catégorie [[categorie]] dans {path}.")

    categories: list[Category] = []
    seen: set[str] = set()
    for i, entry in enumerate(entries, start=1):
        node = entry.get("node")
        name = entry.get("nom")
        lists = entry.get("listes")
        if not isinstance(node, str) or not re.fullmatch(r"[0-9]+", node):
            raise TargetsError(f"Catégorie n° {i} : node doit être une chaîne de chiffres, reçu {node!r}.")
        if node in seen:
            raise TargetsError(f"Catégorie {node} déclarée deux fois.")
        if not isinstance(name, str) or not name.strip():
            raise TargetsError(f"Catégorie {node} : nom absent.")
        if not isinstance(lists, list) or not lists:
            raise TargetsError(f"Catégorie {node} : listes absentes.")
        for list_type in lists:
            if list_type not in SUPPORTED_LISTS:
                raise TargetsError(
                    f"Catégorie {node} : liste {list_type!r} non prise en charge "
                    f"(autorisées : {', '.join(SUPPORTED_LISTS)})."
                )
        if len(set(lists)) != len(lists):
            raise TargetsError(f"Catégorie {node} : liste déclarée deux fois.")
        seen.add(node)
        categories.append(Category(node=node, name=name, lists=tuple(lists)))

    worst_case = sum(len(c.lists) for c in categories) * MAX_PAGES_PER_LIST
    if worst_case > MAX_REQUESTS_PER_RUN:
        raise TargetsError(
            f"Jusqu'à {worst_case} requêtes possibles par tournée : "
            f"le plafond est de {MAX_REQUESTS_PER_RUN} (décision 002)."
        )
    return categories


def plan_requests(categories: list[Category]) -> list[PageRequest]:
    """Pages 1 à demander, dans l'ordre du fichier. La page 2 n'est pas planifiée ici :
    elle dépend de la page 1 reçue (books.collector.run)."""
    return [
        PageRequest(node=c.node, list_type=list_type, page_number=1)
        for c in categories
        for list_type in c.lists
    ]
