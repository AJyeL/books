"""Génère les variantes de la fiche d'exemple (décision 015, étape B), dans tests/fixtures/.

Chaque variante ne diffère de sa fiche de base que par le point testé (voir README.md). Deux bases : fiche_exemple.html
(ebook Kindle, écrite à la main) et fiche_papier_exemple.html (broché dont l'ISBN-10 sert d'ASIN, sans ligne « ASIN : »,
générée ici à partir de la première). Chaque remplacement doit
porter sur un nombre attendu d'occurrences : une fiche d'exemple modifiée qui ne s'y prêterait plus fait échouer la
génération au lieu de produire une variante sans effet. Après toute modification de l'exemple, relancer depuis la
racine du dépôt :
    python tests/fixtures/generer_fiches.py
"""

from pathlib import Path

HERE = Path(__file__).resolve().parent
EXEMPLE = "fiche_exemple.html"
PAPIER = "fiche_papier_exemple.html"

CANONICAL = '<link rel="canonical" href="https://www.amazon.fr/Le-Royaume-des-cendres/dp/B0FAUX0001" />'
FORMAT_LIGNE = '<span class="a-color-secondary">Format&nbsp;: </span><span>Format Kindle</span>'
TITRE = '<span id="productTitle" class="a-size-extra-large celwidget">\n      Le Royaume des cendres\n    </span>'
ASIN_VALEUR = "<span>B0FAUX0001</span>"
LIGNE_ASIN = '<li><span class="a-list-item"> <span class="a-text-bold">ASIN'
LIGNE_ISBN10 = '<li><span class="a-list-item"> <span class="a-text-bold">ISBN-10'
LIBELLE_FIN = "&rlm;\n                                             :\n                                            &lrm;\n                                        </span>                "


def ligne_detail(libelle: str, valeur: str) -> str:
    """Ligne de la liste des détails, sous la forme observée (marques de direction autour des deux-points)."""
    return (f'<li><span class="a-list-item"> <span class="a-text-bold">{libelle}\n                                            '
            f"{LIBELLE_FIN}<span>{valeur}</span> </span></li>")


# Fiche papier d'exemple : broché, ASIN numérique (son ISBN-10), aucune ligne « ASIN : » dans les détails, mais
# « ISBN-10 : » (égal à l'ASIN) et « ISBN-13 : » ; poids au lieu de la taille du fichier (exploration-amazon.md,
# premières captures de fiches par l'extension). Valeurs inventées.
BASE_PAPIER = [
    ("B0FAUX0001", "2000000001", 3),  # canonical, data-asin, valeur de la ligne ASIN
    ("<span>Format Kindle</span>", "<span>Broché</span>", 1),
    ('class="a-size-large a-color-secondary">Format Kindle</span>', 'class="a-size-large a-color-secondary">Broché</span>', 1),
    (LIGNE_ASIN, LIGNE_ISBN10, 1),
    ("<span>2000000001</span> </span></li>",
     "<span>2000000001</span> </span></li>\n        " + ligne_detail("ISBN-13", "978-2000000005"), 1),
    ("Taille du fichier", "Poids de l'article", 1),
    ("<span>1234 KB</span>", "<span>250 g</span>", 1),
]

# (fichier, fiche de base, [(texte cherché, remplacement, occurrences attendues)]) ; dans l'ordre : une base générée
# (fiche papier) est écrite avant ses variantes
VARIANTES = [
    (PAPIER, EXEMPLE, BASE_PAPIER),
    ("fiche_broche.html", EXEMPLE, [("<span>Format Kindle</span>", "<span>Broché</span>", 1)]),
    ("fiche_relie.html", EXEMPLE, [("<span>Format Kindle</span>", "<span>Relié</span>", 1)]),
    ("fiche_audio.html", EXEMPLE, [("<span>Format Kindle</span>", "<span>Livre audio</span>", 1)]),
    ("fiche_poche.html", EXEMPLE, [("<span>Format Kindle</span>", "<span>Poche</span>", 1)]),
    ("fiche_sans_canonical.html", EXEMPLE, [(CANONICAL + "\n", "", 1)]),
    ("fiche_deux_canonicals.html", EXEMPLE, [(CANONICAL, CANONICAL + "\n" + CANONICAL.replace("B0FAUX0001", "B0FAUX0009"), 1)]),
    ("fiche_canonical_autre_asin.html", EXEMPLE, [(CANONICAL, CANONICAL.replace("B0FAUX0001", "B0FAUX0009"), 1)]),
    ("fiche_canonical_hors_fiches.html", EXEMPLE,
     [(CANONICAL, '<link rel="canonical" href="https://www.amazon.fr/gp/bestsellers/digital-text/10000000001" />', 1)]),
    ("fiche_sans_titre.html", EXEMPLE, [('id="productTitle"', 'id="productTitleAbsent"', 1)]),
    ("fiche_titre_vide.html", EXEMPLE, [(TITRE, '<span id="productTitle" class="a-size-extra-large celwidget">\n    </span>', 1)]),
    ("fiche_deux_titres.html", EXEMPLE, [(TITRE, TITRE + "\n    " + TITRE, 1)]),
    ("fiche_titre_captcha.html", EXEMPLE, [("Le Royaume des cendres\n    </span>", "Le Captcha des cendres\n    </span>", 1)]),
    ("fiche_sans_asin_details.html", EXEMPLE, [(LIGNE_ASIN, '<li><span class="a-list-item"> <span class="a-text-bold">EAN', 1)]),
    # Ligne « ASIN : » et ligne « ISBN-10 : » de valeur différente : l'ASIN décide, l'ISBN-10 est ignoré
    ("fiche_asin_et_isbn10.html", EXEMPLE,
     [("<span>B0FAUX0001</span> </span></li>",
       "<span>B0FAUX0001</span> </span></li>\n        " + ligne_detail("ISBN-10", "2000000009"), 1)]),
    ("fiche_asin_details_different.html", EXEMPLE, [(ASIN_VALEUR, "<span>B0FAUX0009</span>", 1)]),
    ("fiche_deux_lignes_asin.html", EXEMPLE,
     [(LIGNE_ASIN, '<li><span class="a-list-item"> <span class="a-text-bold">ASIN :</span> <span>B0FAUX0001</span>'
                   '</span></li>\n        ' + LIGNE_ASIN, 1)]),
    ("fiche_asin_sans_marques.html", EXEMPLE, [("&rlm;", "", 5), ("&lrm;", "", 5)]),
    ("fiche_insecable_caractere.html", EXEMPLE, [("Format&nbsp;: ", "Format\u00a0: ", 2)]),
    ("fiche_format_hors_ligne_auteur.html", EXEMPLE, [(FORMAT_LIGNE, "", 1)]),
    ("fiche_deux_formats.html", EXEMPLE, [(FORMAT_LIGNE, FORMAT_LIGNE + " " + FORMAT_LIGNE, 1)]),
    ("fiche_sans_ligne_auteur.html", EXEMPLE, [('<div id="bylineInfo" ', '<div id="bylineInfoAbsent" ', 1)]),
    ("fiche_sans_details.html", EXEMPLE, [('<div id="detailBullets_feature_div"', '<div id="detailBulletsAbsent"', 2)]),
    # Fiche papier (ISBN-10 servant d'ASIN, amendement du 10 octobre 2026)
    ("fiche_papier_isbn_x.html", PAPIER, [("2000000001", "200000000X", 3)]),
    ("fiche_papier_isbn_tirets.html", PAPIER, [("<span>2000000001</span>", "<span>2-00-000000-1</span>", 1)]),
    ("fiche_papier_isbn_different.html", PAPIER, [("<span>2000000001</span>", "<span>2000000009</span>", 1)]),
    ("fiche_papier_deux_isbn10.html", PAPIER,
     [(LIGNE_ISBN10, ligne_detail("ISBN-10", "2000000001") + "\n        " + LIGNE_ISBN10, 1)]),
]


def main() -> None:
    bases = {EXEMPLE: (HERE / EXEMPLE).read_text(encoding="utf-8")}
    for name, base, changes in VARIANTES:
        page = bases[base]
        for old, new, expected in changes:
            found = page.count(old)
            if found != expected:
                raise SystemExit(f"{name} : {found} occurrence(s) de {old!r}, {expected} attendue(s)")
            page = page.replace(old, new)
        bases[name] = page
        (HERE / name).write_text(page, encoding="utf-8", newline="\n")
        print(name)


if __name__ == "__main__":
    main()
