"""Tests de books.transformer.repository contre un PostgreSQL 17 jetable (migrations 001 à 007), sous le rôle
books_transformer : la clé composée, les contraintes et les droits sont ceux de la vraie base (décisions 011 et 015).

Lancement : bash tests/lancer-tests-postgres.sh (sinon, ces tests sont sautés).
"""

from decimal import Decimal

import psycopg
import pytest

from books.transformer.parsing import ParsedPage, RankingEntry, parse_ranking_page
from books.transformer.product_parsing import parse_product_page
from books.transformer.repository import PgTransformerRepository
from conftest import FIXTURES

COMPLETE = (FIXTURES / "extraction_page1_complete.html").read_bytes()
FICHE = (FIXTURES / "fiche_extraction_exemple.html").read_bytes()


def entries(n: int = 3) -> list[RankingEntry]:
    return parse_ranking_page(COMPLETE).entries[:n]


def parsed(n: int = 3, display: str | None = "Catégorie d'exemple - ebooks",
           short: str | None = "Catégorie d'exemple") -> ParsedPage:
    """Résultat d'analyse : n premières lignes de la page complète, et des noms de catégorie inventés."""
    return ParsedPage(entries=entries(n), display_name=display, short_name=short)


def page_state(pg, page_id):
    """(exécution, statut, motif, nombre annoncé) de page_extraction, et (exécution, rang) des lignes de la page."""
    state = pg.query("SELECT extract_run_id, status, error_message, entry_count FROM staging.page_extraction "
                     "WHERE raw_page_id = %s", (page_id,))
    rows = pg.query("SELECT extract_run_id, rank FROM staging.ranking_entry WHERE raw_page_id = %s ORDER BY rank",
                    (page_id,))
    return (state[0] if state else None), rows


def test_connecte_sous_books_transformer(pg):
    assert pg.transformer.execute("SELECT current_user").fetchone() == ("books_transformer",)


def test_perimetre_et_hors_perimetre(pg):
    inside = pg.add_page(COMPLETE)
    pg.add_page(COMPLETE, method="manual-html")
    pg.add_page(COMPLETE, method=None)
    pg.add_page(COMPLETE, status="blocked")
    pg.add_page(COMPLETE, status="invalid")
    product = pg.add_page(FICHE, page_type="product")  # fiche produit : dans le périmètre depuis la version 3
    pg.add_page(FICHE, page_type="product", status="invalid")
    repo = PgTransformerRepository(pg.transformer)
    pages = repo.pages_to_extract("1", force=False)
    assert [p.id for p in pages] == [inside, product]
    assert [p.is_product for p in pages] == [False, True]
    assert pages[1].asin == "B0FAUX0001" and pages[1].label.startswith("fiche B0FAUX0001 ")
    assert repo.out_of_scope() == {"méthode manual-html": 1, "méthode non enregistrée": 1,
                                   "statut blocked": 1, "statut invalid": 2}


def test_ecriture_d_une_page_et_relecture(pg):
    page = pg.add_page(COMPLETE)
    repo = PgTransformerRepository(pg.transformer)
    run = repo.open_run("1")
    repo.save_extraction(run, page, parsed())
    assert page_state(pg, page) == ((run, "ok", None, 3), [(run, 1), (run, 2), (run, 3)])
    # Valeurs relues telles quelles, sans arrondi (numeric)
    assert pg.query("SELECT price_amount, currency, rating, review_count FROM staging.ranking_entry "
                    "WHERE raw_page_id = %s AND rank = 1", (page,)) == [(Decimal("4.99"), "EUR", Decimal("4.5"), 87)]


def test_page_a_jour_puis_changement_de_version_puis_force(pg):
    page = pg.add_page(COMPLETE)
    repo = PgTransformerRepository(pg.transformer)
    repo.save_extraction(repo.open_run("1"), page, parsed())
    assert repo.pages_to_extract("1", force=False) == []
    assert repo.count_up_to_date("1") == (1, 0)
    assert [p.id for p in repo.pages_to_extract("2", force=False)] == [page]  # autre version : à refaire
    assert repo.count_up_to_date("2") == (0, 0)
    assert [p.id for p in repo.pages_to_extract("1", force=True)] == [page]


def test_page_en_echec_reprise_a_chaque_execution(pg):
    page = pg.add_page(COMPLETE)
    repo = PgTransformerRepository(pg.transformer)
    repo.save_failure(repo.open_run("1"), page, "parse_failed", "motif")
    assert [p.id for p in repo.pages_to_extract("1", force=False)] == [page]
    assert repo.count_up_to_date("1") == (0, 0)


def test_reextraction_remplace_les_lignes(pg):
    page = pg.add_page(COMPLETE)
    repo = PgTransformerRepository(pg.transformer)
    run1 = repo.open_run("1")
    repo.save_extraction(run1, page, parsed(3))
    run2 = repo.open_run("2")
    repo.save_extraction(run2, page, parsed(2))
    # Une seule exécution pour la page, ses lignes seulement : jamais deux versions mélangées
    assert page_state(pg, page) == ((run2, "ok", None, 2), [(run2, 1), (run2, 2)])


def test_reextraction_en_echec_supprime_les_lignes(pg):
    page = pg.add_page(COMPLETE)
    repo = PgTransformerRepository(pg.transformer)
    repo.save_extraction(repo.open_run("1"), page, parsed())
    run2 = repo.open_run("2")
    repo.save_failure(run2, page, "parse_failed", "rang 1 : prix de forme inconnue")
    assert page_state(pg, page) == ((run2, "parse_failed", "rang 1 : prix de forme inconnue", 0), [])


def test_ordre_impose_par_la_base(pg):
    # Mise à jour de page_extraction AVANT la suppression des lignes : refusée par la clé composée.
    # C'est la base, et non le seul code, qui empêche deux versions mélangées.
    page = pg.add_page(COMPLETE)
    repo = PgTransformerRepository(pg.transformer)
    repo.save_extraction(repo.open_run("1"), page, parsed())
    run2 = repo.open_run("2")
    with pytest.raises(psycopg.errors.ForeignKeyViolation, match="ranking_entry_page_extraction_fk"):
        pg.transformer.execute("UPDATE staging.page_extraction SET extract_run_id = %s WHERE raw_page_id = %s",
                               (run2, page))


def test_ecriture_atomique_d_une_page(pg):
    # Une ligne refusée par la base (doublon de rang) : rien n'est écrit pour la page, l'état précédent reste
    page = pg.add_page(COMPLETE)
    repo = PgTransformerRepository(pg.transformer)
    run1 = repo.open_run("1")
    repo.save_extraction(run1, page, parsed(2))
    rows = entries(2)
    with pytest.raises(psycopg.errors.UniqueViolation):
        repo.save_extraction(repo.open_run("2"), page, ParsedPage(rows + [rows[0]], None, None))
    assert page_state(pg, page) == ((run1, "ok", None, 2), [(run1, 1), (run1, 2)])


def test_cloture_de_l_execution(pg):
    repo = PgTransformerRepository(pg.transformer)
    run = repo.open_run("1")
    repo.close_run(run, "partial", 2, 1, 3, "bilan")
    assert pg.query("SELECT extractor_version, status, pages_extracted, pages_failed, pages_skipped, notes, "
                    "finished_at IS NOT NULL FROM staging.extract_run WHERE id = %s",
                    (run,)) == [("1", "partial", 2, 1, 3, "bilan", True)]


def test_verrou_une_seule_extraction(pg):
    first = PgTransformerRepository(pg.transformer)
    assert first.try_lock()
    with pg.connect_transformer() as other:
        assert not PgTransformerRepository(other).try_lock()  # verrou occupé par l'autre connexion
    pg.transformer.close()  # fin de la connexion : verrou libéré par le serveur
    with pg.connect_transformer() as again:
        assert PgTransformerRepository(again).try_lock()


def test_connexion_sans_autocommit_refusee(pg):
    with pg.connect_transformer() as conn:
        conn.autocommit = False
        with pytest.raises(ValueError, match="autocommit"):
            PgTransformerRepository(conn)


def test_categorie_connue_du_collecteur(pg):
    # Information « nouvelle catégorie » de l'ingestion (décision 014) : lecture de raw.raw_page
    from books.collector.repository import PgRepository
    pg.add_page(COMPLETE, node="10000000001", status="invalid")  # quel que soit le statut
    repo = PgRepository(pg.owner)
    assert repo.known_category("10000000001") is True
    assert repo.known_category("10000000002") is False


def observation(pg, page_id):
    return pg.query("SELECT extract_run_id, display_name, short_name FROM staging.category_observation "
                    "WHERE raw_page_id = %s", (page_id,))


def test_observation_de_categorie_ecrite_remplacee_supprimee(pg):
    page = pg.add_page(COMPLETE)
    repo = PgTransformerRepository(pg.transformer)
    run1 = repo.open_run("1")
    repo.save_extraction(run1, page, parsed())
    assert observation(pg, page) == [(run1, "Catégorie d'exemple - ebooks", "Catégorie d'exemple")]
    run2 = repo.open_run("2")
    repo.save_extraction(run2, page, parsed(display="Nom changé d'exemple", short=None))
    assert observation(pg, page) == [(run2, "Nom changé d'exemple", None)]  # remplacée, nom non lu : NULL
    repo.save_failure(repo.open_run("3"), page, "parse_failed", "motif")
    assert observation(pg, page) == []  # page en échec : plus d'observation


# --- Fiches produit (migration 007, décision 015) -------------------------------------------------------------

def product_rows(pg, page_id):
    """Nombre de lignes de la page dans chaque table de fiche, et exécutions distinctes."""
    counts = {}
    for table in ("product_observation", "product_format", "product_sales_rank", "product_rating_share"):
        counts[table] = pg.query(f"SELECT count(*), array_agg(DISTINCT extract_run_id) FROM staging.{table} "
                                 "WHERE raw_page_id = %s", (page_id,))[0]
    return counts


def test_ecriture_d_une_fiche(pg):
    page = pg.add_page(FICHE, page_type="product")
    repo = PgTransformerRepository(pg.transformer)
    run = repo.open_run("3")
    repo.save_product(run, page, parse_product_page(FICHE))
    assert pg.query("SELECT extract_run_id, status, error_message, entry_count FROM staging.page_extraction "
                    "WHERE raw_page_id = %s", (page,)) == [(run, "ok", None, 1)]
    assert product_rows(pg, page) == {"product_observation": (1, [run]), "product_format": (4, [run]),
                                      "product_sales_rank": (4, [run]), "product_rating_share": (5, [run])}
    # Valeurs relues telles quelles ; empreintes acceptées par la base (elle les recalcule dans ses contraintes)
    assert pg.query("SELECT rating, review_count, file_size_value, file_size_unit, has_aplus "
                    "FROM staging.product_observation WHERE raw_page_id = %s",
                    (page,)) == [(Decimal("4.4"), 1234, Decimal("1.2"), "MB", True)]


def test_fiche_mise_a_part_puis_changement_de_version(pg):
    page = pg.add_page(FICHE, page_type="product")
    repo = PgTransformerRepository(pg.transformer)
    run = repo.open_run("3")
    repo.save_skipped(run, page, "format papier")
    assert pg.query("SELECT status, error_message, entry_count FROM staging.page_extraction WHERE raw_page_id = %s",
                    (page,)) == [("skipped", "format papier", 0)]
    assert repo.pages_to_extract("3", force=False) == []  # pas relue par la même version
    assert repo.count_up_to_date("3") == (0, 1)
    assert [p.id for p in repo.pages_to_extract("4", force=False)] == [page]  # reprise au changement de version


def test_reextraction_d_une_fiche_remplace_ses_lignes_et_echec_les_supprime(pg):
    page = pg.add_page(FICHE, page_type="product")
    repo = PgTransformerRepository(pg.transformer)
    repo.save_product(repo.open_run("3"), page, parse_product_page(FICHE))
    run2 = repo.open_run("4")
    repo.save_product(run2, page, parse_product_page(FICHE))
    assert {t: v[1] for t, v in product_rows(pg, page).items()} == {
        "product_observation": [run2], "product_format": [run2], "product_sales_rank": [run2],
        "product_rating_share": [run2]}
    repo.save_failure(repo.open_run("5"), page, "parse_failed", "forme nouvelle")
    assert {t: v[0] for t, v in product_rows(pg, page).items()} == {
        "product_observation": 0, "product_format": 0, "product_sales_rank": 0, "product_rating_share": 0}


def test_fiche_mise_a_part_apres_extraction_perd_ses_lignes(pg):
    page = pg.add_page(FICHE, page_type="product")
    repo = PgTransformerRepository(pg.transformer)
    repo.save_product(repo.open_run("3"), page, parse_product_page(FICHE))
    repo.save_skipped(repo.open_run("4"), page, "format papier")
    assert sum(v[0] for v in product_rows(pg, page).values()) == 0
