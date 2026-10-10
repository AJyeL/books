"""Génère les variantes de la fiche d'exemple (décision 015, étape B), dans tests/fixtures/.

Chaque variante ne diffère de fiche_exemple.html que par le point testé (voir README.md). Chaque remplacement doit
porter sur un nombre attendu d'occurrences : une fiche d'exemple modifiée qui ne s'y prêterait plus fait échouer la
génération au lieu de produire une variante sans effet. Après toute modification de l'exemple, relancer depuis la
racine du dépôt :
    python tests/fixtures/generer_fiches.py
"""

from pathlib import Path

HERE = Path(__file__).resolve().parent
EXEMPLE = "fiche_exemple.html"

CANONICAL = '<link rel="canonical" href="https://www.amazon.fr/Le-Royaume-des-cendres/dp/B0FAUX0001" />'
FORMAT_LIGNE = '<span class="a-color-secondary">Format&nbsp;: </span><span>Format Kindle</span>'
TITRE = '<span id="productTitle" class="a-size-extra-large celwidget">\n      Le Royaume des cendres\n    </span>'
ASIN_VALEUR = "<span>B0FAUX0001</span>"
LIGNE_ASIN = '<li><span class="a-list-item"> <span class="a-text-bold">ASIN'

# (fichier, [(texte cherché, remplacement, occurrences attendues)])
VARIANTES = [
    ("fiche_broche.html", [("<span>Format Kindle</span>", "<span>Broché</span>", 1)]),
    ("fiche_relie.html", [("<span>Format Kindle</span>", "<span>Relié</span>", 1)]),
    ("fiche_audio.html", [("<span>Format Kindle</span>", "<span>Livre audio</span>", 1)]),
    ("fiche_poche.html", [("<span>Format Kindle</span>", "<span>Poche</span>", 1)]),
    ("fiche_sans_canonical.html", [(CANONICAL + "\n", "", 1)]),
    ("fiche_deux_canonicals.html", [(CANONICAL, CANONICAL + "\n" + CANONICAL.replace("B0FAUX0001", "B0FAUX0009"), 1)]),
    ("fiche_canonical_autre_asin.html", [(CANONICAL, CANONICAL.replace("B0FAUX0001", "B0FAUX0009"), 1)]),
    ("fiche_canonical_hors_fiches.html",
     [(CANONICAL, '<link rel="canonical" href="https://www.amazon.fr/gp/bestsellers/digital-text/10000000001" />', 1)]),
    ("fiche_sans_titre.html", [('id="productTitle"', 'id="productTitleAbsent"', 1)]),
    ("fiche_titre_vide.html", [(TITRE, '<span id="productTitle" class="a-size-extra-large celwidget">\n    </span>', 1)]),
    ("fiche_deux_titres.html", [(TITRE, TITRE + "\n    " + TITRE, 1)]),
    ("fiche_titre_captcha.html", [("Le Royaume des cendres\n    </span>", "Le Captcha des cendres\n    </span>", 1)]),
    ("fiche_sans_asin_details.html", [(LIGNE_ASIN, '<li><span class="a-list-item"> <span class="a-text-bold">ISBN-10', 1)]),
    ("fiche_asin_details_different.html", [(ASIN_VALEUR, "<span>B0FAUX0009</span>", 1)]),
    ("fiche_deux_lignes_asin.html",
     [(LIGNE_ASIN, '<li><span class="a-list-item"> <span class="a-text-bold">ASIN :</span> <span>B0FAUX0001</span>'
                   '</span></li>\n        ' + LIGNE_ASIN, 1)]),
    ("fiche_asin_sans_marques.html", [("&rlm;", "", 5), ("&lrm;", "", 5)]),
    ("fiche_insecable_caractere.html", [("Format&nbsp;: ", "Format : ", 2)]),
    ("fiche_format_hors_ligne_auteur.html", [(FORMAT_LIGNE, "", 1)]),
    ("fiche_deux_formats.html", [(FORMAT_LIGNE, FORMAT_LIGNE + " " + FORMAT_LIGNE, 1)]),
    ("fiche_sans_ligne_auteur.html", [('<div id="bylineInfo" ', '<div id="bylineInfoAbsent" ', 1)]),
    ("fiche_sans_details.html", [('<div id="detailBullets_feature_div"', '<div id="detailBulletsAbsent"', 2)]),
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
