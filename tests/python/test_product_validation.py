"""Tests de books.collector.product_validation : validation d'une fiche produit (décision 015, section 5).

Fausses fiches inventées : fiche_exemple.html et ses variantes (generer_fiches.py, voir tests/fixtures/README.md).
"""

import pytest

from books.amazon.product_page import ProductRequest
from books.collector.product_validation import ACCEPTED_FORMATS, normalize, validate_product_page
from books.collector.validation import Verdict, next_page
from conftest import FIXTURES, demande

ASIN = "B0FAUX0001"
FICHE = ProductRequest(ASIN)
# Sentinelles RGPD de la fiche d'exemple : jamais dans un motif (décisions 013 et 015)
SENTINELLES = ("Sentinelle-Rgpd", "B0SENTAUT1", "Sentinelle-Commentatrice", "Exempleville-Sentinelle",
               "Sentinelle-Editrice")


def valider(nom: str, request: ProductRequest = FICHE) -> Verdict:
    return validate_product_page((FIXTURES / nom).read_bytes(), request)


def test_fiche_exemple_conforme():
    verdict = valider("fiche_exemple.html")
    assert verdict == Verdict(status="ok", reason=None)


def test_fiche_sans_liste_classee_rank_count_none():
    # Une fiche n'a pas de liste classée : nombre de rangs inconnu (None), jamais 0 (NULL n'est pas zéro)
    verdict = valider("fiche_exemple.html")
    assert verdict.rank_count is None
    assert not verdict.short_list
    for status in ("blocked", "invalid"):
        assert valider("bestsellers_captcha.html" if status == "blocked" else "fiche_audio.html").rank_count is None


def test_verdict_sans_liste_classee_aucune_page_suivante():
    # next_page ne déduit rien d'un verdict sans liste classée, même si une page 2 est annoncée :
    # ni page 2 attendue, ni divergence « seulement None rangs »
    verdict = Verdict(status="ok", reason=None, next_page_announced=True)
    assert next_page(demande("paid", 1), verdict) == (None, None)


@pytest.mark.parametrize("nom", ["fiche_broche.html", "fiche_relie.html"], ids=["broche", "relie"])
def test_formats_papier_acceptes(nom):
    assert valider(nom).status == "ok"


@pytest.mark.parametrize("nom", ["fiche_audio.html", "fiche_poche.html"], ids=["audio", "poche-non-observe"])
def test_autres_formats_refuses(nom):
    verdict = valider(nom)
    assert verdict.status == "invalid"
    assert verdict.reason == "Fiche non conforme : format affiché non accepté (ni ebook Kindle, ni broché, ni relié)"


def test_formats_acceptes_observes_seulement():
    # « Poche » est refusé tant qu'il n'a pas été observé (décision 015, note de l'étape B)
    assert ACCEPTED_FORMATS == ("Format Kindle", "Broché", "Relié")


NON_CONFORMES = [
    ("fiche_sans_canonical.html", "lien canonical absent"),
    ("fiche_deux_canonicals.html", "2 liens canonical différents (un seul attendu)"),
    ("fiche_canonical_autre_asin.html", "canonical : ASIN différent de celui de l'adresse affichée"),
    ("fiche_canonical_hors_fiches.html", "canonical hors des fiches produit"),
    ("fiche_sans_titre.html", "titre (productTitle) introuvable"),
    ("fiche_titre_vide.html", "titre (productTitle) vide"),
    ("fiche_deux_titres.html", "2 titres (productTitle), un seul attendu"),
    ("fiche_sans_details.html", "liste des détails (detailBullets_feature_div) introuvable"),
    ("fiche_sans_asin_details.html", "ligne ASIN introuvable dans la liste des détails"),
    ("fiche_asin_details_different.html", "ASIN de la liste des détails différent de celui de l'adresse affichée"),
    ("fiche_deux_lignes_asin.html", "2 lignes ASIN dans la liste des détails (une seule attendue)"),
    ("fiche_sans_ligne_auteur.html", "ligne d'auteur (bylineInfo) introuvable"),
    ("fiche_format_hors_ligne_auteur.html", "format introuvable dans la ligne d'auteur"),
    ("fiche_deux_formats.html", "2 formats dans la ligne d'auteur (un seul attendu)"),
]


@pytest.mark.parametrize("nom, motif", NON_CONFORMES, ids=[nom for nom, _ in NON_CONFORMES])
def test_fiche_non_conforme(nom, motif):
    verdict = valider(nom)
    assert verdict.status == "invalid"
    assert verdict.reason == f"Fiche non conforme : {motif}"


def test_format_lu_dans_la_ligne_d_auteur_seulement():
    # Piège observé : « Format : Broché » dans une carte de recommandation, hors de la ligne d'auteur.
    # La fiche d'exemple (Kindle) le contient : elle reste conforme ; sans format dans la ligne d'auteur, elle ne l'est pas.
    assert "Format&nbsp;: </span><span>Broché</span>" in (FIXTURES / "fiche_exemple.html").read_text(encoding="utf-8")
    assert valider("fiche_exemple.html").status == "ok"
    assert valider("fiche_format_hors_ligne_auteur.html").status == "invalid"


def test_asin_demande_different():
    verdict = valider("fiche_exemple.html", ProductRequest("B0FAUX0009"))
    assert verdict.status == "invalid"
    assert "canonical : ASIN différent" in verdict.reason and "ASIN de la liste des détails différent" in verdict.reason


@pytest.mark.parametrize("nom", ["fiche_asin_sans_marques.html", "fiche_insecable_caractere.html"],
                         ids=["sans-marques-invisibles", "insecable-en-caractere"])
def test_variantes_d_ecriture_des_libelles(nom):
    # Libellés avec ou sans marques de direction, espace insécable en entité ou en caractère : même lecture
    assert valider(nom).status == "ok"


def test_normalisation_des_libelles():
    assert normalize("ASIN\n   ‏\n   :\n   ‎\n ") == "ASIN :"
    assert normalize("Format : ") == "Format :"


def test_la_structure_decide_le_mot_captcha_qualifie():
    assert valider("fiche_titre_captcha.html").status == "ok"  # « Captcha » dans un titre conforme
    verdict = valider("bestsellers_captcha.html")  # page de vérification (structure supposée)
    assert verdict.status == "blocked"
    assert verdict.reason.startswith("CAPTCHA détecté : lien canonical absent")


VARIANTES = sorted(p.name for p in FIXTURES.glob("fiche_*.html"))


@pytest.mark.parametrize("nom", VARIANTES)
def test_aucun_contenu_de_la_page_dans_les_motifs(nom):
    # Motifs sans contenu de la page : ni sentinelle, ni titre, ni format refusé, ni libellé de l'adresse canonique
    verdict = valider(nom)
    for interdit in SENTINELLES + ("Royaume", "Livre audio", "Poche"):
        assert interdit not in (verdict.reason or "")


def test_sentinelles_presentes_dans_la_fiche_d_exemple():
    # Sans elles, le test précédent ne prouverait rien
    page = (FIXTURES / "fiche_exemple.html").read_text(encoding="utf-8")
    for sentinelle in SENTINELLES:
        assert sentinelle in page
