"""Tests de books.collector.repository contre un PostgreSQL 17 jetable, sous le rôle books_collector.

Une fiche produit (décision 015) est déposée avec page_type = 'product' et son ASIN, sans catégorie, liste ni page :
la contrainte de la migration 001 l'exige, et books_collector a le droit d'INSERT sur raw.raw_page (migration 002).
"""

from datetime import UTC, datetime
from pathlib import PurePosixPath

from books.amazon.product_page import ProductRequest
from books.amazon.ranking_page import PageRequest
from books.collector.repository import PageRecord, PgRepository
from books.collector.storage import store_raw

CAPTURED = datetime(2026, 10, 6, 20, 0, 50, tzinfo=UTC)


def deposer(pg, request, name):
    repo = PgRepository(pg.connect_collector())
    run = repo.open_run("test")
    html = store_raw(pg.raw_dir, PurePosixPath(f"amazon_fr/test/{name}.html.gz"), f"<html>{name}</html>".encode())
    meta = store_raw(pg.raw_dir, PurePosixPath(f"amazon_fr/test/{name}.json.gz"), b"{}")
    page_id = repo.record_page(run.id, PageRecord(
        request=request, fetched_at=CAPTURED, fetch_status="ok", capture_method="extension-dom",
        stored=html, metadata=meta, requested_url=request.url))
    return repo, page_id


def test_depot_d_une_fiche(pg):
    repo, page_id = deposer(pg, ProductRequest("B0FAUX0001"), "fiche")
    assert pg.query("SELECT page_type, asin, category_node, list_type, page_number, requested_url, fetch_status, "
                    "capture_method FROM raw.raw_page WHERE id = %s", (page_id,)) == [
        ("product", "B0FAUX0001", None, None, None, "https://www.amazon.fr/dp/B0FAUX0001", "ok", "extension-dom")]
    # Une fiche ne fait connaître aucune catégorie
    assert not repo.known_category("10000000001")


def test_depot_d_une_page_de_classement_inchange(pg):
    repo, page_id = deposer(pg, PageRequest("10000000001", "free", 2), "classement")
    assert pg.query("SELECT page_type, asin, category_node, list_type, page_number FROM raw.raw_page "
                    "WHERE id = %s", (page_id,)) == [("bestseller_list", None, "10000000001", "free", 2)]
    assert repo.known_category("10000000001")
