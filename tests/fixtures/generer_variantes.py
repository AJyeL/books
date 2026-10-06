"""Génère les variantes de bestsellers_exemple.html (valeurs inventées).

Chaque variante ne diffère de l'exemple que par le point testé. Après toute modification
de l'exemple, relancer depuis la racine du dépôt :
    python tests/fixtures/generer_variantes.py
La page CAPTCHA (bestsellers_captcha.html) est écrite à la main et n'est pas générée ici.
"""

import json
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASE = (HERE / "bestsellers_exemple.html").read_text(encoding="utf-8")
MARK = "<!-- Fausse page de test B.O.O.K.S. :"


def replace(s: str, old: str, new: str, count: int = 1) -> str:
    """Remplace exactement `count` occurrences, sinon s'arrête : une variante ne doit pas dériver en silence."""
    found = s.count(old)
    if found != count:
        raise SystemExit(f"{old[:60]!r} : {found} occurrence(s), {count} attendue(s)")
    return s.replace(old, new)


def set_ranks(s: str, ranks: list[int]) -> str:
    """Remplace les rangs render.zg.rank de la liste classée, dans l'ordre des éléments."""
    found = re.findall(r"&quot;render\.zg\.rank&quot;:&quot;\d+&quot;", s)
    if len(found) != len(ranks):
        raise SystemExit(f"{len(found)} rangs trouvés, {len(ranks)} fournis")
    it = iter(ranks)
    return re.sub(r"(&quot;render\.zg\.rank&quot;:&quot;)\d+(&quot;)", lambda m: f"{m.group(1)}{next(it)}{m.group(2)}", s)


def recs_list(count: int) -> str:
    """Valeur échappée de data-client-recs-list pour `count` livres inventés, rangs 1 à count."""
    items = [{"id": f"B0FAUX{i:04d}",
              "metadataMap": {"render.zg.rank": str(i),
                              "render.zg.bsms.currentSalesRank": "",
                              "render.zg.bsms.percentageChange": "",
                              "render.zg.bsms.twentyFourHourOldSalesRank": "",
                              "disablePercolateLinkParams": "true"},
              "linkParameters": {}} for i in range(1, count + 1)]
    return json.dumps(items, ensure_ascii=False, separators=(",", ":")).replace('"', "&quot;")


NAV_START = '<nav aria-label="pagination"'
NAV_END = "</ul></nav>\n"


def without_pagination(s: str) -> str:
    start = s.index(NAV_START)
    end = s.index(NAV_END, start) + len(NAV_END)
    return s[:start] + s[end:]


TAB_PAID_ACTIVE = '<span aria-current="page" class="a-size-medium a-color-base _cDEzb_fst_2megA">Top 100 payants</span>'
TAB_FREE_LINK = ('<a class="a-link-normal" href="/gp/bestsellers/digital-text/10000000001/ref=zg_bs?ie=UTF8&amp;tf=1">'
                 'Top 100 gratuits</a>')
PAGE1_SELECTED = ('<li aria-label="Page 1" class="a-selected"><a href="/gp/bestsellers/digital-text/10000000001/'
                  'ref=zg_bs_pg_1_digital-text?ie=UTF8&amp;pg=1" aria-current="page">1</a></li>')
PAGE2_NORMAL = ('<li aria-label="Page 2" class="a-normal"><a href="/gp/bestsellers/digital-text/10000000001/'
                'ref=zg_bs_pg_2_digital-text?ie=UTF8&amp;pg=2">2</a></li>')


def variants() -> dict[str, tuple[str, str]]:
    """Nom de fichier -> (description, contenu)."""
    v: dict[str, tuple[str, str]] = {}

    s = re.sub(r"&quot;render\.zg\.rank&quot;:&quot;\d+&quot;,", "", BASE)
    v["bestsellers_sans_rang.html"] = ("liste sans render.zg.rank", s)

    s = replace(BASE, 'canonical" href="https://www.amazon.fr/gp/bestsellers/digital-text/10000000001"',
                'canonical" href="https://www.amazon.fr/gp/bestsellers/digital-text/10000000002"')
    v["bestsellers_autre_categorie.html"] = ("canonical d'une autre catégorie", s)

    s = replace(BASE, "Ombres sur Valmeraude", "Le Captcha du dragon", 2)
    s = replace(s, "Ombres-sur-Valmeraude", "Le-Captcha-du-dragon", 3)
    v["bestsellers_titre_captcha.html"] = ("page valide, mot captcha dans un titre", s)

    # Onglet actif « Top 100 gratuits » ; prix inchangés (non nuls) : ils ne servent pas d'indice
    s = replace(BASE, TAB_PAID_ACTIVE,
                '<a class="a-link-normal" href="/gp/bestsellers/digital-text/10000000001/ref=zg_bs">Top 100 payants</a>')
    s = replace(s, TAB_FREE_LINK,
                '<span aria-current="page" class="a-size-medium a-color-base _cDEzb_fst_2megA">Top 100 gratuits</span>')
    v["bestsellers_gratuit.html"] = ("Top gratuit, page 1 ; prix non nuls laissés exprès", s)

    s = replace(BASE, TAB_PAID_ACTIVE, TAB_PAID_ACTIVE.replace(' aria-current="page"', ""))
    v["bestsellers_sans_onglet.html"] = ("aucun onglet actif dans la rangée d'onglets", s)

    v["bestsellers_sans_pagination.html"] = ("aucun bloc de pagination", without_pagination(BASE))

    # Page 2 : rangs 51 à 55, badges #51 à #53, pagination « Page 2 » active
    s = set_ranks(BASE, [51, 52, 53, 54, 55])
    for i in (1, 2, 3):
        s = replace(s, f'<span class="zg-bdg-text">#{i}</span>', f'<span class="zg-bdg-text">#{50 + i}</span>')
    s = replace(s, PAGE1_SELECTED, PAGE1_SELECTED.replace('class="a-selected"', 'class="a-normal"')
                .replace(' aria-current="page"', ""))
    s = replace(s, PAGE2_NORMAL, PAGE2_NORMAL.replace('class="a-normal"', 'class="a-selected"')
                .replace('pg=2">', 'pg=2" aria-current="page">'))
    v["bestsellers_page2.html"] = ("Top payant, page 2 (rangs 51 à 55)", s)

    v["bestsellers_rang_decale.html"] = ("premier rang 2 au lieu de 1", set_ranks(BASE, [2, 3, 4, 5, 6]))
    v["bestsellers_rang_hors_plage.html"] = ("un rang hors de la plage de la page 1",
                                             set_ranks(BASE, [1, 2, 3, 4, 51]))
    v["bestsellers_rang_trou.html"] = ("trou dans la suite des rangs (1, 2, 3, 4, 7)",
                                       set_ranks(BASE, [1, 2, 3, 4, 7]))

    # Liste courte réaliste : 45 livres classés, donc pas de page 2 ni de pagination
    s = re.sub(r'data-client-recs-list="[^"]*"', lambda m: f'data-client-recs-list="{recs_list(45)}"', BASE)
    s = replace(s, 'data-offset="5"', 'data-offset="45"')
    v["bestsellers_liste_courte.html"] = ("liste courte de 45 rangs, sans pagination", without_pagination(s))

    # Liste complète : 50 rangs. Avec pagination annonçant la page 2, les deux signaux concordent ;
    # sans pagination, ils divergent (la page 2 ne doit pas être demandée).
    s = re.sub(r'data-client-recs-list="[^"]*"', lambda m: f'data-client-recs-list="{recs_list(50)}"', BASE)
    s = replace(s, 'data-offset="5"', 'data-offset="50"')
    v["bestsellers_page1_complete.html"] = ("page 1 de 50 rangs, pagination annonçant la page 2", s)
    v["bestsellers_page1_complete_sans_pagination.html"] = (
        "page 1 de 50 rangs sans pagination (signaux divergents)", without_pagination(s))
    return v


def main() -> None:
    for name, (description, content) in variants().items():
        content = replace(content, MARK, f"<!-- Fausse page de test B.O.O.K.S. (variante : {description}) :")
        (HERE / name).write_text(content, encoding="utf-8", newline="\n")
        print(f"{name} : {description}")


if __name__ == "__main__":
    main()
