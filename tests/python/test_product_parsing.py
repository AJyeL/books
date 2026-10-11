"""Tests de books.transformer.product_parsing : analyse d'une fiche produit (décision 015, étape D).

Fiches inventées : fiche_extraction_exemple.html et ses variantes (generer_fiches_extraction.py, tests/fixtures/README.md).
"""

import hashlib
from datetime import date
from decimal import Decimal

import pytest

from books.amazon.product_page import ProductRequest
from books.collector.product_validation import validate_product_page
from books.transformer.parsing import EXTRACTOR_VERSION, ParseError
from books.transformer.product_parsing import (
    PageSkipped, ProductFormat, RatingShare, SalesRank, parse_product_page,
)
from conftest import FIXTURES

SENTINELLES = ("Sentinelle-Rgpd", "B0SENTAUT1", "Sentinelle-Commentatrice", "Exempleville-Sentinelle",
               "Sentinelle-Editrice")


def fiche(nom: str) -> bytes:
    return (FIXTURES / f"fiche_extraction_{nom}.html").read_bytes()


def analyser(nom: str):
    return parse_product_page(fiche(nom))


def test_version_3():
    assert EXTRACTOR_VERSION == "3"  # 3 : fiches produit (décision 015, étape D)


def test_fiche_d_exemple_conforme_a_la_validation():
    # Toute fiche d'exemple de l'extracteur est d'abord une fiche que la validation accepte (sauf le poche, refusé)
    assert validate_product_page(fiche("exemple"), ProductRequest("B0FAUX0001")).status == "ok"


def test_fiche_d_exemple_observation():
    p = analyser("exemple")
    assert (p.format_label, p.title) == ("Format Kindle", "Titre d’exemple pour les tests")
    assert (p.series_form, p.series_name, p.series_position, p.series_total) == (
        "livre_n_sur_n", "La Saga d'exemple", 2, 3)
    assert (p.publication_date, p.language, p.print_pages) == (date(2026, 1, 1), "Français", 412)
    assert (p.file_size_value, p.file_size_unit, p.isbn13) == (Decimal("1.2"), "MB", "978-2000000005")
    assert (p.rating, p.review_count) == (Decimal("4.4"), 1234)
    assert p.cover_url == "https://m.media-amazon.com/images/I/exemple._SL1500_.jpg"
    assert (p.has_aplus, p.breadcrumb) == (True, "Boutique Kindle › Catégorie d'exemple")


def test_fiche_d_exemple_onglets():
    assert analyser("exemple").formats == (
        ProductFormat(1, "KINDLE", "Format Kindle", True, None, Decimal("4.99"), "EUR", "exact", True),
        ProductFormat(2, "AUDIO_DOWNLOAD", "Livre audio", False, "B0FAUX0004", Decimal("9.95"), "EUR",
                      "avec_abonnement", False),
        ProductFormat(3, "PAPERBACK", "Broché", False, "2000000001", Decimal("14.90"), "EUR", "exact", False),
        ProductFormat(4, "HARDCOVER", "Relié", False, "B0FAUX0005", None, None, "non_affiche", False),
    )


def test_fiche_d_exemple_rangs_et_repartition():
    p = analyser("exemple")
    assert p.sales_ranks == (
        SalesRank(1, True, 1234, "digital-text", None, "paid"),
        SalesRank(2, False, 5, "digital-text", "10000000001", "paid"),
        SalesRank(3, False, 12, "books", "10000000002", "paid"),
        SalesRank(4, False, 1234, "digital-text", "10000000003", "paid"),
    )
    assert p.rating_shares == tuple(RatingShare(s, pc) for s, pc in ((5, 62), (4, 20), (3, 10), (2, 5), (1, 3)))


def test_description_texte_et_balisage():
    p = analyser("exemple")
    assert p.description_text == ("Une description inventée, sans rapport avec un livre réel & ses <balises>. "
                                  "Classe inconnue. Un paragraphe souligné. Un titre Premier point Second point")
    assert p.description_markup == (
        "Une <b>description</b> inventée, <i>sans</i> rapport avec un livre <b><i>réel</i></b> &amp; ses &lt;balises&gt;."
        "<br><br>Classe inconnue.<p>Un paragraphe <u>souligné</u>.</p><h4>Un titre</h4>"
        "<ul><li>Premier point</li><li>Second point</li></ul>")
    assert p.description_text_sha256 == hashlib.sha256(p.description_text.encode("utf-8")).hexdigest()
    assert p.description_markup_sha256 == hashlib.sha256(p.description_markup.encode("utf-8")).hexdigest()
    # Aucun attribut dans le balisage ; classes inconnues et balises retirées comptées pour le bilan
    assert "=" not in p.description_markup and "<script" not in p.description_markup
    assert dict(p.unknown_span_classes) == {"a-list-item": 2, "a-size-medium": 1}
    assert dict(p.removed_tags) == {"script": 1}


def test_contenu_des_scripts_jamais_lu():
    # Des <script> figurent dans l'onglet audio (titre et message) et dans la description
    p = analyser("exemple")
    assert "script ignoré" in fiche("exemple").decode("utf-8")
    assert "script ignoré" not in repr(p)


def test_bloc_de_note_des_details_jamais_lu():
    # Un second #acrPopover figure dans la liste des détails (« Commentaires client ») : seul le bloc du haut est lu
    assert fiche("exemple").count(b'id="acrPopover"') == 2
    assert analyser("exemple").rating == Decimal("4.4")


@pytest.mark.parametrize("nom, attendu", [
    ("gratuit", {"general": SalesRank(1, True, 1234, "digital-text", None, "free"), "cat_list": "free",
                 "kindle": ProductFormat(1, "KINDLE", "Format Kindle", True, None, Decimal("0.00"), "EUR", "exact", False)}),
    ("rang_rare", {"general": SalesRank(1, True, 12345, "books", "10000000009", "paid")}),
])
def test_formes_de_rang(nom, attendu):
    p = analyser(nom)
    assert p.sales_ranks[0] == attendu["general"]
    if "cat_list" in attendu:
        assert p.sales_ranks[1].list_type == attendu["cat_list"]
    if "kindle" in attendu:
        assert p.formats[0] == attendu["kindle"]


def test_lien_du_rang_gratuit_mal_forme_par_amazon():
    # Forme réelle : « …/digital-text?tf=1/ref=…?tf=1 » (deux « ? ») : reconnue comme Top gratuit
    assert b"digital-text?tf=1/ref=pd_zg_ts_digital-text?tf=1" in fiche("gratuit")
    assert analyser("gratuit").sales_ranks[0].list_type == "free"


def test_fiche_sans_avis_zero_avis():
    p = analyser("sans_avis")
    assert (p.rating, p.review_count) == (None, 0)
    assert all(s.percent == 0 for s in p.rating_shares) and len(p.rating_shares) == 5


@pytest.mark.parametrize("nom, champ, valeur", [
    ("sans_aplus", "has_aplus", False),
    ("fait_partie", "series_form", "fait_partie"),
    ("sans_serie", "series_name", None),
    ("sans_description", "description_markup", None),
    ("sans_couverture", "cover_url", None),
    ("un_commentaire", "review_count", 1),
])
def test_formes_acceptees(nom, champ, valeur):
    assert getattr(analyser(nom), champ) == valeur


def test_fait_partie_sans_rang():
    p = analyser("fait_partie")
    assert (p.series_name, p.series_position, p.series_total) == ("La Saga d'exemple", None, None)


def test_taille_en_kb_sans_conversion():
    assert (analyser("taille_kb").file_size_value, analyser("taille_kb").file_size_unit) == (Decimal("850"), "KB")


@pytest.mark.parametrize("nom, position, qualificatif, montant", [
    ("offre_essai", 2, "avec_offre_essai", Decimal("9.95")),
    ("a_partir_de", 3, "a_partir_de", Decimal("14.90")),
])
def test_qualificatifs_de_prix(nom, position, qualificatif, montant):
    f = analyser(nom).formats[position - 1]
    assert (f.price_qualifier, f.price_amount) == (qualificatif, montant)


def test_fiche_papier_mise_a_part():
    with pytest.raises(PageSkipped, match="^format papier$"):
        analyser("papier")


ECHECS = [
    ("poche", "format affiché ni Kindle ni papier"),
    ("prix_espace", "onglet KINDLE : message d'achat de forme inconnue"),
    ("rang_espace", "rang général de forme inconnue"),
    ("rang_insecable", "rang général de forme inconnue"),
    ("date_inconnue", "date de publication de forme inconnue"),
    ("date_impossible", "date de publication impossible"),
    ("pages_separateur", "nombre de pages de forme inconnue"),
    ("taille_virgule", "taille du fichier de forme inconnue"),
    ("avis_different", "aria-label du nombre d'avis de forme inconnue ou différent"),
    ("note_seule", "note et nombre d'avis non affichés ensemble"),
    ("commentaire_accord", "accord de « Commentaire » inattendu"),
    ("histogramme_4_lignes", "répartition des notes : 4 ligne(s)"),
    ("pourcentage_espace", "répartition des notes : pourcentage de forme inconnue"),
    ("etoiles_inconnues", "répartition des notes : niveau de forme inconnue"),
    ("serie_incoherente", "rang dans la série incohérent"),
    ("deux_dates", "libellé en double dans la liste des détails"),
    ("onglet_prix_inconnu", "onglet PAPERBACK : prix de forme inconnue"),
    ("message_audio_inconnu", "onglet AUDIO_DOWNLOAD : message de forme inconnue"),
    ("lien_rang_inconnu", "rang de catégorie : lien de classement de forme inconnue"),
    ("gratuit_incoherent", "rang général incohérent avec son lien"),
]


@pytest.mark.parametrize("nom, motif", ECHECS, ids=[n for n, _ in ECHECS])
def test_forme_inconnue_echec_de_la_fiche(nom, motif):
    with pytest.raises(ParseError) as exc:
        analyser(nom)
    assert str(exc.value).startswith(motif)


def test_contenu_non_utf8():
    with pytest.raises(ParseError, match="UTF-8"):
        parse_product_page(b"\xff\xfe<html>")


TOUTES = sorted(p.name[len("fiche_extraction_"):-len(".html")] for p in FIXTURES.glob("fiche_extraction_*.html"))


@pytest.mark.parametrize("nom", TOUTES)
def test_aucune_sentinelle_rgpd(nom):
    # Auteur, éditeur, commentatrice, livraison : dans aucun champ, ni dans aucun motif (décisions 013 et 015)
    try:
        resultat = repr(analyser(nom))
    except (ParseError, PageSkipped) as exc:
        resultat = str(exc)
    for sentinelle in SENTINELLES:
        assert sentinelle not in resultat, sentinelle


def test_sentinelles_presentes_dans_la_fiche_d_exemple():
    page = fiche("exemple").decode("utf-8")
    assert all(s in page for s in SENTINELLES)
