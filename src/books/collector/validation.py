"""Validation d'une page de classement reçue (décision 004).

Triangulation, fail closed : la page n'est conforme que si quatre indices indépendants
concordent avec la demande (catégorie, type de liste, numéro de page) :
1. canonical : https://www.amazon.fr/gp/bestsellers/digital-text/{catégorie demandée} ;
2. onglet actif (span aria-current="page" dans ul role="tablist") : « Top 100 payants » (paid)
   ou « Top 100 gratuits » (free) ;
3. pagination : si elle existe, la page active est la page demandée ; si elle est absente,
   seule une demande de page 1 est acceptée (liste courte) ;
4. rangs (render.zg.rank) : une seule liste classée, premier rang = (page - 1) × 50 + 1,
   tous les rangs dans la plage de la page (1-50, 51-100), aucun rang ni ASIN en double (décision 011).
   Un trou dans la suite est seulement signalé (information).
Un indice introuvable rend la page non conforme : rien n'est supposé par défaut. Les prix ne servent pas d'indice.

La structure décide, le mot « captcha » ne fait que qualifier :
- page conforme : « ok », même si le mot « captcha » y figure (un titre de livre peut le contenir) ;
- page non conforme et signe de CAPTCHA : « blocked » ;
- page non conforme sans signe de CAPTCHA : « invalid ».
"""

import re
from collections import Counter
from dataclasses import dataclass, field
from html.parser import HTMLParser

# Définition de la liste classée commune à la validation et à l'extracteur (décision 011)
from books.amazon.ranked_list import RANK_KEY, rank_value, ranked_items
from books.collector.targets import MAX_PAGES_PER_LIST, PageRequest, canonical_url
# Une page de classement compte au plus 50 rangs ; en dessous, c'est une liste courte (information)
FULL_LIST_SIZE = 50
# Libellé de l'onglet actif pour chaque type de liste (textes d'interface observés le 5 octobre 2026)
ACTIVE_TAB_LIST_TYPE = {"Top 100 payants": "paid", "Top 100 gratuits": "free"}


@dataclass(frozen=True)
class Verdict:
    status: str  # "ok", "blocked" ou "invalid" (valeurs de raw.raw_page.fetch_status)
    reason: str | None  # explication, enregistrée dans error_message si la page n'est pas ok
    rank_count: int  # nombre de livres classés trouvés
    notes: tuple[str, ...] = field(default=())  # informations sans effet sur le statut
    # La pagination annonce la page suivante (li aria-label="Page {n+1}", non désactivé).
    # Second signal, avec les 50 rangs, pour décider de demander la page 2 (décision 004).
    next_page_announced: bool = False

    @property
    def short_list(self) -> bool:
        return self.status == "ok" and self.rank_count < FULL_LIST_SIZE


class _PageScanner(HTMLParser):
    """Relève les liens canonical, les listes data-client-recs-list, l'onglet actif et la pagination."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.canonicals: list[str] = []
        self.recs_lists: list[str] = []
        # Texte de chaque span aria-current="page" situé dans un ul role="tablist".
        # Hors de la rangée d'onglets, l'arborescence des catégories porte aussi un span
        # aria-current="page" (catégorie courante) : il n'est pas un onglet.
        self.active_tabs: list[str] = []
        self.pagination_found = False  # un ul.a-pagination existe
        self.selected_pages: list[str] = []  # aria-label des li.a-selected de la pagination
        self.enabled_pages: list[str] = []  # aria-label des li de la pagination non désactivés
        self._in_tablist = 0  # profondeur des ul ouverts depuis ul role="tablist"
        self._tab_depth = 0  # > 0 : à l'intérieur d'un onglet actif
        self._tab_text: list[str] = []
        self._in_pagination = 0  # profondeur des ul ouverts depuis ul.a-pagination

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        classes = (attributes.get("class") or "").split()
        if tag == "link" and "canonical" in (attributes.get("rel") or "").split():
            self.canonicals.append(attributes.get("href") or "")
        value = attributes.get("data-client-recs-list")
        if value is not None:
            self.recs_lists.append(value)
        if tag == "span":
            if self._tab_depth:
                self._tab_depth += 1
            elif self._in_tablist and attributes.get("aria-current") == "page":
                self._tab_depth = 1
                self._tab_text = []
        if tag == "ul":
            if self._in_tablist:
                self._in_tablist += 1
            elif attributes.get("role") == "tablist":
                self._in_tablist = 1
            if self._in_pagination:
                self._in_pagination += 1
            elif "a-pagination" in classes:
                self.pagination_found = True
                self._in_pagination = 1
        if tag == "li" and self._in_pagination:
            label = attributes.get("aria-label") or ""
            if "a-selected" in classes:
                self.selected_pages.append(label)
            if label and "a-disabled" not in classes:
                self.enabled_pages.append(label.strip())

    def handle_endtag(self, tag: str) -> None:
        if tag == "span" and self._tab_depth:
            self._tab_depth -= 1
            if not self._tab_depth:
                self.active_tabs.append(" ".join("".join(self._tab_text).split()))
        if tag == "ul":
            if self._in_tablist:
                self._in_tablist -= 1
            if self._in_pagination:
                self._in_pagination -= 1

    def handle_data(self, data: str) -> None:
        if self._tab_depth:
            self._tab_text.append(data)


def _check_canonical(scanner: _PageScanner, request: PageRequest) -> list[str]:
    expected = canonical_url(request.node)
    canonicals = set(scanner.canonicals)
    if not canonicals:
        return ["lien canonical absent"]
    if canonicals != {expected}:
        return [f"canonical inattendu : {', '.join(sorted(canonicals))} (attendu : {expected})"]
    return []


def _check_active_tab(scanner: _PageScanner, request: PageRequest) -> list[str]:
    if not scanner.active_tabs:
        return ["onglet actif introuvable"]
    if len(scanner.active_tabs) > 1:
        return [f"{len(scanner.active_tabs)} onglets actifs (un seul attendu)"]
    label = scanner.active_tabs[0]
    list_type = ACTIVE_TAB_LIST_TYPE.get(label)
    if list_type is None:
        return [f"onglet actif inconnu : {label!r}"]
    if list_type != request.list_type:
        return [f"onglet actif {label!r} ({list_type}), liste demandée : {request.list_type}"]
    return []


def _check_pagination(scanner: _PageScanner, request: PageRequest) -> list[str]:
    if not scanner.pagination_found:
        if request.page_number == 1:
            return []  # liste courte : pas de page 2, donc pas de pagination
        return [f"pagination absente, page demandée : {request.page_number}"]
    if len(scanner.selected_pages) != 1:
        return [f"pagination sans page active unique ({len(scanner.selected_pages)} trouvée(s))"]
    match = re.fullmatch(r"Page (\d+)", scanner.selected_pages[0].strip())
    if match is None:
        return [f"page active illisible : {scanner.selected_pages[0]!r}"]
    if int(match.group(1)) != request.page_number:
        return [f"page active {match.group(1)}, page demandée : {request.page_number}"]
    return []


def _check_ranks(scanner: _PageScanner, request: PageRequest) -> tuple[list[str], list[str], int]:
    """Problèmes, informations et nombre de rangs de la liste classée."""
    ranked_lists = [r for r in map(ranked_items, scanner.recs_lists) if r is not None]
    if not ranked_lists:
        return [f"aucune liste contenant {RANK_KEY}"], [], 0
    if len(ranked_lists) > 1:
        return [f"{len(ranked_lists)} listes contenant {RANK_KEY} (une seule attendue)"], [], 0
    items = ranked_lists[0]
    values = [rank_value(item["metadataMap"][RANK_KEY]) for item in items]
    if None in values:
        return [f"{RANK_KEY} non entier"], [], len(items)
    ranks = sorted(values)

    low = (request.page_number - 1) * FULL_LIST_SIZE + 1
    high = request.page_number * FULL_LIST_SIZE
    problems: list[str] = []
    if ranks[0] != low:
        problems.append(f"premier rang {ranks[0]}, attendu {low} pour la page {request.page_number}")
    outside = [r for r in ranks if not low <= r <= high]
    if outside:
        problems.append(f"{len(outside)} rang(s) hors de la plage {low}-{high} (ex. : {outside[0]})")
    # Doublons : page non conforme (décision 011, section 5 bis). Seuls les ASIN en texte sont comparés :
    # une autre valeur ne peut pas être un ASIN, et un objet ne pourrait pas être compté.
    duplicate_ranks = sorted(r for r, n in Counter(ranks).items() if n > 1)
    if duplicate_ranks:
        problems.append(f"{len(duplicate_ranks)} rang(s) en double (ex. : {duplicate_ranks[0]})")
    asins = Counter(item.get("id") for item in items if isinstance(item.get("id"), str))
    duplicate_asins = sorted(a for a, n in asins.items() if n > 1)
    if duplicate_asins:
        problems.append(f"{len(duplicate_asins)} ASIN en double dans la liste classée (ex. : {duplicate_asins[0]})")
    notes: list[str] = []
    if not problems and ranks != list(range(low, low + len(ranks))):
        notes.append(f"suite de rangs non continue (trou) entre {ranks[0]} et {ranks[-1]}")
    return problems, notes, len(items)


def validate_bestseller_page(content: bytes, request: PageRequest) -> Verdict:
    """Contrôle qu'une page reçue est bien la page de classement demandée."""
    text = content.decode("utf-8", errors="replace")
    scanner = _PageScanner()
    scanner.feed(text)
    scanner.close()

    rank_problems, notes, rank_count = _check_ranks(scanner, request)
    problems = (
        _check_canonical(scanner, request)
        + _check_active_tab(scanner, request)
        + _check_pagination(scanner, request)
        + rank_problems
    )

    if not problems:
        next_label = f"Page {request.page_number + 1}"
        return Verdict(status="ok", reason=None, rank_count=rank_count, notes=tuple(notes),
                       next_page_announced=scanner.pagination_found and next_label in scanner.enabled_pages)
    if "captcha" in text.lower():
        return Verdict(status="blocked", reason="CAPTCHA détecté : " + " ; ".join(problems),
                       rank_count=rank_count)
    return Verdict(status="invalid", reason="Page non conforme : " + " ; ".join(problems),
                   rank_count=rank_count)


def next_page(request: PageRequest, verdict: Verdict) -> tuple[PageRequest | None, str | None]:
    """Page suivante attendue après une page conforme, et éventuelle information à signaler.

    Deux signaux doivent concorder : la page compte 50 rangs, et sa pagination annonce la page suivante.
    S'ils divergent, la page suivante n'est ni attendue ni comptée comme manquante : la divergence est signalée
    pour information (décisions 004 et 008). Utilisée par la tournée de dev (page 2 demandée) et par l'ingestion
    (page 2 attendue dans le même lot).
    """
    if request.page_number >= MAX_PAGES_PER_LIST:
        return None, None
    full = verdict.rank_count == FULL_LIST_SIZE
    announced = verdict.next_page_announced
    following = request.page_number + 1
    if full and announced:
        return PageRequest(request.node, request.list_type, following), None
    if full:
        return None, (f"{FULL_LIST_SIZE} rangs, mais la pagination n'annonce pas de page {following} : "
                      f"page {following} non attendue")
    if announced:
        return None, (f"page {following} annoncée par la pagination, mais seulement {verdict.rank_count} rangs : "
                      f"page {following} non attendue")
    return None, None
