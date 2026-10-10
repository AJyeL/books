"""Génère des captures de test conformes à la décision 007 (valeurs inventées), dans tests/fixtures/captures/.

Chaque capture (page de classement ou fiche produit) est une paire .html + .json, construite à partir des fausses pages de ce dossier :
HTML = « <!DOCTYPE html> » suivi du reste de la page, sans séparateur ; JSON au schéma version 1,
avec empreinte et taille exactes. Après toute modification des fausses pages, relancer depuis la racine du dépôt :
    python tests/fixtures/generer_captures.py
"""

import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "captures"
BASE_URL = "https://www.amazon.fr/gp/bestsellers/digital-text/"
USER_AGENT = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
              "Chrome/140.0.0.0 Safari/537.36")

# (fausse page source, catégorie, liste, page, horodatage UTC, adresse affichée après la catégorie)
CAPTURES = [
    ("bestsellers_page1_complete.html", "10000000001", "paid", 1, "2026-10-06T200000Z", ""),
    ("bestsellers_page2.html", "10000000001", "paid", 2, "2026-10-06T200010Z",
     "/ref=zg_bs_pg_2_digital-text?ie=UTF8&pg=2"),
    ("bestsellers_gratuit.html", "10000000001", "free", 1, "2026-10-06T200020Z", "/ref=zg_bs?ie=UTF8&tf=1"),
    # Page de vérification affichée à l'adresse du Top payant : capture intègre, classée blocked à la validation
    ("bestsellers_captcha.html", "10000000001", "paid", 1, "2026-10-06T200030Z", ""),
    # Seconde catégorie inventée : capture intègre, acceptée (décision 014 : toute catégorie est dans le périmètre)
    ("bestsellers_exemple.html", "10000000009", "paid", 1, "2026-10-06T200040Z", ""),
]

# Fiches produit (décision 015) : (fausse page source, ASIN, horodatage UTC, adresse affichée)
PRODUCT_CAPTURES = [
    ("fiche_exemple.html", "B0FAUX0001", "2026-10-06T200050Z",
     "https://www.amazon.fr/Le-Royaume-des-cendres/dp/B0FAUX0001/ref=zg_bs_g_digital-text_d_sccl_1"),
    # Livre audio : capture intègre, classée invalid à la validation (format non accepté)
    ("fiche_audio.html", "B0FAUX0001", "2026-10-06T200100Z", "https://www.amazon.fr/dp/B0FAUX0001"),
    # Page de vérification affichée à l'adresse d'une fiche : capture intègre, classée blocked
    ("bestsellers_captcha.html", "B0FAUX0001", "2026-10-06T200110Z", "https://www.amazon.fr/dp/B0FAUX0001"),
    # Fiche papier dont l'ISBN-10 sert d'ASIN (ASIN numérique, sans ligne « ASIN : ») : intègre, ok
    ("fiche_papier_exemple.html", "2000000001", "2026-10-06T200130Z",
     "https://www.amazon.fr/Le-Royaume-des-cendres/dp/2000000001/ref=tmm_pap_swatch_0"),
]


def to_dom(page: str, node: str | None = None) -> bytes:
    """Forme d'une capture DOM : déclaration reconstruite en majuscules, sans séparateur (décision 007)."""
    if node is not None:
        page = page.replace("10000000001", node)
    if page.lower().startswith("<!doctype html>"):
        page = page[len("<!doctype html>"):].lstrip("\n")
    return ("<!DOCTYPE html>" + page).encode("utf-8")


def write_capture(stem: str, html: bytes, stamp: str, displayed_url: str, source: str) -> None:
    meta = {
        "schema_version": 1,
        "displayed_url": displayed_url,
        "captured_at": f"{stamp[:13]}:{stamp[13:15]}:{stamp[15:17]}Z",
        "capture_method": "extension-dom",
        "extension_version": "0.1.1",
        "user_agent": USER_AGENT,
        "html_sha256": hashlib.sha256(html).hexdigest(),
        "html_bytes": len(html),
    }
    (OUT / f"{stem}.html").write_bytes(html)
    (OUT / f"{stem}.json").write_bytes((json.dumps(meta, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
    print(f"{stem} ({source})")


def main() -> None:
    OUT.mkdir(exist_ok=True)
    for source, node, list_type, page, stamp, url_tail in CAPTURES:
        stem = f"amazon_fr_bestsellers_{node}_{list_type}_p{page}_{stamp}"
        html = to_dom((HERE / source).read_text(encoding="utf-8"), node)
        write_capture(stem, html, stamp, BASE_URL + node + url_tail, source)
    for source, asin, stamp, displayed_url in PRODUCT_CAPTURES:
        html = to_dom((HERE / source).read_text(encoding="utf-8"))
        write_capture(f"amazon_fr_product_{asin}_{stamp}", html, stamp, displayed_url, source)


if __name__ == "__main__":
    main()
