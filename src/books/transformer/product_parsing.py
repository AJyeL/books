"""Analyse d'une fiche produit : fonction pure, du HTML aux lignes de STAGING (décision 015, section 6 et étape D).

parse_product_page() reçoit le contenu HTML d'une fiche (octets) et rend une ParsedProduct (observation de la fiche,
onglets de formats, rangs de vente, répartition des notes) ; lève PageSkipped pour une fiche papier (mise à part,
motif « format papier ») ; lève ParseError avec un motif pour toute forme inconnue. Elle n'accède ni à la base, ni aux
fichiers.

Règles (décision 015, notes de l'étape D ; formes de l'inventaire de 431 fiches, docs/exploration-amazon.md) :
- champ absent : None ; champ présent mais de forme inconnue : la fiche entière est en échec (décision 011, section 5) ;
- séparateurs : seuls ceux observés sont acceptés : U+202F dans les rangs, U+00A0 dans les prix et les compteurs d'avis ;
- jamais lus : l'auteur (seuls les span de libellé de la ligne d'auteur sont lus), la valeur de l'éditeur, les avis
  individuels, la mention de livraison, les vendeurs tiers (décisions 013 et 015) ;
- description : texte (espaces normalisés) et balisage de sens (b, i, u, h3 à h5, ul, li, p, br ; aucun attribut),
  chacun avec son empreinte SHA-256 ; span.a-text-bold devient <b>, span.a-text-italic devient <i> ; les autres classes
  de span et les autres balises sont retirées (texte conservé) et comptées, pour le bilan.

Toute modification de ces règles incrémente EXTRACTOR_VERSION dans le même commit (décision 011, section 6).
"""

import hashlib
import re
from collections import Counter
from dataclasses import dataclass
from datetime import date
from decimal import Decimal
from html import escape

from books.transformer.parsing import NBSP, ParseError, _clean, _Node, _TreeBuilder

NNBSP = " "  # espace fine insécable : séparateur des milliers dans les rangs de vente
KINDLE_FORMAT = "Format Kindle"
PAPER_FORMATS = ("Broché", "Relié")
PAPER_REASON = "format papier"
CURRENCIES = {"€": "EUR"}
MAX_PRICE = Decimal("999999.99")  # numeric(8,2)
MONTHS = {name: i for i, name in enumerate(
    "janvier février mars avril mai juin juillet août septembre octobre novembre décembre".split(), start=1)}
INVISIBLE_MARKS = dict.fromkeys(map(ord, "‎‏"), None)

_NBSP_GROUPED = rf"\d{{1,3}}(?:{NBSP}\d{{3}})*"
_NNBSP_GROUPED = rf"\d{{1,3}}(?:{NNBSP}\d{{3}})*"
_PRICE = re.compile(rf"({_NBSP_GROUPED}),(\d{{2}}){NBSP}(\S+)")
_RATING = re.compile(rf"(\d),(\d) sur 5{NBSP}étoiles")
_RATING_SHORT = re.compile(r"(\d),(\d)")
_REVIEWS_VISIBLE = re.compile(rf"\(({_NBSP_GROUPED})\)")
_REVIEWS_LABEL = re.compile(rf"({_NBSP_GROUPED}) (Commentaires?)")
_DATE = re.compile(r"(\d{1,2}) ([a-zéû]+) (\d{4})")
_PAGES = re.compile(r"(\d+) pages")
_SIZE = re.compile(r"(\d+(?:\.\d)?) (KB|MB)")
_ISBN13 = re.compile(r"97[89]-\d{10}")
_SERIES = re.compile(r"Livre (\d+) sur (\d+) :")
_STARS = re.compile(rf"([1-5])[ {NBSP}](étoiles?)")
_PERCENT = re.compile(rf"(\d{{1,3}}){NBSP}?%")
_GENERAL_RANK = re.compile(
    rf"(n°)?({_NNBSP_GROUPED}) (en|des titres gratuits dans la)(?: (Boutique Kindle|Livres) \( \))?")
_CATEGORY_RANK = re.compile(rf"({_NNBSP_GROUPED}) en")
_BESTSELLERS_HREF = re.compile(r"/gp/bestsellers/(digital-text|books)(?:/(\d+))?(?:/ref=[^?]*)?(?:\?(.*))?")
_FREE_LIST = re.compile(r"[?&]tf=1(?![0-9])")
_DP_HREF = re.compile(r"/dp/([A-Z0-9]{10})(?=[/?]|$)")
_KINDLE_BUY = re.compile(rf"ou ({_NBSP_GROUPED},\d{{2}}{NBSP}\S+) pour acheter")
# Balises de sens conservées dans description_markup (br : sans balise de fin)
DESCRIPTION_TAGS = frozenset({"p", "br", "h3", "h4", "h5", "ul", "li", "u"})
_BLOCK_TAGS = frozenset({"p", "br", "h3", "h4", "h5", "ul", "li"})
SPAN_CLASSES = {"a-text-bold": "b", "a-text-italic": "i"}
# Messages d'onglet observés (texte d'interface) ; tout autre fait échouer la fiche
AUDIO_MESSAGES = {"avec votre abonnement": "avec_abonnement", "avec l'offre d'essai": "avec_offre_essai"}
KINDLE_MESSAGES = {"Disponible immédiatement"}


class PageSkipped(Exception):
    """Fiche mise à part, sans échec : le message est le motif (« format papier »)."""


@dataclass(frozen=True)
class ProductFormat:
    """Une ligne de staging.product_format."""

    position: int
    swatch_kind: str
    label: str
    is_selected: bool
    linked_asin: str | None
    price_amount: Decimal | None
    currency: str | None
    price_qualifier: str
    ku_borrow: bool


@dataclass(frozen=True)
class SalesRank:
    """Une ligne de staging.product_sales_rank."""

    position: int
    is_general: bool
    rank: int
    store: str
    category_node: str | None
    list_type: str


@dataclass(frozen=True)
class RatingShare:
    """Une ligne de staging.product_rating_share."""

    stars: int
    percent: int


@dataclass(frozen=True)
class ParsedProduct:
    """Observation d'une fiche (staging.product_observation) et ses lignes de détail ; plus, pour le bilan, les classes
    de span et les balises retirées de la description (informations, jamais des échecs)."""

    format_label: str
    title: str
    series_form: str | None
    series_name: str | None
    series_position: int | None
    series_total: int | None
    publication_date: date | None
    language: str | None
    print_pages: int | None
    file_size_value: Decimal | None
    file_size_unit: str | None
    isbn13: str | None
    rating: Decimal | None
    review_count: int | None
    cover_url: str | None
    description_text: str | None
    description_text_sha256: str | None
    description_markup: str | None
    description_markup_sha256: str | None
    has_aplus: bool | None
    breadcrumb: str | None
    formats: tuple[ProductFormat, ...]
    sales_ranks: tuple[SalesRank, ...]
    rating_shares: tuple[RatingShare, ...]
    unknown_span_classes: tuple[tuple[str, int], ...] = ()
    removed_tags: tuple[tuple[str, int], ...] = ()


def parse_product_page(content: bytes) -> ParsedProduct:
    """Analyse d'une fiche Kindle ; PageSkipped pour une fiche papier ; ParseError pour toute forme inconnue."""
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ParseError(f"contenu qui n'est pas en UTF-8 (octet {exc.start})") from None
    builder = _TreeBuilder()
    builder.feed(text)
    builder.close()
    root = builder.root

    format_label = _format(root)
    if format_label in PAPER_FORMATS:
        raise PageSkipped(PAPER_REASON)
    if format_label != KINDLE_FORMAT:
        raise ParseError("format affiché ni Kindle ni papier")

    details = _details(root)
    series = _series(details)
    rating, review_count, shares = _reviews(root)
    description = _description(root)
    return ParsedProduct(
        format_label=format_label,
        title=_title(root),
        series_form=series[0], series_name=series[1], series_position=series[2], series_total=series[3],
        publication_date=_publication_date(details),
        language=_language(details),
        print_pages=_print_pages(details),
        file_size_value=(size := _file_size(details))[0], file_size_unit=size[1],
        isbn13=_isbn13(details),
        rating=rating, review_count=review_count,
        cover_url=_cover(root),
        description_text=description[0], description_text_sha256=description[1],
        description_markup=description[2], description_markup_sha256=description[3],
        has_aplus=_has_aplus(root),
        breadcrumb=_breadcrumb(root),
        formats=_formats(root),
        sales_ranks=_sales_ranks(details),
        rating_shares=shares,
        unknown_span_classes=description[4], removed_tags=description[5],
    )


# --- Outils ---------------------------------------------------------------------------------------------------

def _outermost(root: _Node, ident: str) -> list[_Node]:
    """Éléments d'identifiant donné, sans ceux contenus dans un autre élément de même identifiant (identifiants
    doublés, comme detailBullets_feature_div)."""
    found: list[_Node] = []

    def walk(node: _Node) -> None:
        for child in node.children:
            if isinstance(child, _Node):
                if child.attrs.get("id") == ident:
                    found.append(child)
                else:
                    walk(child)

    walk(root)
    return found


def _one(root: _Node, ident: str, label: str) -> _Node | None:
    """Élément unique ou absent ; plusieurs : forme inconnue."""
    nodes = _outermost(root, ident)
    if len(nodes) > 1:
        raise ParseError(f"{len(nodes)} éléments pour le champ {label} (un seul attendu)")
    return nodes[0] if nodes else None


def _label(text: str) -> str:
    """Libellé d'interface : marques de direction retirées, toute suite d'espaces réduite à une espace."""
    return " ".join(text.translate(INVISIBLE_MARKS).split())


def _ascii_spaces(text: str) -> str:
    """Espaces ordinaires (et sauts de ligne) réduits ; insécables conservés, pour contrôler les séparateurs."""
    return re.sub(r"[ \t\r\n]+", " ", text).strip(" ")


# Éléments dont le contenu n'est pas du texte affiché : jamais lus (des <script> figurent dans les onglets de formats)
_NOT_TEXT = frozenset({"script", "style", "noscript", "template"})


def _text(node: _Node) -> str:
    """Texte affiché d'un élément : le contenu des script, style, noscript et template n'est pas lu."""
    return "".join(c if isinstance(c, str) else ("" if c.tag in _NOT_TEXT else _text(c)) for c in node.children)


def _direct_text(node: _Node) -> str:
    return "".join(c for c in node.children if isinstance(c, str))


def _first(node: _Node, css_class: str) -> _Node | None:
    return next((n for n in node.iter() if css_class in n.classes()), None)


def _price(raw: str, field: str) -> tuple[Decimal, str]:
    match = _PRICE.fullmatch(raw)
    if match is None:
        raise ParseError(f"{field} : prix de forme inconnue {raw!r}")
    if match.group(3) not in CURRENCIES:
        raise ParseError(f"{field} : devise non autorisée {match.group(3)!r}")
    amount = Decimal(f"{match.group(1).replace(NBSP, '')}.{match.group(2)}")
    if amount > MAX_PRICE:
        raise ParseError(f"{field} : prix hors limite {raw!r}")
    return amount, CURRENCIES[match.group(3)]


# --- Format, titre --------------------------------------------------------------------------------------------

def _format(root: _Node) -> str:
    """Format affiché : le span qui suit le libellé « Format : » parmi les enfants directs de div#bylineInfo. Seuls les
    span de libellé (classe a-color-secondary) sont lus : le texte de l'auteur ne l'est jamais."""
    byline = _one(root, "bylineInfo", "ligne d'auteur")
    if byline is None:
        raise ParseError("ligne d'auteur (bylineInfo) introuvable")
    children = [c for c in byline.children if isinstance(c, _Node)]
    labels = [i for i, c in enumerate(children)
              if c.tag == "span" and "a-color-secondary" in c.classes() and _label(_text(c)) == "Format :"]
    if len(labels) != 1:
        raise ParseError(f"{len(labels)} libellé(s) « Format : » dans la ligne d'auteur (un seul attendu)")
    following = children[labels[0] + 1:labels[0] + 2]
    if not following or following[0].tag != "span":
        raise ParseError("format de la ligne d'auteur sans valeur")
    return _clean(_text(following[0]))


def _title(root: _Node) -> str:
    node = _one(root, "productTitle", "titre")
    if node is None:
        raise ParseError("titre (productTitle) introuvable")
    title = _clean(_text(node))
    if not title:
        raise ParseError("titre vide")
    return title


# --- Liste des détails ----------------------------------------------------------------------------------------

def _details(root: _Node) -> dict[str, tuple[_Node, _Node, _Node | None]]:
    """Lignes de la liste « Détails sur le produit » : libellé -> (contenant, libellé en gras, valeur). La valeur est
    l'élément qui suit le libellé ; elle n'est lue que pour les champs extraits (jamais celle de l'éditeur)."""
    box = _one(root, "detailBullets_feature_div", "liste des détails")
    rows: dict[str, tuple[_Node, _Node, _Node | None]] = {}
    if box is None:
        return rows

    def walk(node: _Node) -> None:
        for child in node.children:
            if not isinstance(child, _Node):
                continue
            if child.tag == "ul" and "zg_hrsr" in child.classes():
                continue  # rangs de catégorie : lus avec le classement
            if child.tag == "li":
                item = next((c for c in child.children if isinstance(c, _Node) and c.tag == "span"), None)
                bold_index = None if item is None else next(
                    (i for i, c in enumerate(item.children)
                     if isinstance(c, _Node) and c.tag == "span" and "a-text-bold" in c.classes()), None)
                if bold_index is not None:
                    bold = item.children[bold_index]
                    label = _label(_text(bold))
                    value = next((c for c in item.children[bold_index + 1:] if isinstance(c, _Node)), None)
                    if label in rows:
                        raise ParseError(f"libellé en double dans la liste des détails : {label!r}")
                    rows[label] = (item, bold, value)
                    continue
            walk(child)

    walk(box)
    return rows


def _value(details: dict, label: str) -> str | None:
    """Texte de la valeur d'une ligne de détail (espaces ordinaires réduits), ou None si la ligne est absente."""
    row = details.get(label)
    if row is None:
        return None
    if row[2] is None:
        raise ParseError(f"ligne {label!r} sans valeur")
    return _ascii_spaces(_text(row[2]))


def _series(details: dict) -> tuple[str | None, str | None, int | None, int | None]:
    rows = [(label, row) for label, row in details.items()
            if _SERIES.fullmatch(label) or label == "Fait partie de la série :"]
    if not rows:
        return None, None, None, None
    if len(rows) > 1:
        raise ParseError(f"{len(rows)} lignes de série dans la liste des détails (une seule attendue)")
    label, (_, _, value) = rows[0]
    if value is None or value.tag != "a" or not (name := _clean(_text(value))):
        raise ParseError("série sans nom (lien) dans la liste des détails")
    match = _SERIES.fullmatch(label)
    if match is None:
        return "fait_partie", name, None, None
    position, total = int(match.group(1)), int(match.group(2))
    if not 1 <= position <= total:
        raise ParseError(f"rang dans la série incohérent : {label!r}")
    return "livre_n_sur_n", name, position, total


def _publication_date(details: dict) -> date | None:
    raw = _value(details, "Date de publication :")
    if raw is None:
        return None
    match = _DATE.fullmatch(raw)
    if match is None or match.group(2) not in MONTHS:
        raise ParseError(f"date de publication de forme inconnue {raw!r}")
    try:
        return date(int(match.group(3)), MONTHS[match.group(2)], int(match.group(1)))
    except ValueError:
        raise ParseError(f"date de publication impossible {raw!r}") from None


def _language(details: dict) -> str | None:
    raw = _value(details, "Langue :")
    if raw is None:
        return None
    language = _clean(raw)
    if not language:
        raise ParseError("langue vide")
    return language


def _print_pages(details: dict) -> int | None:
    raw = _value(details, "Nombre de pages de l'édition imprimée :")
    if raw is None:
        return None
    match = _PAGES.fullmatch(raw)
    if match is None or int(match.group(1)) < 1:
        raise ParseError(f"nombre de pages de forme inconnue {raw!r}")
    return int(match.group(1))


def _file_size(details: dict) -> tuple[Decimal | None, str | None]:
    raw = _value(details, "Taille du fichier :")
    if raw is None:
        return None, None
    match = _SIZE.fullmatch(raw)
    if match is None or Decimal(match.group(1)) <= 0:
        raise ParseError(f"taille du fichier de forme inconnue {raw!r}")
    return Decimal(match.group(1)), match.group(2)


def _isbn13(details: dict) -> str | None:
    raw = _value(details, "ISBN-13 :")
    if raw is None:
        return None
    if not _ISBN13.fullmatch(raw):
        raise ParseError(f"ISBN-13 de forme inconnue {raw!r}")
    return raw


# --- Rangs de vente -------------------------------------------------------------------------------------------

def _bestsellers_link(link: _Node, field: str) -> tuple[str, str | None, str]:
    """Boutique, numéro de catégorie et liste (tf=1 : Top gratuit) d'un lien /gp/bestsellers/…"""
    href = link.attrs.get("href") or ""
    match = _BESTSELLERS_HREF.fullmatch(href)
    if match is None:
        raise ParseError(f"{field} : lien de classement de forme inconnue")
    # Top gratuit : tf=1 après « ? » ou « & », où qu'il soit. Le lien du rang général gratuit est mal formé par Amazon
    # (« …/digital-text?tf=1/ref=…?tf=1 », deux « ? ») : une lecture ordinaire des paramètres le manquerait.
    return match.group(1), match.group(2), "free" if _FREE_LIST.search(href) else "paid"


def _sales_ranks(details: dict) -> tuple[SalesRank, ...]:
    row = next((r for label, r in details.items() if label == "Classement des meilleures ventes d'Amazon :"), None)
    if row is None:
        return ()
    item, bold, _ = row
    after = item.children[item.children.index(bold) + 1:]
    strings, links, lists = [], [], []
    for child in after:
        if isinstance(child, str):
            if not lists:
                strings.append(child)
        elif child.tag == "ul" and "zg_hrsr" in child.classes():
            lists.append(child)
        elif child.tag == "a" and not lists:
            links.append(child)
    ranks: list[SalesRank] = []
    general = _ascii_spaces(" ".join(strings))
    match = _GENERAL_RANK.fullmatch(general)
    if match is None or len(links) != 1:
        raise ParseError(f"rang général de forme inconnue {general[:60]!r}")
    store, node, list_type = _bestsellers_link(links[0], "rang général")
    prefix, phrase, shop = match.group(1), match.group(3), match.group(4)
    free = phrase == "des titres gratuits dans la"
    expected_store = {"Boutique Kindle": "digital-text", "Livres": "books"}.get(shop)
    if (free != (prefix is not None) or free != (list_type == "free") or (free and shop != "Boutique Kindle")
            or (shop is None and node is None) or (shop is not None and (node is not None or store != expected_store))):
        raise ParseError(f"rang général incohérent avec son lien {general[:60]!r}")
    ranks.append(SalesRank(len(ranks) + 1, True, int(match.group(2).replace(NNBSP, "")), store, node, list_type))

    for ul in lists:
        for li in (c for c in ul.children if isinstance(c, _Node) and c.tag == "li"):
            span = next((c for c in li.children if isinstance(c, _Node) and c.tag == "span"), li)
            pending: list[str] = []
            pairs = 0
            for child in span.children:
                if isinstance(child, str):
                    pending.append(child)
                elif child.tag == "a":
                    text = _ascii_spaces("".join(pending))
                    cat = _CATEGORY_RANK.fullmatch(text)
                    if cat is None:
                        raise ParseError(f"rang de catégorie de forme inconnue {text[:40]!r}")
                    store, node, list_type = _bestsellers_link(child, "rang de catégorie")
                    if node is None:
                        raise ParseError("rang de catégorie sans numéro de catégorie")
                    ranks.append(SalesRank(len(ranks) + 1, False, int(cat.group(1).replace(NNBSP, "")),
                                           store, node, list_type))
                    pending, pairs = [], pairs + 1
            if pairs == 0 or _ascii_spaces("".join(pending)):
                raise ParseError("rang de catégorie sans lien, ou texte après le dernier lien")
    return tuple(ranks)


# --- Note, avis, répartition ----------------------------------------------------------------------------------

def _reviews(root: _Node) -> tuple[Decimal | None, int | None, tuple[RatingShare, ...]]:
    shares = _rating_shares(root)
    block = _one(root, "averageCustomerReviews", "bloc des avis")
    popover = _one(block, "acrPopover", "note") if block is not None else None
    counter = _one(block, "acrCustomerReviewText", "nombre d'avis") if block is not None else None
    if popover is None and counter is None:
        # Compteur absent : 0 avis si la répartition est entièrement à 0 %, sinon inconnu (décision 015, section 6)
        zero = bool(shares) and all(s.percent == 0 for s in shares)
        return None, 0 if zero else None, shares
    if popover is None or counter is None:
        raise ParseError("note et nombre d'avis non affichés ensemble")

    icon = _first(popover, "a-icon-alt")
    raw = (_text(icon) if icon is not None else "").strip(" \t\r\n")
    match = _RATING.fullmatch(raw)
    if match is None:
        raise ParseError(f"note de forme inconnue {raw!r}")
    rating = Decimal(f"{match.group(1)}.{match.group(2)}")
    if rating > 5:
        raise ParseError(f"note supérieure à 5 {raw!r}")
    short = next((n for n in popover.iter() if "a-size-small" in n.classes() and "a-color-base" in n.classes()), None)
    if short is not None:
        short_match = _RATING_SHORT.fullmatch(_text(short).strip(" \t\r\n"))
        if short_match is None or Decimal(f"{short_match.group(1)}.{short_match.group(2)}") != rating:
            raise ParseError("note abrégée différente de la note de l'icône")

    visible = _text(counter).strip(" \t\r\n")
    visible_match = _REVIEWS_VISIBLE.fullmatch(visible)
    if visible_match is None:
        raise ParseError(f"nombre d'avis de forme inconnue {visible!r}")
    count = int(visible_match.group(1).replace(NBSP, ""))
    label = counter.attrs.get("aria-label") or ""
    label_match = _REVIEWS_LABEL.fullmatch(label)
    if label_match is None or int(label_match.group(1).replace(NBSP, "")) != count:
        raise ParseError(f"aria-label du nombre d'avis de forme inconnue ou différent {label!r}")
    if (label_match.group(2) == "Commentaire") != (count == 1):
        raise ParseError(f"accord de « Commentaire » inattendu {label!r}")
    return rating, count, shares


def _rating_shares(root: _Node) -> tuple[RatingShare, ...]:
    """Répartition par étoiles : texte direct des colonnes gauche (niveau) et droite (pourcentage) de chaque ligne ;
    les colonnes cachées (les cinq libellés et pourcentages servant à la mise en page) ne sont pas lues."""
    table = _one(root, "histogramTable", "répartition des notes")
    if table is None:
        return ()
    rows = [c for c in table.children if isinstance(c, _Node) and c.tag == "li"]
    if len(rows) != 5:
        raise ParseError(f"répartition des notes : {len(rows)} ligne(s) (cinq attendues)")
    shares = []
    for row in rows:
        left, right = _first(row, "a-text-left"), _first(row, "a-text-right")
        stars_raw = _direct_text(left).strip(" \t\r\n") if left is not None else ""
        percent_raw = _direct_text(right).strip(" \t\r\n") if right is not None else ""
        stars, percent = _STARS.fullmatch(stars_raw), _PERCENT.fullmatch(percent_raw)
        if stars is None or (stars.group(2) == "étoile") != (stars.group(1) == "1"):
            raise ParseError(f"répartition des notes : niveau de forme inconnue {stars_raw!r}")
        if percent is None or int(percent.group(1)) > 100:
            raise ParseError(f"répartition des notes : pourcentage de forme inconnue {percent_raw!r}")
        shares.append(RatingShare(int(stars.group(1)), int(percent.group(1))))
    if sorted(s.stars for s in shares) != [1, 2, 3, 4, 5]:
        raise ParseError("répartition des notes : niveaux d'étoiles manquants ou en double")
    return tuple(shares)


# --- Couverture, description, A+, fil de catégories -----------------------------------------------------------

def _cover(root: _Node) -> str | None:
    image = _one(root, "landingImage", "couverture")
    if image is None:
        return None
    url = image.attrs.get("data-old-hires") or ""
    if not url:
        return None
    if not url.startswith("https://"):
        raise ParseError(f"adresse de couverture inattendue {url[:60]!r}")
    return url


def _description(root: _Node):
    """(texte, empreinte, balisage, empreinte, classes de span inconnues, balises retirées) ; quatre None si la
    description est absente ou vide."""
    block = _one(root, "bookDescription_feature_div", "description")
    content = _first(block, "a-expander-content") if block is not None else None
    if content is None:
        return None, None, None, None, (), ()
    unknown_classes: Counter[str] = Counter()
    removed: Counter[str] = Counter()

    def text_of(node: _Node) -> str:
        parts = []
        for child in node.children:
            if isinstance(child, str):
                parts.append(child)
            elif child.tag in _NOT_TEXT:
                continue
            else:
                inner = text_of(child)
                parts.append(f" {inner} " if child.tag in _BLOCK_TAGS else inner)
        return "".join(parts)

    def markup_of(node: _Node) -> str:
        parts = []
        for child in node.children:
            if isinstance(child, str):
                parts.append(escape(child, quote=False))
            elif child.tag in _NOT_TEXT:
                removed[child.tag] += 1
            elif child.tag == "br":
                parts.append("<br>")
            elif child.tag in DESCRIPTION_TAGS:
                parts.append(f"<{child.tag}>{markup_of(child)}</{child.tag}>")
            elif child.tag == "span":
                classes = child.classes()
                unknown_classes.update(c for c in classes if c not in SPAN_CLASSES)
                inner = markup_of(child)
                for css in ("a-text-italic", "a-text-bold"):  # <b><i>…</i></b> quand les deux classes sont présentes
                    if css in classes:
                        inner = f"<{SPAN_CLASSES[css]}>{inner}</{SPAN_CLASSES[css]}>"
                parts.append(inner)
            else:
                removed[child.tag] += 1
                parts.append(markup_of(child))
        return "".join(parts)

    text = _clean(text_of(content))
    if not text:
        return None, None, None, None, (), ()
    markup = _clean(markup_of(content))
    digest = lambda s: hashlib.sha256(s.encode("utf-8")).hexdigest()  # noqa: E731
    return (text, digest(text), markup, digest(markup),
            tuple(sorted(unknown_classes.items())), tuple(sorted(removed.items())))


def _has_aplus(root: _Node) -> bool | None:
    block = _one(root, "aplus_feature_div", "bloc A+")
    if block is None:
        return None
    return any(n.tag not in _NOT_TEXT for n in block.iter())


def _breadcrumb(root: _Node) -> str | None:
    block = _one(root, "wayfinding-breadcrumbs_feature_div", "fil de catégories")
    if block is None:
        return None
    levels = [_clean(_text(a)) for a in block.iter() if a.tag == "a"]
    if any(not level for level in levels):
        raise ParseError("fil de catégories : niveau vide")
    return " › ".join(levels) or None


# --- Onglets de formats ---------------------------------------------------------------------------------------

def _formats(root: _Node) -> tuple[ProductFormat, ...]:
    block = _one(root, "tmmSwatches", "onglets de formats")
    if block is None:
        return ()
    swatches = [n for n in block.iter() if (n.attrs.get("id") or "").startswith("tmm-grid-swatch-")]
    formats = []
    for position, swatch in enumerate(swatches, start=1):
        kind = swatch.attrs["id"][len("tmm-grid-swatch-"):]
        field = f"onglet {kind}"
        if not re.fullmatch(r"[A-Z_]+", kind):
            raise ParseError(f"onglet d'identifiant inconnu {kind[:30]!r}")
        selected = "selected" in swatch.classes()
        title = _first(swatch, "slot-title")
        label = _clean(_text(title)) if title is not None else ""
        if not label:
            raise ParseError(f"{field} : libellé absent")
        link = next((n for n in swatch.iter() if n.tag == "a"), None)
        dp = _DP_HREF.search(link.attrs.get("href") or "") if link is not None else None
        linked = dp.group(1) if dp else None
        if selected != (linked is None):
            raise ParseError(f"{field} : lien vers une fiche incohérent avec la sélection")

        price_nodes = [n for n in swatch.iter() if "slot-price" in n.classes()]
        if len(price_nodes) != 1:
            raise ParseError(f"{field} : {len(price_nodes)} prix (un seul attendu)")
        raw = _text(price_nodes[0]).strip(" \t\r\n")
        extra = _first(swatch, "slot-extraMessage")
        message = _ascii_spaces(_text(extra)) if extra is not None else None
        ku = False
        if raw == "Emprunt":
            if kind not in ("KINDLE", "OTHER") or message is None:
                raise ParseError(f"{field} : « Emprunt » hors de l'onglet de l'ebook, ou sans prix d'achat")
            buy = _KINDLE_BUY.fullmatch(message)
            if buy is None:
                raise ParseError(f"{field} : message d'achat de forme inconnue {message[:40]!r}")
            amount, currency = _price(buy.group(1), field)
            qualifier, ku = "exact", True
        elif raw == "—":
            amount, currency, qualifier = None, None, "non_affiche"
        elif raw.startswith("à partir de "):
            amount, currency = _price(raw[len("à partir de "):], field)
            qualifier = "a_partir_de"
        else:
            amount, currency = _price(raw, field)
            qualifier = "exact"
        if not ku and message is not None:
            if kind == "AUDIO_DOWNLOAD" and message in AUDIO_MESSAGES and qualifier == "exact":
                qualifier = AUDIO_MESSAGES[message]
            elif not (kind in ("KINDLE", "OTHER") and message in KINDLE_MESSAGES):
                raise ParseError(f"{field} : message de forme inconnue {message[:40]!r}")
        formats.append(ProductFormat(position, kind, label, selected, linked, amount, currency, qualifier, ku))
    if sum(f.is_selected for f in formats) != 1:
        raise ParseError(f"{sum(f.is_selected for f in formats)} onglet(s) sélectionné(s) (un seul attendu)")
    return tuple(formats)
