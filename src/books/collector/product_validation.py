"""Validation d'une fiche produit capturée (décision 015, section 5).

Même principe que la page de classement (décision 004) : fail closed, la fiche n'est conforme que si quatre indices
concordent avec la demande (l'ASIN tiré de l'adresse affichée) :
1. canonical : un seul lien canonical distinct, dont l'ASIN (asin_from_url, décision 015, section 3) est l'ASIN
   demandé ;
2. titre : exactement un élément id="productTitle", au texte non vide ;
3. ASIN des détails : dans la liste « Détails sur le produit » (div#detailBullets_feature_div la plus externe : il y en a
   deux, imbriquées), la ligne « ASIN : » si elle existe, sinon la ligne « ISBN-10 : » (livre papier dont l'ISBN-10 sert
   d'ASIN), tirets retirés : exactement une ligne lue, de valeur égale à l'ASIN demandé (amendement du 10 octobre
   2026). Quand la ligne « ASIN : » existe, une ligne « ISBN-10 : » est ignorée ;
4. format : dans la ligne d'auteur (div#bylineInfo), exactement un libellé « Format : », suivi d'un format accepté :
   ebook Kindle, broché ou relié (décision 015, section 4). Tout autre format (livre audio, poche tant qu'il n'est pas
   observé…) rend la fiche non conforme.
Libellés comparés après retrait des marques de direction invisibles (U+200E, U+200F) et réduction des espaces,
insécables comprises (docs/exploration-amazon.md, repères de validation d'une fiche).

La structure décide, le mot « captcha » ne fait que qualifier, comme pour une page de classement : ok, blocked, invalid.

Les motifs ne recopient aucun texte de la page (titre, ligne d'auteur, format refusé, adresse canonique) : un texte
mal découpé après un changement de structure pourrait contenir un nom (décisions 013 et 015). Ils nomment l'indice et,
au besoin, un compte ; le HTML reste dans RAW pour l'examen.
"""

from html.parser import HTMLParser

from books.amazon.product_page import ProductRequest, asin_from_url
from books.collector.validation import Verdict

# Formats acceptés, tels qu'affichés après « Format : » (valeurs observées le 10 octobre 2026). « Poche » n'y figure
# pas : jamais observé, il sera ajouté après observation (décision 015, section 4, note de l'étape B).
ACCEPTED_FORMATS = ("Format Kindle", "Broché", "Relié")
FORMAT_LABEL = "Format :"
ASIN_LABEL = "ASIN :"
ISBN10_LABEL = "ISBN-10 :"
# Éléments sans balise de fin : jamais empilés
VOID_ELEMENTS = frozenset({"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source",
                           "track", "wbr"})
INVISIBLE_MARKS = dict.fromkeys(map(ord, "\u200e\u200f"), None)


def normalize(text: str) -> str:
    """Marques de direction retirées ; toute suite d'espaces (insécables comprises) réduite à une espace."""
    return " ".join(text.translate(INVISIBLE_MARKS).split())


class _Element:
    __slots__ = ("tag", "role", "text")

    def __init__(self, tag: str, role: str | None, capture: bool) -> None:
        self.tag = tag
        self.role = role  # "byline", "details", "title", "format", "asin", ou None
        self.text: list[str] | None = [] if capture else None


class _ProductScanner(HTMLParser):
    """Relève les canonicals, les titres, la ligne ASIN des détails et le format de la ligne d'auteur."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[_Element] = []
        self.canonicals: list[str] = []
        self.titles: list[str] = []
        self.bylines = 0  # div#bylineInfo
        self.details = 0  # div#detailBullets_feature_div les plus externes
        self.format_labels = 0
        self.formats: list[str] = []
        self.asin_labels = 0
        self.asins: list[str] = []
        self.isbn10_labels = 0
        self.isbn10s: list[str] = []
        self._next_span: str | None = None  # "format", "asin" ou "isbn10" : le prochain span porte la valeur

    def _inside(self, role: str) -> bool:
        return any(e.role == role for e in self.stack)

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if tag == "link" and "canonical" in (attributes.get("rel") or "").split():
            self.canonicals.append(attributes.get("href") or "")
        if tag in VOID_ELEMENTS:
            return
        element_id = attributes.get("id")
        role, capture = None, False
        if element_id == "productTitle":
            role, capture = "title", True
        elif element_id == "bylineInfo":
            self.bylines += 1
            role = "byline"
        elif element_id == "detailBullets_feature_div" and not self._inside("details"):
            self.details += 1
            role = "details"
        elif tag == "span" and (self._inside("byline") or self._inside("details")):
            if self._next_span:
                role, self._next_span = self._next_span, None
            elif self._inside("details") and "a-text-bold" in (attributes.get("class") or "").split():
                role = "asin_label"
            elif self._inside("byline"):
                role = "format_label"
            capture = role is not None
        self.stack.append(_Element(tag, role, capture))

    def handle_endtag(self, tag: str) -> None:
        # Ferme l'élément ouvert de même nom le plus proche, et ceux qu'il contient (HTML mal fermé)
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index].tag == tag:
                closed = self.stack[index:]
                del self.stack[index:]
                for element in reversed(closed):
                    self._close(element)
                return

    def _close(self, element: _Element) -> None:
        if element.role in ("byline", "details"):
            self._next_span = None  # un libellé sans valeur ne se prolonge jamais hors de son bloc
        if element.text is None:
            return
        text = normalize("".join(element.text))
        if element.role == "title":
            self.titles.append(text)
        elif element.role == "format":
            self.formats.append(text)
        elif element.role == "asin":
            self.asins.append(text)
        elif element.role == "isbn10":
            self.isbn10s.append(text)
        elif element.role == "format_label" and text == FORMAT_LABEL:
            self.format_labels += 1
            self._next_span = "format"
        elif element.role == "asin_label" and text == ASIN_LABEL:
            self.asin_labels += 1
            self._next_span = "asin"
        elif element.role == "asin_label" and text == ISBN10_LABEL:
            self.isbn10_labels += 1
            self._next_span = "isbn10"

    def handle_data(self, data: str) -> None:
        for element in self.stack:
            if element.text is not None:
                element.text.append(data)


def _check_canonical(scanner: _ProductScanner, request: ProductRequest) -> list[str]:
    canonicals = set(scanner.canonicals)
    if not canonicals:
        return ["lien canonical absent"]
    if len(canonicals) > 1:
        return [f"{len(canonicals)} liens canonical différents (un seul attendu)"]
    asin, _ = asin_from_url(canonicals.pop())
    if asin is None:
        return ["canonical hors des fiches produit"]
    if asin != request.asin:
        return ["canonical : ASIN différent de celui de l'adresse affichée"]
    return []


def _check_title(scanner: _ProductScanner) -> list[str]:
    if not scanner.titles:
        return ["titre (productTitle) introuvable"]
    if len(scanner.titles) > 1:
        return [f"{len(scanner.titles)} titres (productTitle), un seul attendu"]
    if not scanner.titles[0]:
        return ["titre (productTitle) vide"]
    return []


def _check_details_asin(scanner: _ProductScanner, request: ProductRequest) -> list[str]:
    if not scanner.details:
        return ["liste des détails (detailBullets_feature_div) introuvable"]
    if scanner.details > 1:
        return [f"{scanner.details} listes des détails distinctes (une seule attendue)"]
    if not scanner.asin_labels:
        return _check_details_isbn10(scanner, request)
    if scanner.asin_labels > 1:
        return [f"{scanner.asin_labels} lignes ASIN dans la liste des détails (une seule attendue)"]
    if len(scanner.asins) != 1:
        return ["ligne ASIN de la liste des détails sans valeur"]
    if scanner.asins[0] != request.asin:
        return ["ASIN de la liste des détails différent de celui de l'adresse affichée"]
    return []


def _check_details_isbn10(scanner: _ProductScanner, request: ProductRequest) -> list[str]:
    """Sans ligne « ASIN : » : la ligne « ISBN-10 : », tirets retirés, porte l'ASIN (livre papier, amendement du
    10 octobre 2026)."""
    if not scanner.isbn10_labels:
        return ["ni ligne ASIN ni ligne ISBN-10 dans la liste des détails"]
    if scanner.isbn10_labels > 1:
        return [f"{scanner.isbn10_labels} lignes ISBN-10 dans la liste des détails, sans ligne ASIN (une seule attendue)"]
    if len(scanner.isbn10s) != 1:
        return ["ligne ISBN-10 de la liste des détails sans valeur"]
    if scanner.isbn10s[0].replace("-", "") != request.asin:
        return ["ISBN-10 de la liste des détails différent de l'ASIN de l'adresse affichée"]
    return []


def _check_format(scanner: _ProductScanner) -> list[str]:
    if not scanner.bylines:
        return ["ligne d'auteur (bylineInfo) introuvable"]
    if scanner.bylines > 1:
        return [f"{scanner.bylines} lignes d'auteur (bylineInfo), une seule attendue"]
    if not scanner.format_labels:
        return ["format introuvable dans la ligne d'auteur"]
    if scanner.format_labels > 1:
        return [f"{scanner.format_labels} formats dans la ligne d'auteur (un seul attendu)"]
    if len(scanner.formats) != 1:
        return ["format de la ligne d'auteur sans valeur"]
    if scanner.formats[0] not in ACCEPTED_FORMATS:
        return ["format affiché non accepté (ni ebook Kindle, ni broché, ni relié)"]
    return []


def validate_product_page(content: bytes, request: ProductRequest) -> Verdict:
    """Contrôle qu'une page capturée est bien la fiche demandée, dans un format accepté."""
    text = content.decode("utf-8", errors="replace")
    scanner = _ProductScanner()
    scanner.feed(text)
    scanner.close()

    problems = (_check_canonical(scanner, request) + _check_title(scanner)
                + _check_details_asin(scanner, request) + _check_format(scanner))
    if not problems:
        return Verdict(status="ok", reason=None)
    if "captcha" in text.lower():
        return Verdict(status="blocked", reason="CAPTCHA détecté : " + " ; ".join(problems))
    return Verdict(status="invalid", reason="Fiche non conforme : " + " ; ".join(problems))
