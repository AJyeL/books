"""Génère les fausses pages de l'extracteur (décision 011), à partir de bestsellers_exemple.html (valeurs inventées).

Les cartes reprennent la structure des cartes réelles et les formes de l'inventaire du 8 octobre 2026 ; comme dans
les captures, l'espace insécable est écrit « &nbsp; ». Un auteur inventé et reconnaissable, AUTHOR_SENTINEL, signe
plusieurs cartes : le test RGPD vérifie qu'il n'apparaît dans aucun résultat de l'extracteur.

Relancer depuis la racine du dépôt après toute modification :
    python tests/fixtures/generer_pages_extraction.py
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))  # generer_variantes.py, à côté de ce script, même en mode isolé (python -I)

from generer_variantes import (  # noqa: E402
    BASE, MARK, PAGE1_SELECTED, PAGE2_NORMAL, TAB_FREE_LINK, TAB_PAID_ACTIVE, recs_list, replace,
)
AUTHOR_SENTINEL = "Quentin Sentinelle-Rgpd"
AUTHOR_SENTINEL_ID = "B0SENTINL1"
COVER_KU = "https://images-eu.ssl-images-amazon.com/images/I/FAUX{n:04d}._UX300__OU08__PJku-sticker-v7,TopRight,0,-50_AC_UL900_SR900,600_.jpg"
COVER_PLAIN = "https://m.media-amazon.com/images/I/FAUX{n:04d}._AC_UL900_SR900,600_.jpg"


def card(rank: int, *, title: str, price: str, rating: tuple[str, str, str] | None,
         cover: str | None, author: str = "Camille Exemple", author_id: str = "B0AUTEUR01") -> str:
    """Carte détaillée (HTML) ; rating = (note de l'icône, note de l'aria-label, nombre d'évaluations)."""
    asin = f"B0FAUX{rank:04d}"
    link = f"/Titre-{rank}/dp/{asin}/ref=zg_bs_g_10000000001_d_sccl_{rank}/123-1234567-1234567"
    image = (f'<a aria-hidden="true" class="a-link-normal aok-block" tabindex="-1" href="{link}">'
             f'<div class="a-section a-spacing-mini _cDEzb_noop_3Xbw5"><img alt="Titre {rank}" src="{cover}" '
             f'class="a-dynamic-image p13n-sc-dynamic-image p13n-product-image" height="300" data-a-dynamic-image="{{}}">'
             f'</div></a>') if cover else ""
    stars = ""
    if rating:
        icon, label, count = rating
        stars = (f'<div class="a-row"><div class="a-icon-row"><a aria-label="{label} sur 5&nbsp;étoiles, {count}&nbsp;évaluations" '
                 f'class="a-link-normal" href="/product-reviews/{asin}/ref=zg_bs_g_10000000001_d_sccl_{rank}">'
                 f'<i aria-hidden="true" class="a-icon a-icon-star-small a-star-small-4-5 aok-align-top">'
                 f'<span class="a-icon-alt">{icon} sur 5&nbsp;étoiles</span></i>'
                 f'<span aria-hidden="true" class="a-size-small">{count}</span></a></div></div>')
    return (
        f'<li class="zg-no-numbers"><span class="a-list-item"><div id="gridItemRoot" class="a-column a-span12 a-text-center _cDEzb_grid-column_2hIsc">'
        f'<div id="{asin}" class="a-cardui _cDEzb_grid-cell_1uMOS expandableGrid p13n-grid-content" data-a-card-type="basic">'
        f'<div data-asin="{asin}" class="_cDEzb_iveVideoWrapper_JJ34T">'
        f'<div class="a-section zg-bdg-ctr"><div class="a-section zg-bdg-body zg-bdg-clr-body aok-float-left">'
        f'<span class="zg-bdg-text">#{rank}</span></div></div>'
        f'<div class="zg-grid-general-faceout"><span><div id="p13n-asin-index-{rank - 1}" class="p13n-sc-uncoverable-faceout">{image}'
        f'<div><div><a class="a-link-normal aok-block" href="{link}" role="link"><span>'
        f'<div class="_cDEzb_p13n-sc-css-line-clamp-1_1Fn1y">{title}</div></span></a>'
        f'<div class="a-row a-size-small"><a class="a-size-small a-link-child" href="/{author.replace(" ", "-")}/e/{author_id}/ref=zg_bs_g_10000000001_d_sccl_{rank}">'
        f'<div class="_cDEzb_p13n-sc-css-line-clamp-1_1Fn1y">{author}</div></a></div>{stars}'
        f'<div class="a-row a-size-small"><span class="a-size-small a-color-secondary a-text-normal">Format Kindle</span></div>'
        f'<div class="a-row"><div class="a-row"><div class="_cDEzb_p13n-sc-price-animation-wrapper_3PzN2">'
        f'<a class="a-link-normal aok-block a-text-normal" href="{link}" role="link"><div class="a-row">'
        f'<span class="a-size-base a-color-price"><span class="_cDEzb_p13n-sc-price_3mJ9Z">{price}</span></span></div></a>'
        f'</div></div></div></div></div></div></span></div></div></div></div></span></li>\n'
    )


def particular_cards() -> dict[int, str]:
    """Cartes 1 à 7 : chacune illustre une forme acceptée."""
    return {
        # Complète ; auteur sentinelle ; vignette ku-sticker
        1: card(1, title="Le Royaume des cendres", price="4,99&nbsp;€", rating=("4,5", "4,5", "87"),
                cover=COVER_KU.format(n=1), author=AUTHOR_SENTINEL, author_id=AUTHOR_SENTINEL_ID),
        # Sans évaluation affichée
        2: card(2, title="Ombres sur Valmeraude", price="2,99&nbsp;€", rating=None, cover=COVER_PLAIN.format(n=2)),
        # Titre : entités HTML, espaces multiples et insécables ; milliers ; note entière écrite avec décimale
        3: card(3, title="  L&#39;Héritière&nbsp;des   marées &amp; autres&#160;contes ", price="12,99&nbsp;€",
                rating=("4,0", "4,0", "1&nbsp;234"), cover=COVER_KU.format(n=3),
                author=AUTHOR_SENTINEL, author_id=AUTHOR_SENTINEL_ID),
        # Prix au-delà de 999 € (groupes de trois chiffres) ; note maximale ; centaines de milliers d'évaluations
        4: card(4, title="Grand Atlas des royaumes", price="1&nbsp;234,56&nbsp;€", rating=("5,0", "5,0", "123&nbsp;456"),
                cover=COVER_KU.format(n=4)),
        # Espaces insécables écrits comme caractères (U+00A0), et non comme entités : même résultat
        5: card(5, title="La Forge d'hiver", price="3,49 €", rating=("4,1", "4,1", "1 002"),
                cover=COVER_KU.format(n=5), author=AUTHOR_SENTINEL, author_id=AUTHOR_SENTINEL_ID),
        # Une seule évaluation (le libellé reste au pluriel, comme dans toutes les pages observées)
        6: card(6, title="Premier envol", price="0,99&nbsp;€", rating=("3,0", "3,0", "1"), cover=COVER_PLAIN.format(n=6)),
        # Sans couverture
        7: card(7, title="Sans visage", price="5,99&nbsp;€", rating=("4,2", "4,2", "15"), cover=None),
    }


def generic_card(rank: int, price: str) -> str:
    return card(rank, title=f"Titre inventé numéro {rank}", price=price, rating=("4,3", "4,3", str(rank)),
                cover=COVER_KU.format(n=rank), author=AUTHOR_SENTINEL if rank % 10 == 0 else "Lou Fictif",
                author_id=AUTHOR_SENTINEL_ID if rank % 10 == 0 else "B0AUTEUR02")


def page(card_count: int, free: bool = False) -> str:
    """Page de 50 rangs (1 à 50) dont les `card_count` premiers ont une carte détaillée."""
    head, _, rest = BASE.partition('<div class="p13n-desktop-grid"')
    _, _, tail = rest.partition('<div role="listitem" aria-hidden="true"><div id="videoResponsePlaceholder">')
    special = particular_cards()
    cards = []
    for rank in range(1, card_count + 1):
        if free:
            cards.append(generic_card(rank, "0,00&nbsp;€"))
        else:
            # Prix génériques de 6 à 9 €, centimes = rang : distincts des prix des cartes 1 à 7
            cards.append(special.get(rank) or generic_card(rank, f"{rank % 4 + 6},{rank:02d}&nbsp;€"))
    s = (head + f'<div class="p13n-desktop-grid" data-client-recs-list="{recs_list(50)}" data-index-offset="30" '
         f'data-reftag="zg_bs_g_10000000001" data-offset="50" data-faceoutkataname="GeneralFaceout">'
         f'<ol class="a-ordered-list a-vertical p13n-gridRow _cDEzb_grid-row_3Cywl">\n' + "".join(cards)
         + '<div role="listitem" aria-hidden="true"><div id="videoResponsePlaceholder">' + tail)
    assert PAGE1_SELECTED in s and PAGE2_NORMAL in s  # page 1 annonçant une page 2 : conforme à la validation
    if free:
        s = replace(s, TAB_PAID_ACTIVE,
                    '<a class="a-link-normal" href="/gp/bestsellers/digital-text/10000000001/ref=zg_bs">Top 100 payants</a>')
        s = replace(s, TAB_FREE_LINK,
                    '<span aria-current="page" class="a-size-medium a-color-base _cDEzb_fst_2megA">Top 100 gratuits</span>')
    return s


PAGES = {
    "extraction_page1_complete.html": ("Top payant p1, 50 rangs, 50 cartes (formes acceptées aux rangs 1 à 7)", 50, False),
    "extraction_page1_30_cartes.html": ("Top payant p1, 50 rangs, 30 cartes (capture sans défilement)", 30, False),
    "extraction_gratuit.html": ("Top gratuit p1, 50 rangs, 50 cartes à 0,00 €", 50, True),
}


def main() -> None:
    for name, (description, count, free) in PAGES.items():
        content = replace(page(count, free), MARK,
                          f"<!-- Fausse page de test B.O.O.K.S. (extracteur : {description}) :")
        (HERE / name).write_text(content, encoding="utf-8", newline="\n")
        print(f"{name} : {description}")


if __name__ == "__main__":
    main()
