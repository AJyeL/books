"""Liste classée d'une page de classement : définition unique, commune à la validation et à l'extracteur
(décisions 010 et 011).

La liste classée est la valeur d'un attribut data-client-recs-list : un tableau JSON dont les éléments classés
portent la clé render.zg.rank dans un objet metadataMap. Elle n'est jamais repérée par la classe de l'élément
qui la porte. Une page doit en contenir exactement une : ce contrôle appartient à la validation.
"""

import json
import re

RANK_KEY = "render.zg.rank"


def ranked_items(raw_value: str) -> list[dict] | None:
    """Éléments d'une liste data-client-recs-list, si c'est une liste classée ; sinon None."""
    try:
        items = json.loads(raw_value)
    except json.JSONDecodeError:
        return None
    if not isinstance(items, list):
        return None
    # metadataMap qui n'est pas un objet JSON (nombre, booléen, liste, texte) : pas de rang, jamais un plantage ;
    # « in » lèverait TypeError sur un nombre, et chercherait une sous-chaîne dans un texte
    ranked = [
        item for item in items
        if isinstance(item, dict) and isinstance(item.get("metadataMap"), dict) and RANK_KEY in item["metadataMap"]
    ]
    return ranked or None


def rank_value(value: object) -> int | None:
    """Rang lu : entier JSON ou texte de chiffres ; None sinon. Un booléen n'est jamais un rang (int(True) vaut 1),
    un décimal non plus (int(3.7) vaudrait 3)."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str) and re.fullmatch(r"[0-9]+", value):
        return int(value)
    return None
