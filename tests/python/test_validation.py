"""Tests de books.collector.validation, sur les fausses pages de tests/fixtures/."""

import pytest

from books.collector.validation import validate_bestseller_page
from conftest import FIXTURE_NODE


def test_page_valide(fixture_page):
    verdict = validate_bestseller_page(fixture_page("bestsellers_exemple.html"), FIXTURE_NODE)
    assert verdict.status == "ok"
    assert verdict.reason is None
    assert verdict.rank_count == 5
    assert verdict.short_list  # 5 rangs sur 50 : information, pas une erreur


def test_mot_captcha_dans_un_titre_page_valide(fixture_page):
    # La structure décide : le mot « captcha » ne suffit pas à rejeter une page conforme
    verdict = validate_bestseller_page(fixture_page("bestsellers_titre_captcha.html"), FIXTURE_NODE)
    assert verdict.status == "ok"
    assert verdict.rank_count == 5


def test_sans_render_zg_rank(fixture_page):
    verdict = validate_bestseller_page(fixture_page("bestsellers_sans_rang.html"), FIXTURE_NODE)
    assert verdict.status == "invalid"
    assert "render.zg.rank" in verdict.reason
    assert verdict.rank_count == 0


def test_canonical_d_une_autre_categorie(fixture_page):
    verdict = validate_bestseller_page(fixture_page("bestsellers_autre_categorie.html"), FIXTURE_NODE)
    assert verdict.status == "invalid"
    assert "canonical inattendu" in verdict.reason
    assert "10000000002" in verdict.reason


def test_mauvaise_categorie_demandee(fixture_page):
    # Page conforme en soi, mais ce n'est pas la catégorie demandée
    verdict = validate_bestseller_page(fixture_page("bestsellers_exemple.html"), "10000000009")
    assert verdict.status == "invalid"


def test_page_captcha(fixture_page):
    verdict = validate_bestseller_page(fixture_page("bestsellers_captcha.html"), FIXTURE_NODE)
    assert verdict.status == "blocked"
    assert verdict.reason.startswith("CAPTCHA détecté")
    assert "canonical absent" in verdict.reason


def test_structure_manquante_et_mot_captcha(fixture_page):
    # Le mot qualifie une structure manquante : canonical inattendu + « captcha » = blocked
    content = fixture_page("bestsellers_titre_captcha.html").replace(
        b"digital-text/10000000001\">", b"digital-text/10000000002\">", 1)
    assert validate_bestseller_page(content, FIXTURE_NODE).status == "blocked"


@pytest.mark.parametrize("content", [b"", b"\xff\xfe\x00 pas du html", b"<html><body>Rien</body></html>"])
def test_contenu_inattendu(content):
    verdict = validate_bestseller_page(content, FIXTURE_NODE)
    assert verdict.status == "invalid"
    assert "canonical absent" in verdict.reason


def test_json_illisible(fixture_page):
    content = fixture_page("bestsellers_exemple.html").replace(
        b'data-client-recs-list="[', b'data-client-recs-list="[[', 1)
    assert validate_bestseller_page(content, FIXTURE_NODE).status == "invalid"


def test_deux_listes_classees(fixture_page):
    page = fixture_page("bestsellers_exemple.html")
    start = page.index(b'data-client-recs-list="')
    end = page.index(b'"', start + len(b'data-client-recs-list="'))
    doubled = page.replace(b"<ol ", b'<div ' + page[start:end + 1] + b"></div><ol ", 1)
    verdict = validate_bestseller_page(doubled, FIXTURE_NODE)
    assert verdict.status == "invalid"
    assert "2 listes" in verdict.reason
