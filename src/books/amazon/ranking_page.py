"""Page de classement acceptable : définition unique de l'adresse d'une page dans le périmètre (décision 014).

Toute page de classement Kindle d'amazon.fr est dans le périmètre : https://www.amazon.fr/gp/bestsellers/digital-text/
{numéro de catégorie}, Top payant ou Top gratuit (tf=1), page 1 ou 2 (pg). Sont refusés : les autres domaines, les
autres boutiques, les autres types de listes, la page générale sans numéro de catégorie, et toute valeur de tf ou de pg
non prévue ou répétée (décision 007, section 2 et compléments).

Contrat commun avec l'extension : tests/fixtures/adresses_classement.json (adresses acceptées et refusées), que ce
dépôt teste entièrement et dont l'extension garde une copie dans ses tests.
"""

import re
from dataclasses import dataclass
from urllib.parse import parse_qs, urlsplit

BESTSELLERS_URL = "https://www.amazon.fr/gp/bestsellers/digital-text/"
# Chemin d'une page de classement Kindle : numéro de catégorie obligatoire, suite libre (ex. : /ref=…)
BESTSELLERS_PATH = re.compile(r"/gp/bestsellers/digital-text/([0-9]+)(/.*)?")
# Top 100 payant et Top 100 gratuit (décision 004)
SUPPORTED_LISTS = ("paid", "free")
# Une liste de classement compte au plus 2 pages (docs/exploration-amazon.md)
MAX_PAGES_PER_LIST = 2


@dataclass(frozen=True)
class PageRequest:
    """Une page de classement : catégorie, type de liste, numéro de page."""

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


def request_from_url(url: str) -> tuple[PageRequest | None, str | None]:
    """Catégorie, liste et page déduites d'une adresse de page de classement.

    Renvoie (demande, None) si l'adresse est dans le périmètre, ou (None, motif) si elle est refusée ou ambiguë.
    """
    try:
        parts = urlsplit(url)
    except ValueError:  # adresse mal formée (ex. : crochet non fermé dans l'hôte) : refus, jamais une exception
        return None, "adresse mal formée"
    if parts.scheme != "https" or parts.netloc != "www.amazon.fr":
        return None, "adresse hors de https://www.amazon.fr"
    path = BESTSELLERS_PATH.fullmatch(parts.path)
    if path is None:
        return None, "adresse hors des pages de classement Kindle"
    params = parse_qs(parts.query, keep_blank_values=True)
    for key in ("tf", "pg"):
        if len(params.get(key, [])) > 1:
            return None, f"paramètre {key} répété : adresse ambiguë"
    tf = params.get("tf", [None])[0]
    pg = params.get("pg", [None])[0]
    if tf not in (None, "1"):
        return None, f"valeur de tf non acceptée : {tf!r}"
    if pg not in (None, "1", "2"):
        return None, f"valeur de pg non acceptée : {pg!r}"
    return PageRequest(path.group(1), "free" if tf == "1" else "paid", int(pg or 1)), None
