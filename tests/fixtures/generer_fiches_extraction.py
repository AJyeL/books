"""Génère les variantes de fiche_extraction_exemple.html (extracteur version 3, décision 015, étape D).

Chaque variante ne diffère de l'exemple que par le point testé (voir README.md, « Fiches de l'extracteur »). Chaque
remplacement porte sur un nombre attendu d'occurrences : une fiche d'exemple modifiée qui ne s'y prêterait plus fait
échouer la génération. Après toute modification de l'exemple, relancer depuis la racine du dépôt :
    python tests/fixtures/generer_fiches_extraction.py
"""

from pathlib import Path

HERE = Path(__file__).resolve().parent
EXEMPLE = "fiche_extraction_exemple.html"

KU_PRICE = '<span aria-label="Emprunt"> Emprunt </span>'
KU_MESSAGE = '<span class="a-color-price">4,99&nbsp;€</span>'
GENERAL = "1&#8239;234 en Boutique Kindle ("
GENERAL_LINK = '<a href="/gp/bestsellers/digital-text/ref=pd_zg_ts_digital-text">Voir les 100 premiers en Boutique Kindle</a>'
CAT_LINK = "/gp/bestsellers/digital-text/10000000001/ref=pd_zg_hrsr_digital-text"
COUNTER = '<span id="acrCustomerReviewText" aria-label="1&nbsp;234 Commentaires" class="a-size-small">(1&nbsp;234)</span>'
AUDIO_MESSAGE = "<span><span> avec votre abonnement </span></span>"
SERIES_LABEL = '<span class="a-text-bold">Livre 2 sur 3\n'
DATE = "<span>1 janvier 2026</span>"
REVIEWS_BLOCK_START = '<div id="averageCustomerReviews" data-asin="B0FAUX0001" data-ref="dpx_acr_pop_">'
APLUS = '<div class="aplus-v2 desktop celwidget"><div class="aplus-module"><img src="https://m.media-amazon.com/images/S/aplus.jpg" alt=""><p>Un bloc A+ inventé.</p></div></div>'
FORMAT_VALUE = '<span class="a-color-secondary">Format&nbsp;: </span><span>Format Kindle</span>'
SIZE = "<span>1.2 MB</span>"
PAGES = "<span>412 pages</span>"
PCT = ["62%</div>", "20%</div>", "10%</div>", "5%</div>", "3%</div>"]


def ligne_date_en_double() -> str:
    return ("<li><span class=\"a-list-item\"> <span class=\"a-text-bold\">Date de publication :</span> "
            "<span>2 janvier 2026</span> </span></li>\n        ")


# (fichier, [(texte cherché, remplacement, occurrences attendues)])
VARIANTES = [
    # --- Formes acceptées ---------------------------------------------------------------------------------------
    ("fiche_extraction_gratuit.html", [
        (GENERAL, "n°1&#8239;234 des titres gratuits dans la Boutique Kindle (", 1),
        (GENERAL_LINK, '<a href="/gp/bestsellers/digital-text?tf=1/ref=pd_zg_ts_digital-text?tf=1">'
                       'Voir les 100 premiers en Boutique Kindle</a>', 1),
        (CAT_LINK, "/gp/bestsellers/digital-text/10000000001?tf=1", 1),
        (KU_PRICE, '<span class="a-size-base a-color-price a-color-price" aria-label="0,00 €"> 0,00&nbsp;€ </span>', 1),
        ('<span class="a-size-mini a-text-normal">\n              ou\n              <span class="a-color-price">4,99&nbsp;€</span>\n              pour acheter\n            </span>',
         '<div class="a-section"><span class="a-size-small a-text-normal" aria-label="Disponible immédiatement">'
         ' Disponible immédiatement </span></div>', 1)]),
    ("fiche_extraction_sans_avis.html", [
        (REVIEWS_BLOCK_START, '<div id="averageCustomerReviewsAbsent">', 1),
        ('<span id="acrPopover" class="reviewCountTextLinkedHistogram noUnderline"', '<span class="x"', 1),
        (COUNTER, "", 1),
        ] + [(p, p.replace(p.split("%")[0], "0&nbsp;"), 1) for p in PCT]),
    ("fiche_extraction_sans_aplus.html", [(APLUS, "", 1)]),
    ("fiche_extraction_fait_partie.html", [(SERIES_LABEL, '<span class="a-text-bold">Fait partie de la série\n', 1)]),
    ("fiche_extraction_sans_serie.html", [(SERIES_LABEL, '<span class="a-text-bold">Collection d\'exemple\n', 1)]),
    ("fiche_extraction_taille_kb.html", [(SIZE, "<span>850 KB</span>", 1)]),
    ("fiche_extraction_rang_rare.html", [
        (GENERAL + GENERAL_LINK + ")",
         '12&#8239;345 en <a href="/gp/bestsellers/books/10000000009/ref=pd_zg_ts_books">Sous-boutique (Livres)</a>', 1)]),
    ("fiche_extraction_offre_essai.html", [(AUDIO_MESSAGE, "<span><span> avec l'offre d'essai </span></span>", 1)]),
    ("fiche_extraction_a_partir_de.html", [("> 14,90&nbsp;€ </span>", "> à partir de 14,90&nbsp;€ </span>", 1)]),
    ("fiche_extraction_sans_description.html", [
        ('<div class="a-expander-content a-expander-partial-collapse-content">',
         '<div class="a-expander-content-absent">', 1)]),
    ("fiche_extraction_sans_couverture.html", [
        ('data-old-hires="https://m.media-amazon.com/images/I/exemple._SL1500_.jpg"', 'data-old-hires=""', 1)]),
    ("fiche_extraction_un_commentaire.html", [
        (COUNTER, '<span id="acrCustomerReviewText" aria-label="1 Commentaire" class="a-size-small">(1)</span>', 1)]),
    # --- Fiche papier : mise à part ------------------------------------------------------------------------------
    ("fiche_extraction_papier.html", [(FORMAT_VALUE, FORMAT_VALUE.replace("Format Kindle</span>", "Broché</span>"), 1)]),
    # --- Formes inconnues : échec de la fiche ----------------------------------------------------------------------
    ("fiche_extraction_poche.html", [(FORMAT_VALUE, FORMAT_VALUE.replace("Format Kindle</span>", "Poche</span>"), 1)]),
    ("fiche_extraction_prix_espace.html", [(KU_MESSAGE, '<span class="a-color-price">4,99 €</span>', 1)]),
    ("fiche_extraction_rang_espace.html", [(GENERAL, "1 234 en Boutique Kindle (", 1)]),
    ("fiche_extraction_rang_insecable.html", [(GENERAL, "1&nbsp;234 en Boutique Kindle (", 1)]),
    ("fiche_extraction_date_inconnue.html", [(DATE, "<span>1 janvember 2026</span>", 1)]),
    ("fiche_extraction_date_impossible.html", [(DATE, "<span>31 février 2026</span>", 1)]),
    ("fiche_extraction_pages_separateur.html", [(PAGES, "<span>1 234 pages</span>", 1)]),
    ("fiche_extraction_taille_virgule.html", [(SIZE, "<span>1,2 MB</span>", 1)]),
    ("fiche_extraction_avis_different.html", [("(1&nbsp;234)</span>", "(1&nbsp;235)</span>", 1)]),
    ("fiche_extraction_note_seule.html", [(COUNTER, "", 1)]),
    ("fiche_extraction_commentaire_accord.html", [
        (COUNTER, '<span id="acrCustomerReviewText" aria-label="1 Commentaires" class="a-size-small">(1)</span>', 1)]),
    ("fiche_extraction_histogramme_4_lignes.html", [
        ('<li class="a-align-center a-spacing-none"><span class="a-list-item"><div>\n    <a class="a-size-base a-link-normal _cr-ratings-histogram_style_histogram-row-container__exemple" aria-label="3 pour cent',
         '<li class="a-align-center a-spacing-none"><span class="a-list-item"><div class="retiree">\n    <a class="a-size-base a-link-normal _cr-ratings-histogram_style_histogram-row-container__exemple" aria-label="3 pour cent', 1),
        ('<li class="a-align-center a-spacing-none"><span class="a-list-item"><div class="retiree">', '<span class="a-list-item"><div>', 1)]),
    ("fiche_extraction_pourcentage_espace.html", [("62%</div>", "62 %</div>", 1)]),
    ("fiche_extraction_etoiles_inconnues.html", [("5 étoiles</div>", "5 stars</div>", 1)]),
    ("fiche_extraction_serie_incoherente.html", [(SERIES_LABEL, '<span class="a-text-bold">Livre 4 sur 3\n', 1)]),
    ("fiche_extraction_deux_dates.html", [
        ('<li><span class="a-list-item"> <span class="a-text-bold">Langue',
         ligne_date_en_double() + '<li><span class="a-list-item"> <span class="a-text-bold">Langue', 1)]),
    ("fiche_extraction_onglet_prix_inconnu.html", [("> 14,90&nbsp;€ </span>", "> Gratuit </span>", 1)]),
    ("fiche_extraction_message_audio_inconnu.html", [(AUDIO_MESSAGE, "<span><span> avec un code promo </span></span>", 1)]),
    ("fiche_extraction_lien_rang_inconnu.html", [(CAT_LINK, "/gp/new-releases/digital-text/10000000001", 1)]),
    ("fiche_extraction_gratuit_incoherent.html", [
        (GENERAL, "n°1&#8239;234 des titres gratuits dans la Boutique Kindle (", 1)]),
]


def main() -> None:
    exemple = (HERE / EXEMPLE).read_text(encoding="utf-8")
    for name, changes in VARIANTES:
        page = exemple
        for old, new, expected in changes:
            found = page.count(old)
            if found != expected:
                raise SystemExit(f"{name} : {found} occurrence(s) de {old!r}, {expected} attendue(s)")
            page = page.replace(old, new)
        (HERE / name).write_text(page, encoding="utf-8", newline="\n")
        print(name)


if __name__ == "__main__":
    main()
