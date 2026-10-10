"""Tests de books.transformer.parsing : analyse pure d'une page de classement (décision 011).

Pages : tests/fixtures/extraction_*.html, générées par tests/fixtures/generer_pages_extraction.py (valeurs inventées).
Les cas d'échec modifient une page générée par un remplacement exact (nombre d'occurrences vérifié).
"""

import dataclasses
from decimal import Decimal

import pytest

from books.collector.validation import validate_bestseller_page
from books.transformer.parsing import EXTRACTOR_VERSION, ParseError, RankingEntry, parse_ranking_page
from conftest import FIXTURES, demande

COMPLETE = "extraction_page1_complete.html"
THIRTY = "extraction_page1_30_cartes.html"
FREE = "extraction_gratuit.html"
# Auteur inventé et reconnaissable des fausses pages (tests/fixtures/generer_pages_extraction.py)
AUTHOR_SENTINEL = "Quentin Sentinelle-Rgpd"
AUTHOR_SENTINEL_ID = "B0SENTINL1"
DETAIL_FIELDS = [f.name for f in dataclasses.fields(RankingEntry) if f.name not in ("rank", "asin", "has_card")]


def read(name: str) -> str:
    return (FIXTURES / name).read_text(encoding="utf-8")


def mutate(name: str, old: str, new: str, count: int = 1) -> bytes:
    """Page modifiée par un remplacement exact : la variante ne doit pas dériver en silence."""
    content = read(name)
    assert content.count(old) == count, f"{old!r} : {content.count(old)} occurrence(s), {count} attendue(s)"
    return content.replace(old, new).encode("utf-8")


def entries(name: str) -> list[RankingEntry]:
    return parse_ranking_page((FIXTURES / name).read_bytes()).entries


def by_rank(name: str) -> dict[int, RankingEntry]:
    return {e.rank: e for e in entries(name)}


def test_version_initiale():
    assert EXTRACTOR_VERSION == "2"  # 2 : noms de la catégorie (décision 014)


@pytest.mark.parametrize("name", [COMPLETE, THIRTY, FREE])
def test_pages_generees_conformes_a_la_validation(name):
    # Les fausses pages de l'extracteur sont des pages valides : elles serviront aussi aux tests d'ingestion
    verdict = validate_bestseller_page((FIXTURES / name).read_bytes(), demande("free" if name == FREE else "paid"))
    assert verdict.status == "ok" and verdict.rank_count == 50


# --- Formes acceptées --------------------------------------------------------------------------

def test_page_complete_une_ligne_par_rang():
    rows = entries(COMPLETE)
    assert [r.rank for r in rows] == list(range(1, 51))
    assert [r.asin for r in rows] == [f"B0FAUX{i:04d}" for i in range(1, 51)]
    assert all(r.has_card for r in rows)


def test_carte_complete():
    assert by_rank(COMPLETE)[1] == RankingEntry(
        rank=1, asin="B0FAUX0001", has_card=True, title="Le Royaume des cendres",
        price_amount=Decimal("4.99"), currency="EUR", rating=Decimal("4.5"), review_count=87,
        cover_url="https://images-eu.ssl-images-amazon.com/images/I/FAUX0001._UX300__OU08__PJku-sticker-v7,"
                  "TopRight,0,-50_AC_UL900_SR900,600_.jpg",
        ku_sticker_hint=True)


def test_prix_et_note_en_decimal_jamais_en_float():
    for row in entries(COMPLETE):
        assert type(row.price_amount) is Decimal
        assert row.rating is None or type(row.rating) is Decimal
    assert by_rank(COMPLETE)[1].price_amount == Decimal("4.99")  # exact, sans arrondi binaire


def test_carte_sans_evaluation():
    row = by_rank(COMPLETE)[2]
    assert row.has_card and row.rating is None and row.review_count is None
    assert row.price_amount == Decimal("2.99") and row.ku_sticker_hint is False


def test_titre_entites_decodees_et_espaces_reduits():
    # « &#39; », « &amp; », « &nbsp; », « &#160; », espaces multiples, en début et en fin
    assert by_rank(COMPLETE)[3].title == "L'Héritière des marées & autres contes"


def test_milliers_et_note_entiere_ecrite_avec_decimale():
    row = by_rank(COMPLETE)[3]
    assert row.review_count == 1234 and row.rating == Decimal("4.0")


def test_prix_au_dela_de_999_et_grands_nombres():
    row = by_rank(COMPLETE)[4]
    assert row.price_amount == Decimal("1234.56") and row.rating == Decimal("5.0") and row.review_count == 123456


def test_espace_insecable_en_caractere_ou_en_entite():
    row = by_rank(COMPLETE)[5]
    assert (row.title, row.price_amount, row.review_count) == ("La Forge d'hiver", Decimal("3.49"), 1002)


def test_une_seule_evaluation_et_couverture_sans_vignette():
    row = by_rank(COMPLETE)[6]
    assert row.review_count == 1 and row.ku_sticker_hint is False
    assert row.cover_url.startswith("https://m.media-amazon.com/")


def test_carte_sans_couverture():
    row = by_rank(COMPLETE)[7]
    assert row.has_card and row.cover_url is None and row.ku_sticker_hint is None


def test_top_gratuit_prix_nuls():
    rows = entries(FREE)
    assert len(rows) == 50
    assert {(r.price_amount, r.currency) for r in rows} == {(Decimal("0.00"), "EUR")}


# --- Carte absente : jamais de champ de détail ---------------------------------------------------

def test_rangs_sans_carte_sans_aucun_champ_de_detail():
    rows = by_rank(THIRTY)
    assert len(rows) == 50
    assert all(rows[r].has_card for r in range(1, 31))
    for r in range(31, 51):
        assert rows[r] == RankingEntry(rank=r, asin=f"B0FAUX{r:04d}", has_card=False)


@pytest.mark.parametrize("name", [COMPLETE, THIRTY, FREE])
def test_invariant_has_card(name):
    # Une ligne sans carte n'a aucun champ de détail (même règle que ranking_entry_no_card_ck)
    for row in entries(name):
        if not row.has_card:
            assert all(getattr(row, f) is None for f in DETAIL_FIELDS), row


# --- RGPD : l'auteur n'est jamais lu --------------------------------------------------------------

def test_auteur_present_dans_les_pages():
    # Sans cela, le test suivant ne prouverait rien
    for name in (COMPLETE, THIRTY, FREE):
        assert AUTHOR_SENTINEL in read(name) and AUTHOR_SENTINEL_ID in read(name)


@pytest.mark.parametrize("name", [COMPLETE, THIRTY, FREE])
def test_auteur_absent_de_tout_champ(name):
    for row in entries(name):
        for value in dataclasses.astuple(row):
            text = str(value)
            assert "Sentinelle" not in text and AUTHOR_SENTINEL_ID not in text, (row.rank, text)


def test_auteur_absent_du_motif_d_echec():
    # Échec sur une carte signée par l'auteur sentinelle (rang 1) : le motif ne le cite pas
    content = mutate(COMPLETE, '<span class="zg-bdg-text">#1</span>', '<span class="zg-bdg-text">#9</span>')
    with pytest.raises(ParseError) as exc:
        parse_ranking_page(content)
    assert "Sentinelle" not in str(exc.value) and AUTHOR_SENTINEL_ID not in str(exc.value)


# --- Formes refusées : liste d'autorisation ------------------------------------------------------

REFUSALS = [
    # (identifiant, ancien texte, nouveau texte, motif attendu)
    ("prix-espace-ordinaire", "4,99&nbsp;€", "4,99 €", "rang 1 : prix de forme inconnue"),
    ("prix-espace-fine", "4,99&nbsp;€", "4,99 €", "rang 1 : prix de forme inconnue"),
    ("prix-point-decimal", "4,99&nbsp;€", "4.99&nbsp;€", "rang 1 : prix de forme inconnue"),
    ("prix-sans-centimes", "4,99&nbsp;€", "4&nbsp;€", "rang 1 : prix de forme inconnue"),
    ("prix-milliers-non-groupes", "1&nbsp;234,56&nbsp;€", "1234,56&nbsp;€", "rang 4 : prix de forme inconnue"),
    ("devise-dollar", "4,99&nbsp;€", "4,99&nbsp;$", "rang 1 : devise non autorisée '$'"),
    ("devise-en-lettres", "4,99&nbsp;€", "4,99&nbsp;EUR", "rang 1 : devise non autorisée 'EUR'"),
    ("note-sans-decimale", ">4,5 sur 5&nbsp;étoiles<", ">4 sur 5&nbsp;étoiles<", "rang 1 : note de forme inconnue"),
    ("note-sur-10", ">4,5 sur 5&nbsp;étoiles<", ">4,5 sur 10&nbsp;étoiles<", "rang 1 : note de forme inconnue"),
    ("note-espace-ordinaire", ">4,5 sur 5&nbsp;étoiles<", ">4,5 sur 5 étoiles<", "rang 1 : note de forme inconnue"),
    ("note-superieure-a-5", ">5,0 sur 5&nbsp;étoiles<", ">5,5 sur 5&nbsp;étoiles<", "rang 4 : note supérieure à 5"),
    ("evaluations-differentes", '<span aria-hidden="true" class="a-size-small">87</span>',
     '<span aria-hidden="true" class="a-size-small">88</span>', "rang 1 : note ou nombre d'évaluations différent"),
    ("note-differente", 'aria-label="4,5 sur 5', 'aria-label="4,6 sur 5', "rang 1 : note ou nombre d'évaluations différent"),
    ("evaluations-virgule", ">1&nbsp;234</span>", ">1,234</span>", "rang 3 : nombre d'évaluations de forme inconnue"),
    ("evaluation-au-singulier", "3,0 sur 5&nbsp;étoiles, 1&nbsp;évaluations", "3,0 sur 5&nbsp;étoiles, 1&nbsp;évaluation",
     "rang 6 : aria-label des étoiles de forme inconnue"),
    ("note-sans-lien", 'aria-label="4,5 sur 5&nbsp;étoiles, 87&nbsp;évaluations"', 'data-x="1"',
     "rang 1 : note et nombre d'évaluations non affichés ensemble"),
    ("badge-different", '<span class="zg-bdg-text">#2</span>', '<span class="zg-bdg-text">#20</span>',
     "rang 2 : badge '#20' différent du rang de la liste"),
    ("carte-hors-liste", 'data-asin="B0FAUX0002"', 'data-asin="B0FAUX0999"',
     "carte dont l'ASIN est absent de la liste classée : B0FAUX0999"),
    ("carte-sans-asin", 'data-asin="B0FAUX0002"', 'data-x="B0FAUX0002"', "carte détaillée sans ASIN"),
    ("couverture-reecrite", 'src="https://images-eu.ssl-images-amazon.com/images/I/FAUX0001.',
     'src="./page_files/FAUX0001.', "rang 1 : adresse de couverture inattendue"),
    ("titre-vide", '<div class="_cDEzb_p13n-sc-css-line-clamp-1_1Fn1y">Ombres sur Valmeraude</div>',
     '<div class="_cDEzb_p13n-sc-css-line-clamp-1_1Fn1y"> &nbsp; </div>', "rang 2 : titre vide"),
]


@pytest.mark.parametrize("old, new, motif", [r[1:] for r in REFUSALS], ids=[r[0] for r in REFUSALS])
def test_forme_refusee_page_entiere_en_echec(old, new, motif):
    with pytest.raises(ParseError, match=None) as exc:
        parse_ranking_page(mutate(COMPLETE, old, new))
    assert motif in str(exc.value)
    assert "Sentinelle" not in str(exc.value) and AUTHOR_SENTINEL_ID not in str(exc.value)


def test_carte_en_double():
    content = read(COMPLETE)
    start = content.index('<li class="zg-no-numbers"><span class="a-list-item"><div id="gridItemRoot"')
    end = content.index("</li>\n", start) + len("</li>\n")
    doubled = content[:end] + content[start:end] + content[end:]
    with pytest.raises(ParseError, match="carte en double pour le rang 1"):
        parse_ranking_page(doubled.encode("utf-8"))


@pytest.mark.parametrize("old, new, motif", [
    ("&quot;render.zg.rank&quot;:&quot;", "&quot;autre&quot;:&quot;", "0 liste(s) classée(s)"),
    ("&quot;render.zg.rank&quot;:&quot;2&quot;", "&quot;render.zg.rank&quot;:&quot;1&quot;",
     "rang en double dans la liste classée (ex. : 1)"),
    ("&quot;id&quot;:&quot;B0FAUX0002&quot;", "&quot;id&quot;:&quot;B0FAUX0001&quot;",
     "ASIN en double dans la liste classée (ex. : B0FAUX0001)"),
    ("&quot;id&quot;:&quot;B0FAUX0002&quot;", "&quot;id&quot;:&quot;b0faux0002&quot;", "ASIN illisible au rang 2"),
], ids=["sans-liste", "rang-double", "asin-double", "asin-illisible"])
def test_liste_classee_illisible(old, new, motif):
    count = 50 if old == "&quot;render.zg.rank&quot;:&quot;" else 1
    with pytest.raises(ParseError) as exc:
        parse_ranking_page(mutate(COMPLETE, old, new, count))
    assert motif in str(exc.value)


def test_deux_listes_classees():
    content = read(COMPLETE)
    start = content.index('data-client-recs-list="')
    end = content.index('"', start + len('data-client-recs-list="'))
    second = f'<div {content[start:end + 1]}></div>'
    with pytest.raises(ParseError, match="2 liste"):
        parse_ranking_page(content.replace("</body>", second + "</body>").encode("utf-8"))


def test_contenu_qui_n_est_pas_utf8():
    with pytest.raises(ParseError, match="UTF-8"):
        parse_ranking_page(read(COMPLETE).encode("utf-8") + b"\xff")


def _request_for(name: str):
    """Demande correspondant à une fausse page, d'après son nom."""
    if "gratuit" in name:
        return demande("free")
    if "page2" in name:
        return demande("paid", 2)
    return demande()


# Fausses pages de classement conformes à la validation ; les autres variantes sont non conformes par construction
VALID_PAGES = {
    "bestsellers_exemple.html", "bestsellers_titre_captcha.html", "bestsellers_gratuit.html", "bestsellers_page2.html",
    "bestsellers_sans_pagination.html", "bestsellers_rang_trou.html", "bestsellers_liste_courte.html",
    "bestsellers_page1_complete.html", "bestsellers_page1_complete_sans_pagination.html",
    COMPLETE, THIRTY, FREE,
}


def test_toutes_les_fausses_pages_conformes_passent_l_extracteur():
    pages = sorted(p.name for p in FIXTURES.glob("*.html"))
    valid = {name for name in pages
             if validate_bestseller_page((FIXTURES / name).read_bytes(), _request_for(name)).status == "ok"}
    assert valid == VALID_PAGES  # une dérive des fausses pages se voit ici
    for name in sorted(valid):
        rows = parse_ranking_page((FIXTURES / name).read_bytes()).entries  # aucune ParseError
        assert rows, name
        for row in rows:
            if not row.has_card:
                assert all(getattr(row, f) is None for f in DETAIL_FIELDS), (name, row)


# --- Noms de la catégorie (décision 014, section 3) : jamais un échec de page ---------------------

H1 = '<h1 class="a-size-large a-spacing-medium a-text-bold"> Les meilleures ventes en Catégorie d\'exemple - ebooks</h1>'
SELECTED = ('<span class="_p13n-zg-nav-tree-all_style_zg-selected__1SfhQ" aria-current="page">Catégorie d\'exemple'
            '<span class="_p13n-zg-nav-tree-all_style_zg-visually-hidden__2zReM">(Current)</span></span>')


def names(content: bytes) -> tuple[str | None, str | None]:
    page = parse_ranking_page(content)
    assert len(page.entries) == 50  # les lignes sont toujours extraites, quels que soient les noms
    return page.display_name, page.short_name


def test_noms_de_la_categorie_lus():
    # Nom d'affichage tel qu'affiché, suffixe compris ; nom court sans le texte caché « (Current) »
    assert names((FIXTURES / COMPLETE).read_bytes()) == ("Catégorie d'exemple - ebooks", "Catégorie d'exemple")


@pytest.mark.parametrize("name", [COMPLETE, THIRTY, FREE])
def test_noms_lus_sur_toutes_les_pages_generees(name):
    page = parse_ranking_page((FIXTURES / name).read_bytes())
    assert page.display_name and page.short_name and "Current" not in page.short_name


def test_noms_nettoyes_comme_le_titre():
    content = mutate(COMPLETE, H1, H1.replace("en Catégorie d'exemple - ebooks",
                                              "en  Catégorie&nbsp;d&#39;exemple   - ebooks "))
    assert names(content)[0] == "Catégorie d'exemple - ebooks"


@pytest.mark.parametrize("old, new, expected", [
    (H1, "", (None, "Catégorie d'exemple")),                                          # <h1> de la catégorie absent
    (H1, H1.replace("Les meilleures ventes en", "Meilleures ventes :"), (None, "Catégorie d'exemple")),  # préfixe
    (H1, H1 + H1, (None, "Catégorie d'exemple")),                                     # deux <h1> candidats
    (H1, H1.replace("en Catégorie d'exemple - ebooks", "en "), (None, "Catégorie d'exemple")),  # nom vide
    (SELECTED, SELECTED.replace(' aria-current="page"', ""), ("Catégorie d'exemple - ebooks", None)),  # absent
    (SELECTED, SELECTED + SELECTED, ("Catégorie d'exemple - ebooks", None)),         # deux éléments sélectionnés
], ids=["h1-absent", "prefixe-change", "deux-h1", "nom-vide", "selection-absente", "deux-selections"])
def test_nom_illisible_vaut_none_jamais_un_echec(old, new, expected):
    assert names(mutate(COMPLETE, old, new)) == expected


def test_onglet_actif_jamais_pris_pour_la_categorie():
    # Sans élément sélectionné dans l'arborescence, le seul span aria-current="page" restant est l'onglet actif,
    # dans la rangée d'onglets : il n'est jamais lu comme nom de catégorie
    short = names(mutate(COMPLETE, SELECTED, SELECTED.replace(' aria-current="page"', "")))[1]
    assert short is None


def test_noms_absents_lignes_extraites():
    page = parse_ranking_page(mutate(COMPLETE, H1, "").replace(
        SELECTED.encode(), SELECTED.replace(' aria-current="page"', "").encode()))
    assert (page.display_name, page.short_name) == (None, None) and len(page.entries) == 50
