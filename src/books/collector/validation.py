"""Validation d'une page de classement reçue (décision 004).

La structure décide, le mot « captcha » ne fait que qualifier :
- canonical conforme ET liste classée (render.zg.rank) présente : page « ok »,
  même si le mot « captcha » y figure (un titre de livre peut le contenir) ;
- structure manquante et signe de CAPTCHA : « blocked » ;
- structure manquante sans signe de CAPTCHA : « invalid ».
"""

import json
from dataclasses import dataclass
from html.parser import HTMLParser

from books.collector.targets import canonical_url

RANK_KEY = "render.zg.rank"
# Une liste complète compte 50 rangs ; en dessous, c'est une liste courte (information, pas une erreur)
FULL_LIST_SIZE = 50


@dataclass(frozen=True)
class Verdict:
    status: str  # "ok", "blocked" ou "invalid" (valeurs de raw.raw_page.fetch_status)
    reason: str | None  # explication, enregistrée dans error_message si la page n'est pas ok
    rank_count: int  # nombre de livres classés trouvés

    @property
    def short_list(self) -> bool:
        return self.status == "ok" and self.rank_count < FULL_LIST_SIZE


class _PageScanner(HTMLParser):
    """Relève les liens canonical et les valeurs de data-client-recs-list."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.canonicals: list[str] = []
        self.recs_lists: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if tag == "link" and "canonical" in (attributes.get("rel") or "").split():
            self.canonicals.append(attributes.get("href") or "")
        value = attributes.get("data-client-recs-list")
        if value is not None:
            self.recs_lists.append(value)


def _ranked_items(raw_value: str) -> list[dict] | None:
    """Éléments d'une liste data-client-recs-list, si c'est une liste classée ; sinon None."""
    try:
        items = json.loads(raw_value)
    except json.JSONDecodeError:
        return None
    if not isinstance(items, list):
        return None
    ranked = [
        item for item in items
        if isinstance(item, dict) and RANK_KEY in (item.get("metadataMap") or {})
    ]
    return ranked or None


def validate_bestseller_page(content: bytes, node: str) -> Verdict:
    """Contrôle qu'une page reçue est bien le classement de la catégorie demandée."""
    text = content.decode("utf-8", errors="replace")
    scanner = _PageScanner()
    scanner.feed(text)
    scanner.close()

    problems: list[str] = []
    expected = canonical_url(node)
    canonicals = set(scanner.canonicals)
    if not canonicals:
        problems.append("lien canonical absent")
    elif canonicals != {expected}:
        problems.append(f"canonical inattendu : {', '.join(sorted(canonicals))} (attendu : {expected})")

    ranked_lists = [r for r in map(_ranked_items, scanner.recs_lists) if r is not None]
    rank_count = 0
    if not ranked_lists:
        problems.append(f"aucune liste contenant {RANK_KEY}")
    elif len(ranked_lists) > 1:
        problems.append(f"{len(ranked_lists)} listes contenant {RANK_KEY} (une seule attendue)")
    else:
        rank_count = len(ranked_lists[0])

    if not problems:
        return Verdict(status="ok", reason=None, rank_count=rank_count)
    if "captcha" in text.lower():
        return Verdict(status="blocked", reason="CAPTCHA détecté : " + " ; ".join(problems),
                       rank_count=rank_count)
    return Verdict(status="invalid", reason="Page non conforme : " + " ; ".join(problems),
                   rank_count=rank_count)
