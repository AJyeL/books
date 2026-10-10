"""Fiche produit acceptable : définition unique de l'adresse d'une fiche (décision 015, section 3).

Une fiche est acceptée à l'adresse https://www.amazon.fr/{libellé facultatif}/dp/{ASIN}, suivie ou non de /ref=… et
de paramètres. L'ASIN est déduit de l'adresse affichée uniquement (comme la catégorie d'une page de classement,
décision 007). Sont refusés : les autres domaines et sous-domaines, http, la forme /gp/product/ (jamais observée
comme adresse d'une fiche), un ASIN de forme invalide, un /dp/ répété, et toute autre page.

L'adresse ne dit pas le format (Kindle, papier, audio) : c'est la validation qui le reconnaît (décision 015, section 5).

Contrat commun avec l'extension : tests/fixtures/adresses_fiches.json (adresses acceptées et refusées), que ce dépôt
teste entièrement et dont l'extension garde une copie dans ses tests.
"""

import re
from dataclasses import dataclass
from urllib.parse import urlsplit

PRODUCT_ORIGIN = ("https", "www.amazon.fr")
# Adresse courte d'une fiche, sans libellé : celle que construit ProductRequest.url
PRODUCT_URL = "https://www.amazon.fr/dp/"
# ASIN : 10 caractères, majuscules et chiffres (même règle que raw.raw_page) ; entièrement numérique pour certains
# livres papier (forme d'un ISBN-10)
ASIN_PATTERN = re.compile(r"[A-Z0-9]{10}")
# Chemin d'une fiche : libellé facultatif (un seul segment), /dp/, ASIN, suite libre commençant par / (ex. : /ref=…)
PRODUCT_PATH = re.compile(r"(?:/[^/]+)?/dp/([^/]+)(/.*)?")


@dataclass(frozen=True)
class ProductRequest:
    """Une fiche produit : son ASIN (pendant de PageRequest pour une page de classement)."""

    asin: str

    @property
    def url(self) -> str:
        """Adresse courte de la fiche, sans libellé ; elle-même acceptée par asin_from_url."""
        return PRODUCT_URL + self.asin

    @property
    def label(self) -> str:
        return f"fiche {self.asin}"


def asin_from_url(url: str) -> tuple[str | None, str | None]:
    """ASIN déduit d'une adresse de fiche produit.

    Renvoie (ASIN, None) si l'adresse est celle d'une fiche acceptée, ou (None, motif) si elle est refusée ou ambiguë.
    """
    try:
        parts = urlsplit(url)
    except ValueError:  # adresse mal formée (ex. : crochet non fermé dans l'hôte) : refus, jamais une exception
        return None, "adresse mal formée"
    if (parts.scheme, parts.netloc) != PRODUCT_ORIGIN:
        return None, "adresse hors de https://www.amazon.fr"
    if parts.path.startswith("/gp/product/"):
        return None, "forme /gp/product/ non acceptée (seule /dp/ est observée)"
    # Occurrences chevauchantes comprises (/dp/dp/…) ; barre finale ajoutée pour compter un /dp terminal
    if len(re.findall(r"(?=/dp/)", parts.path + "/")) > 1:
        return None, "/dp/ répété : adresse ambiguë"
    path = PRODUCT_PATH.fullmatch(parts.path)
    if path is None:
        return None, "adresse hors des fiches produit"
    asin = path.group(1)
    if ASIN_PATTERN.fullmatch(asin) is None:
        return None, f"ASIN de forme invalide : {asin!r}"
    return asin, None
