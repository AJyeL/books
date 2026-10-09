"""Analyse d'une page de classement : fonction pure, du HTML aux lignes de staging.ranking_entry (décision 011).

parse_ranking_page() reçoit le contenu HTML d'une page (octets) et rend une ligne par livre classé, ou lève
ParseError avec un motif. Elle n'accède ni à la base, ni aux fichiers.

Règles (décision 011, sections 3 à 5 et 9) :
- liste classée : définition commune de books.amazon.ranked_list ; exactement une par page ;
- cartes : [id="gridItemRoot"] à l'intérieur de l'élément qui porte la liste, rattachées par l'ASIN de [data-asin] ;
  le badge de rang (span.zg-bdg-text) doit être celui de la liste ;
- champ absent : None ; champ présent mais de forme inconnue : la page entière est en échec ;
- formes acceptées, et seulement elles (inventaire du 8 octobre 2026). Dans les captures, l'espace insécable est
  écrit « &nbsp; » ; l'analyseur décode les entités, d'où U+00A0 dans les formes ci-dessous ;
- titre : entités HTML décodées et espaces réduits (y compris insécables), rien d'autre ;
- l'auteur n'est jamais lu : ni son nom, ni son lien, ni son identifiant (décision RGPD en attente).

Toute modification de ces règles incrémente EXTRACTOR_VERSION dans le même commit (décision 011, section 6).
"""

import re
from collections import Counter
from dataclasses import dataclass, field
from decimal import Decimal
from html.parser import HTMLParser

from books.amazon.ranked_list import RANK_KEY, rank_value, ranked_items

EXTRACTOR_VERSION = "1"

NBSP = " "
# Symboles de devise autorisés (liste d'autorisation) : tout autre symbole fait échouer la page
CURRENCIES = {"€": "EUR"}
# Nombre groupé par trois chiffres, groupes séparés par une espace insécable : 9, 999, 9 999, 999 999…
_GROUPED = rf"\d{{1,3}}(?:{NBSP}\d{{3}})*"
_PRICE = re.compile(rf"({_GROUPED}),(\d{{2}}){NBSP}(\S+)")
_RATING = re.compile(rf"(\d),(\d) sur 5{NBSP}étoiles")
_RATING_LINK = re.compile(rf"(\d),(\d) sur 5{NBSP}étoiles, ({_GROUPED}){NBSP}évaluations")
_COUNT = re.compile(_GROUPED)
_BADGE = re.compile(r"#(\d+)")
_ASIN = re.compile(r"[A-Z0-9]{10}")
# Bornes des colonnes de staging.ranking_entry (migration 005)
MAX_PRICE = Decimal("999999.99")  # numeric(8,2)
MAX_RATING = Decimal("5")
# Éléments HTML sans balise de fin
_VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}


class ParseError(Exception):
    """La page ne peut pas être extraite ; le message donne le motif (champ et rang)."""


@dataclass(frozen=True)
class RankingEntry:
    """Une ligne de staging.ranking_entry, sans les identifiants de page et d'exécution."""

    rank: int
    asin: str
    has_card: bool
    title: str | None = None
    price_amount: Decimal | None = None
    currency: str | None = None
    rating: Decimal | None = None
    review_count: int | None = None
    cover_url: str | None = None
    ku_sticker_hint: bool | None = None


@dataclass
class _Node:
    tag: str
    attrs: dict[str, str | None]
    children: list["_Node | str"] = field(default_factory=list)

    def iter(self):
        """Descendants, dans l'ordre du document."""
        for child in self.children:
            if isinstance(child, _Node):
                yield child
                yield from child.iter()

    def text(self) -> str:
        return "".join(c if isinstance(c, str) else c.text() for c in self.children)

    def classes(self) -> list[str]:
        return (self.attrs.get("class") or "").split()

    def child_nodes(self, tag: str) -> list["_Node"]:
        return [c for c in self.children if isinstance(c, _Node) and c.tag == tag]


class _TreeBuilder(HTMLParser):
    """Arbre minimal du document. Les entités sont décodées (texte et attributs) par l'analyseur."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.root = _Node("#document", {})
        self._stack = [self.root]

    def handle_starttag(self, tag, attrs):
        node = _Node(tag, dict(attrs))
        self._stack[-1].children.append(node)
        if tag not in _VOID:
            self._stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self._stack[-1].children.append(_Node(tag, dict(attrs)))

    def handle_endtag(self, tag):
        # Ferme l'élément ouvert de ce nom le plus proche ; une balise de fin orpheline est ignorée
        for i in range(len(self._stack) - 1, 0, -1):
            if self._stack[i].tag == tag:
                del self._stack[i:]
                return

    def handle_data(self, data):
        self._stack[-1].children.append(data)


def parse_ranking_page(content: bytes) -> list[RankingEntry]:
    """Lignes de la page, une par livre classé, dans l'ordre des rangs. Lève ParseError si la page est illisible."""
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ParseError(f"contenu qui n'est pas en UTF-8 (octet {exc.start})") from None
    builder = _TreeBuilder()
    builder.feed(text)
    builder.close()

    carrier, items = _ranked_list(builder.root)
    entries = {asin: rank for asin, rank in items}
    details: dict[str, RankingEntry] = {}
    for card in (n for n in carrier.iter() if n.attrs.get("id") == "gridItemRoot"):
        entry = _parse_card(card, entries)
        if entry.asin in details:
            raise ParseError(f"carte en double pour le rang {entry.rank}")
        details[entry.asin] = entry
    rows = [details.get(asin) or RankingEntry(rank=rank, asin=asin, has_card=False) for asin, rank in items]
    return sorted(rows, key=lambda r: r.rank)


def _ranked_list(root: _Node) -> tuple[_Node, list[tuple[str, int]]]:
    """Élément qui porte la liste classée, et (ASIN, rang) de ses éléments ; exactement une liste par page."""
    found = []
    for node in root.iter():
        value = node.attrs.get("data-client-recs-list")
        if value is not None:
            items = ranked_items(value)
            if items is not None:
                found.append((node, items))
    if len(found) != 1:
        raise ParseError(f"{len(found)} liste(s) classée(s) (une seule attendue)")
    carrier, items = found[0]
    pairs = []
    for item in items:
        rank = rank_value(item["metadataMap"][RANK_KEY])
        if rank is None or not 1 <= rank <= 100:
            raise ParseError(f"rang illisible ou hors de 1-100 dans la liste classée : {item['metadataMap'][RANK_KEY]!r}")
        asin = item.get("id")
        if not isinstance(asin, str) or not _ASIN.fullmatch(asin):
            raise ParseError(f"ASIN illisible au rang {rank}")
        pairs.append((asin, rank))
    # Filet de sécurité : déjà refusé par la validation (décision 011, section 5 bis)
    for label, values in (("rang", [r for _, r in pairs]), ("ASIN", [a for a, _ in pairs])):
        doubles = [v for v, n in Counter(values).items() if n > 1]
        if doubles:
            raise ParseError(f"{label} en double dans la liste classée (ex. : {doubles[0]})")
    return carrier, pairs


def _parse_card(card: _Node, ranks: dict[str, int]) -> RankingEntry:
    asin_node = next((n for n in card.iter() if n.attrs.get("data-asin")), None)
    if asin_node is None:
        raise ParseError("carte détaillée sans ASIN")
    asin = asin_node.attrs["data-asin"]
    if asin not in ranks:
        raise ParseError(f"carte dont l'ASIN est absent de la liste classée : {asin}")
    rank = ranks[asin]

    badges = [n for n in card.iter() if n.tag == "span" and "zg-bdg-text" in n.classes()]
    if len(badges) != 1:
        raise ParseError(f"rang {rank} : {len(badges)} badge(s) de rang (un seul attendu)")
    badge = _BADGE.fullmatch(badges[0].text().strip(" \t\r\n"))
    if badge is None or int(badge.group(1)) != rank:
        raise ParseError(f"rang {rank} : badge {badges[0].text()!r} différent du rang de la liste")

    price_amount, currency = _price(card, rank)
    rating, review_count = _rating(card, rank)
    cover_url = _cover(card, rank)
    return RankingEntry(
        rank=rank, asin=asin, has_card=True, title=_title(card, rank),
        price_amount=price_amount, currency=currency, rating=rating, review_count=review_count,
        cover_url=cover_url, ku_sticker_hint=None if cover_url is None else "ku-sticker" in cover_url,
    )


def _single(nodes: list[_Node], rank: int, label: str) -> _Node | None:
    """Élément unique ou absent ; plusieurs : forme inconnue, la page est en échec."""
    if len(nodes) > 1:
        raise ParseError(f"rang {rank} : {len(nodes)} éléments pour le champ {label} (un seul attendu)")
    return nodes[0] if nodes else None


def _title(card: _Node, rank: int) -> str | None:
    # a[role=link] > span > div : le titre. Le lien de l'auteur (a.a-link-child) n'a pas role="link" : jamais lu.
    divs = [div for a in card.iter() if a.tag == "a" and a.attrs.get("role") == "link"
            for span in a.child_nodes("span") for div in span.child_nodes("div")]
    node = _single(divs, rank, "titre")
    if node is None:
        return None
    # Nettoyage limité (décision 011) : entités déjà décodées par l'analyseur ; espaces réduits, insécables compris
    title = re.sub(r"\s+", " ", node.text()).strip()
    if not title:
        raise ParseError(f"rang {rank} : titre vide")
    return title


def _price(card: _Node, rank: int) -> tuple[Decimal | None, str | None]:
    spans = [n for n in card.iter() if n.tag == "span" and any("p13n-sc-price" in c for c in n.classes())]
    node = _single(spans, rank, "prix")
    if node is None:
        return None, None
    raw = node.text().strip(" \t\r\n")
    match = _PRICE.fullmatch(raw)
    if match is None:
        raise ParseError(f"rang {rank} : prix de forme inconnue {raw!r}")
    if match.group(3) not in CURRENCIES:
        raise ParseError(f"rang {rank} : devise non autorisée {match.group(3)!r}")
    amount = Decimal(f"{match.group(1).replace(NBSP, '')}.{match.group(2)}")
    if amount > MAX_PRICE:
        raise ParseError(f"rang {rank} : prix hors limite {raw!r}")
    return amount, CURRENCIES[match.group(3)]


def _rating(card: _Node, rank: int) -> tuple[Decimal | None, int | None]:
    note = _single([n for n in card.iter() if n.tag == "span" and "a-icon-alt" in n.classes()], rank, "note")
    link = _single([n for n in card.iter() if n.tag == "a" and "étoiles" in (n.attrs.get("aria-label") or "")],
                   rank, "lien des étoiles")
    if note is None and link is None:
        return None, None  # livre sans évaluation affichée
    if note is None or link is None:
        raise ParseError(f"rang {rank} : note et nombre d'évaluations non affichés ensemble")

    raw_note = note.text().strip(" \t\r\n")
    match = _RATING.fullmatch(raw_note)
    if match is None:
        raise ParseError(f"rang {rank} : note de forme inconnue {raw_note!r}")
    rating = Decimal(f"{match.group(1)}.{match.group(2)}")
    if rating > MAX_RATING:
        raise ParseError(f"rang {rank} : note supérieure à 5 {raw_note!r}")

    label = link.attrs["aria-label"]
    label_match = _RATING_LINK.fullmatch(label)
    if label_match is None:
        raise ParseError(f"rang {rank} : aria-label des étoiles de forme inconnue {label!r}")
    visible = _single([n for n in link.iter() if n.tag == "span" and "a-size-small" in n.classes()],
                      rank, "nombre d'évaluations")
    if visible is None:
        raise ParseError(f"rang {rank} : nombre d'évaluations absent du lien des étoiles")
    raw_count = visible.text().strip(" \t\r\n")
    if not _COUNT.fullmatch(raw_count):
        raise ParseError(f"rang {rank} : nombre d'évaluations de forme inconnue {raw_count!r}")
    count = int(raw_count.replace(NBSP, ""))
    if Decimal(f"{label_match.group(1)}.{label_match.group(2)}") != rating \
            or int(label_match.group(3).replace(NBSP, "")) != count:
        raise ParseError(f"rang {rank} : note ou nombre d'évaluations différent de l'aria-label {label!r}")
    return rating, count


def _cover(card: _Node, rank: int) -> str | None:
    images = [n for n in card.iter() if n.tag == "img" and "p13n-product-image" in n.classes()]
    node = _single(images, rank, "couverture")
    if node is None:
        return None
    src = node.attrs.get("src") or ""
    # Adresse d'origine seulement : une adresse réécrite (Ctrl+S « page complète ») ou vide n'est pas acceptée
    if not src.startswith("https://"):
        raise ParseError(f"rang {rank} : adresse de couverture inattendue {src[:80]!r}")
    return src
