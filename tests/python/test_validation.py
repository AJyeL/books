"""Tests de books.collector.validation, sur les fausses pages de tests/fixtures/.

Triangulation (décision 004) : canonical, onglet actif, pagination et rangs doivent concorder
avec la demande. Un indice introuvable rend la page non conforme.
"""

import pytest

from books.collector.validation import validate_bestseller_page
from conftest import demande


def verdict(fixture_page, name, request=None):
    return validate_bestseller_page(fixture_page(name), request or demande())


# --- Pages conformes ---------------------------------------------------------

def test_page_valide(fixture_page):
    v = verdict(fixture_page, "bestsellers_exemple.html")
    assert v.status == "ok"
    assert v.reason is None
    assert v.rank_count == 5
    assert v.short_list  # 5 rangs sur 50 : information, pas une erreur
    assert v.notes == ()


def test_arborescence_jamais_prise_pour_l_onglet(fixture_page):
    # L'exemple contient aussi un span aria-current="page" dans l'arborescence des catégories
    page = fixture_page("bestsellers_exemple.html")
    assert page.count(b'<span class="_p13n-zg-nav-tree-all_style_zg-selected__1SfhQ" aria-current="page">') == 1
    assert validate_bestseller_page(page, demande()).status == "ok"


def test_mot_captcha_dans_un_titre_page_valide(fixture_page):
    # La structure décide : le mot « captcha » ne suffit pas à rejeter une page conforme
    v = verdict(fixture_page, "bestsellers_titre_captcha.html")
    assert v.status == "ok"
    assert v.rank_count == 5


def test_top_gratuit_pour_une_demande_gratuite(fixture_page):
    # Prix non nuls dans cette fixture : ils ne servent pas d'indice
    assert verdict(fixture_page, "bestsellers_gratuit.html", demande("free")).status == "ok"


def test_page_2_pour_une_demande_de_page_2(fixture_page):
    v = verdict(fixture_page, "bestsellers_page2.html", demande("paid", 2))
    assert v.status == "ok"
    assert v.rank_count == 5


def test_sans_pagination_pour_une_demande_de_page_1(fixture_page):
    assert verdict(fixture_page, "bestsellers_sans_pagination.html").status == "ok"


def test_liste_courte_de_45_rangs_en_page_1(fixture_page):
    v = verdict(fixture_page, "bestsellers_liste_courte.html")
    assert v.status == "ok"
    assert v.rank_count == 45
    assert v.short_list
    assert v.notes == ()


def test_trou_dans_les_rangs_seulement_signale(fixture_page):
    v = verdict(fixture_page, "bestsellers_rang_trou.html")
    assert v.status == "ok"
    assert len(v.notes) == 1
    assert "non continue" in v.notes[0]


def test_doublon_de_rang_seulement_signale(fixture_page):
    page = fixture_page("bestsellers_exemple.html").replace(
        b"&quot;render.zg.rank&quot;:&quot;5&quot;", b"&quot;render.zg.rank&quot;:&quot;4&quot;", 1)
    v = validate_bestseller_page(page, demande())
    assert v.status == "ok"
    assert "non continue" in v.notes[0]


# --- Type de liste (onglet actif) -------------------------------------------

def test_page_payante_recue_pour_une_demande_gratuite(fixture_page):
    v = verdict(fixture_page, "bestsellers_exemple.html", demande("free"))
    assert v.status == "invalid"
    assert "onglet actif 'Top 100 payants' (paid), liste demandée : free" in v.reason


def test_page_gratuite_recue_pour_une_demande_payante(fixture_page):
    v = verdict(fixture_page, "bestsellers_gratuit.html", demande("paid"))
    assert v.status == "invalid"
    assert "onglet actif 'Top 100 gratuits' (free)" in v.reason


def test_page_sans_onglet_actif(fixture_page):
    # Aucun type supposé par défaut, même si tout le reste est conforme
    v = verdict(fixture_page, "bestsellers_sans_onglet.html")
    assert v.status == "invalid"
    assert "onglet actif introuvable" in v.reason


def test_onglet_actif_inconnu(fixture_page):
    page = fixture_page("bestsellers_exemple.html").replace(b">Top 100 payants</span>", b">Top 100 inconnus</span>", 1)
    v = validate_bestseller_page(page, demande())
    assert v.status == "invalid"
    assert "onglet actif inconnu" in v.reason


def test_deux_onglets_actifs(fixture_page):
    page = fixture_page("bestsellers_exemple.html").replace(
        b'<a class="a-link-normal" href="/gp/bestsellers/digital-text/10000000001/ref=zg_bs?ie=UTF8&amp;tf=1">'
        b"Top 100 gratuits</a>",
        b'<span aria-current="page">Top 100 gratuits</span>', 1)
    v = validate_bestseller_page(page, demande())
    assert v.status == "invalid"
    assert "2 onglets actifs" in v.reason


# --- Numéro de page (pagination) --------------------------------------------

def test_page_2_recue_pour_une_demande_de_page_1(fixture_page):
    v = verdict(fixture_page, "bestsellers_page2.html", demande("paid", 1))
    assert v.status == "invalid"
    assert "page active 2, page demandée : 1" in v.reason


def test_page_1_recue_pour_une_demande_de_page_2(fixture_page):
    v = verdict(fixture_page, "bestsellers_exemple.html", demande("paid", 2))
    assert v.status == "invalid"
    assert "page active 1, page demandée : 2" in v.reason


def test_page_sans_pagination_demandee_en_page_2(fixture_page):
    v = verdict(fixture_page, "bestsellers_sans_pagination.html", demande("paid", 2))
    assert v.status == "invalid"
    assert "pagination absente, page demandée : 2" in v.reason


def test_pagination_sans_page_active(fixture_page):
    page = fixture_page("bestsellers_exemple.html").replace(
        b'<li aria-label="Page 1" class="a-selected">', b'<li aria-label="Page 1" class="a-normal">', 1)
    v = validate_bestseller_page(page, demande())
    assert v.status == "invalid"
    assert "sans page active unique" in v.reason


# --- Rangs (indice indépendant de l'interface) ------------------------------

def test_premier_rang_decale(fixture_page):
    v = verdict(fixture_page, "bestsellers_rang_decale.html")
    assert v.status == "invalid"
    assert "premier rang 2, attendu 1" in v.reason


def test_rang_hors_de_la_plage(fixture_page):
    v = verdict(fixture_page, "bestsellers_rang_hors_plage.html")
    assert v.status == "invalid"
    assert "hors de la plage 1-50" in v.reason
    assert "premier rang" not in v.reason  # le premier rang, lui, est correct


def test_rangs_de_page_2_seuls_contredisent_la_demande(fixture_page):
    # Onglet et pagination conformes, seuls les rangs sont ceux d'une page 2 : l'indice des rangs suffit
    page = fixture_page("bestsellers_page2.html")
    page = page.replace(b'<li aria-label="Page 1" class="a-normal">', b'<li aria-label="Page 1" class="a-selected">', 1)
    page = page.replace(b'<li aria-label="Page 2" class="a-selected">', b'<li aria-label="Page 2" class="a-normal">', 1)
    v = validate_bestseller_page(page, demande("paid", 1))
    assert v.status == "invalid"
    assert "premier rang 51, attendu 1" in v.reason
    assert "page active" not in v.reason


def test_rang_non_numerique(fixture_page):
    page = fixture_page("bestsellers_exemple.html").replace(
        b"&quot;render.zg.rank&quot;:&quot;3&quot;", b"&quot;render.zg.rank&quot;:&quot;trois&quot;", 1)
    v = validate_bestseller_page(page, demande())
    assert v.status == "invalid"
    assert "non numérique" in v.reason


# --- Catégorie, liste classée, CAPTCHA (règles inchangées) -------------------

def test_sans_render_zg_rank(fixture_page):
    v = verdict(fixture_page, "bestsellers_sans_rang.html")
    assert v.status == "invalid"
    assert "render.zg.rank" in v.reason
    assert v.rank_count == 0


def test_canonical_d_une_autre_categorie(fixture_page):
    v = verdict(fixture_page, "bestsellers_autre_categorie.html")
    assert v.status == "invalid"
    assert "canonical inattendu" in v.reason
    assert "10000000002" in v.reason


def test_mauvaise_categorie_demandee(fixture_page):
    assert verdict(fixture_page, "bestsellers_exemple.html", demande(node="10000000009")).status == "invalid"


def test_page_captcha(fixture_page):
    v = verdict(fixture_page, "bestsellers_captcha.html")
    assert v.status == "blocked"
    assert v.reason.startswith("CAPTCHA détecté")
    assert "canonical absent" in v.reason
    assert "onglet actif introuvable" in v.reason


def test_structure_manquante_et_mot_captcha(fixture_page):
    # Le mot qualifie une structure manquante : onglet d'un autre type + « captcha » = blocked
    v = verdict(fixture_page, "bestsellers_titre_captcha.html", demande("free"))
    assert v.status == "blocked"


@pytest.mark.parametrize("content", [b"", b"\xff\xfe\x00 pas du html", b"<html><body>Rien</body></html>"])
def test_contenu_inattendu(content):
    v = validate_bestseller_page(content, demande())
    assert v.status == "invalid"
    assert "canonical absent" in v.reason


def test_json_illisible(fixture_page):
    page = fixture_page("bestsellers_exemple.html").replace(
        b'data-client-recs-list="[', b'data-client-recs-list="[[', 1)
    assert validate_bestseller_page(page, demande()).status == "invalid"


def test_deux_listes_classees(fixture_page):
    page = fixture_page("bestsellers_exemple.html")
    start = page.index(b'data-client-recs-list="')
    end = page.index(b'"', start + len(b'data-client-recs-list="'))
    doubled = page.replace(b"<ol ", b"<div " + page[start:end + 1] + b"></div><ol ", 1)
    v = validate_bestseller_page(doubled, demande())
    assert v.status == "invalid"
    assert "2 listes" in v.reason


# --- Annonce de la page suivante (second signal pour la page 2) -------------

def test_page_2_annoncee_par_la_pagination(fixture_page):
    v = verdict(fixture_page, "bestsellers_page1_complete.html")
    assert v.status == "ok"
    assert v.rank_count == 50
    assert v.next_page_announced
    assert not v.short_list


def test_page_2_non_annoncee_sans_pagination(fixture_page):
    v = verdict(fixture_page, "bestsellers_page1_complete_sans_pagination.html")
    assert v.status == "ok"
    assert v.rank_count == 50
    assert not v.next_page_announced


def test_page_2_desactivee_non_annoncee(fixture_page):
    page = fixture_page("bestsellers_page1_complete.html").replace(
        b'<li aria-label="Page 2" class="a-normal">', b'<li aria-label="Page 2" class="a-disabled">', 1)
    assert not validate_bestseller_page(page, demande()).next_page_announced


def test_aucune_page_3_annoncee_en_page_2(fixture_page):
    assert not verdict(fixture_page, "bestsellers_page2.html", demande("paid", 2)).next_page_announced


def test_page_non_conforme_n_annonce_rien(fixture_page):
    assert not verdict(fixture_page, "bestsellers_page1_complete.html", demande("free")).next_page_announced
