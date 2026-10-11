"""Lectures et écritures en base de l'extracteur, avec les seuls droits de books_transformer (migrations 005 à 007) :
lecture de raw ; dans staging, INSERT et DELETE sur les tables de lignes (classements, catégories, fiches), INSERT et
UPDATE limité sur page_extraction, INSERT et UPDATE des colonnes de clôture sur extract_run.
"""

from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Protocol

import psycopg

from books.transformer.parsing import ParsedPage
from books.transformer.product_parsing import ParsedProduct

# Numéro du verrou consultatif de l'extracteur (pg_try_advisory_lock) : une seule extraction à la fois.
# Valeur arbitraire, propre à B.O.O.K.S. ; libéré par le serveur à la fin de la connexion.
LOCK_KEY = 4_211_011_005

# Périmètre de l'extracteur (décision 011, section 1 ; fiches produit depuis la décision 015, étape D).
# IS NOT DISTINCT FROM : une méthode NULL (lignes antérieures à la migration 004) est hors périmètre, et non
# « inconnue » ; NOT (…) reste donc vrai pour elle.
SCOPE = ("rp.page_type IN ('bestseller_list', 'product') AND rp.fetch_status = 'ok' "
         "AND rp.capture_method IS NOT DISTINCT FROM 'extension-dom'")
# Statuts d'une page traitée par une version de l'extracteur, sans anomalie : extraite, ou mise à part (fiche papier)
DONE = ("ok", "skipped")

# Tables de lignes d'une page, supprimées avant toute réécriture (jamais deux versions mélangées)
PAGE_TABLES = ("ranking_entry", "category_observation", "product_format", "product_sales_rank",
               "product_rating_share", "product_observation")


@dataclass(frozen=True)
class RawPageRef:
    """Une page RAW à extraire : de quoi vérifier son fichier, et la nommer dans le bilan."""

    id: int
    storage_path: str
    content_sha256: str
    content_bytes: int
    category_node: str | None
    list_type: str | None
    page_number: int | None
    fetched_at: datetime
    page_type: str = "bestseller_list"
    asin: str | None = None

    @property
    def is_product(self) -> bool:
        return self.page_type == "product"

    @property
    def label(self) -> str:
        stamp = self.fetched_at.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")  # horodatages en UTC
        if self.is_product:
            return f"fiche {self.asin} {stamp} (page RAW {self.id})"
        return f"{self.category_node} {self.list_type} p{self.page_number} {stamp} (page RAW {self.id})"


class TransformerRepository(Protocol):
    def try_lock(self) -> bool: ...

    def open_run(self, extractor_version: str) -> int: ...

    def pages_to_extract(self, extractor_version: str, force: bool) -> list[RawPageRef]: ...

    def count_up_to_date(self, extractor_version: str) -> tuple[int, int]: ...

    def out_of_scope(self) -> dict[str, int]: ...

    def save_extraction(self, run_id: int, raw_page_id: int, page: ParsedPage) -> None: ...

    def save_product(self, run_id: int, raw_page_id: int, product: ParsedProduct) -> None: ...

    def save_skipped(self, run_id: int, raw_page_id: int, reason: str) -> None: ...

    def save_failure(self, run_id: int, raw_page_id: int, status: str, message: str) -> None: ...

    def close_run(self, run_id: int, status: str, pages_extracted: int, pages_failed: int, pages_skipped: int,
                  notes: str) -> None: ...


class PgTransformerRepository:
    """Connexion en autocommit : l'exécution est enregistrée dès son ouverture, et chaque page est écrite dans
    sa propre transaction (entièrement ou pas du tout, décision 011, section 5)."""

    def __init__(self, conn: psycopg.Connection) -> None:
        if not conn.autocommit:
            raise ValueError("PgTransformerRepository exige une connexion en autocommit.")
        self.conn = conn

    def try_lock(self) -> bool:
        (taken,) = self.conn.execute("SELECT pg_try_advisory_lock(%s)", (LOCK_KEY,)).fetchone()
        return taken

    def open_run(self, extractor_version: str) -> int:
        (run_id,) = self.conn.execute(
            "INSERT INTO staging.extract_run (extractor_version) VALUES (%s) RETURNING id", (extractor_version,)
        ).fetchone()
        return run_id

    def pages_to_extract(self, extractor_version: str, force: bool) -> list[RawPageRef]:
        """Pages du périmètre jamais traitées, traitées par une autre version, ou en échec ; toutes si force.
        Une page en échec est reprise à chaque exécution : son anomalie reste visible tant qu'elle n'est pas résolue.
        Une fiche mise à part (skipped) par cette version ne l'est pas : elle sera reprise au changement de version."""
        rows = self.conn.execute(
            f"""
            SELECT rp.id, rp.storage_path, rp.content_sha256, rp.content_bytes,
                   rp.category_node, rp.list_type, rp.page_number, rp.fetched_at, rp.page_type, rp.asin
              FROM raw.raw_page rp
              LEFT JOIN staging.page_extraction pe ON pe.raw_page_id = rp.id
              LEFT JOIN staging.extract_run er ON er.id = pe.extract_run_id
             WHERE {SCOPE}
               AND (%(force)s OR pe.raw_page_id IS NULL OR er.extractor_version <> %(version)s
                    OR pe.status <> ALL (%(done)s))
             ORDER BY rp.id
            """,
            {"force": force, "version": extractor_version, "done": list(DONE)},
        ).fetchall()
        return [RawPageRef(*row) for row in rows]

    def count_up_to_date(self, extractor_version: str) -> tuple[int, int]:
        """Pages du périmètre déjà traitées par cette version : (extraites, mises à part)."""
        ok, skipped = self.conn.execute(
            f"""
            SELECT count(*) FILTER (WHERE pe.status = 'ok'), count(*) FILTER (WHERE pe.status = 'skipped')
              FROM raw.raw_page rp
              JOIN staging.page_extraction pe ON pe.raw_page_id = rp.id
              JOIN staging.extract_run er ON er.id = pe.extract_run_id
             WHERE {SCOPE} AND er.extractor_version = %s
            """,
            (extractor_version,),
        ).fetchone()
        return ok, skipped

    def out_of_scope(self) -> dict[str, int]:
        """Pages RAW hors périmètre, comptées par motif (décision 011, section 1)."""
        rows = self.conn.execute(
            f"""
            SELECT CASE WHEN rp.page_type NOT IN ('bestseller_list', 'product') THEN 'type ' || rp.page_type
                        WHEN rp.fetch_status <> 'ok' THEN 'statut ' || rp.fetch_status
                        WHEN rp.capture_method IS NULL THEN 'méthode non enregistrée'
                        ELSE 'méthode ' || rp.capture_method END AS motif,
                   count(*)
              FROM raw.raw_page rp
             WHERE NOT ({SCOPE})
             GROUP BY 1
             ORDER BY 1
            """
        ).fetchall()
        return dict(rows)

    def save_extraction(self, run_id: int, raw_page_id: int, page: ParsedPage) -> None:
        """Remplace les lignes et l'observation de catégorie de la page, dans une transaction, dans l'ordre imposé par
        les clés composées (migrations 005 et 006) : suppression des anciennes, mise à jour de page_extraction,
        insertion des nouvelles."""
        entries = page.entries
        with self.conn.transaction():
            self._delete_page_rows(raw_page_id)
            self._set_page(run_id, raw_page_id, "ok", None, len(entries))
            with self.conn.cursor() as cur:
                cur.executemany(
                    """
                    INSERT INTO staging.ranking_entry (
                        raw_page_id, extract_run_id, rank, asin, has_card, title, price_amount, currency,
                        rating, review_count, cover_url, ku_sticker_hint)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                    """,
                    [(raw_page_id, run_id, e.rank, e.asin, e.has_card, e.title, e.price_amount, e.currency,
                      e.rating, e.review_count, e.cover_url, e.ku_sticker_hint) for e in entries],
                )
            # Noms de la catégorie observés sur la page (décision 014) ; None : nom non lu
            self.conn.execute(
                "INSERT INTO staging.category_observation (raw_page_id, extract_run_id, display_name, short_name) "
                "VALUES (%s, %s, %s, %s)",
                (raw_page_id, run_id, page.display_name, page.short_name),
            )

    def save_product(self, run_id: int, raw_page_id: int, product: ParsedProduct) -> None:
        """Remplace l'observation et les lignes de détail d'une fiche, dans une transaction, dans l'ordre imposé par les
        clés composées (migration 007). Une fiche extraite compte une observation (entry_count = 1)."""
        p = product
        with self.conn.transaction():
            self._delete_page_rows(raw_page_id)
            self._set_page(run_id, raw_page_id, "ok", None, 1)
            self.conn.execute(
                """
                INSERT INTO staging.product_observation (
                    raw_page_id, extract_run_id, format_label, title, series_form, series_name, series_position,
                    series_total, publication_date, language, print_pages, file_size_value, file_size_unit, isbn13,
                    rating, review_count, cover_url, description_text, description_text_sha256, description_markup,
                    description_markup_sha256, has_aplus, breadcrumb)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (raw_page_id, run_id, p.format_label, p.title, p.series_form, p.series_name, p.series_position,
                 p.series_total, p.publication_date, p.language, p.print_pages, p.file_size_value, p.file_size_unit,
                 p.isbn13, p.rating, p.review_count, p.cover_url, p.description_text, p.description_text_sha256,
                 p.description_markup, p.description_markup_sha256, p.has_aplus, p.breadcrumb),
            )
            with self.conn.cursor() as cur:
                cur.executemany(
                    """
                    INSERT INTO staging.product_format (raw_page_id, extract_run_id, position, swatch_kind, label,
                        is_selected, linked_asin, price_amount, currency, price_qualifier, ku_borrow)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                    """,
                    [(raw_page_id, run_id, f.position, f.swatch_kind, f.label, f.is_selected, f.linked_asin,
                      f.price_amount, f.currency, f.price_qualifier, f.ku_borrow) for f in p.formats],
                )
                cur.executemany(
                    """
                    INSERT INTO staging.product_sales_rank (raw_page_id, extract_run_id, position, is_general, rank,
                        store, category_node, list_type)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                    """,
                    [(raw_page_id, run_id, r.position, r.is_general, r.rank, r.store, r.category_node, r.list_type)
                     for r in p.sales_ranks],
                )
                cur.executemany(
                    "INSERT INTO staging.product_rating_share (raw_page_id, extract_run_id, stars, percent) "
                    "VALUES (%s, %s, %s, %s)",
                    [(raw_page_id, run_id, s.stars, s.percent) for s in p.rating_shares],
                )

    def save_skipped(self, run_id: int, raw_page_id: int, reason: str) -> None:
        """Fiche mise à part (fiche papier) : ses anciennes lignes sont supprimées ; statut skipped avec son motif."""
        with self.conn.transaction():
            self._delete_page_rows(raw_page_id)
            self._set_page(run_id, raw_page_id, "skipped", reason, 0)

    def save_failure(self, run_id: int, raw_page_id: int, status: str, message: str) -> None:
        """Page en échec : ses anciennes lignes sont supprimées (jamais deux versions mélangées) ; rien n'est écrit."""
        with self.conn.transaction():
            self._delete_page_rows(raw_page_id)
            self._set_page(run_id, raw_page_id, status, message, 0)

    def close_run(self, run_id: int, status: str, pages_extracted: int, pages_failed: int, pages_skipped: int,
                  notes: str) -> None:
        self.conn.execute(
            """
            UPDATE staging.extract_run
               SET finished_at = now(), status = %s, pages_extracted = %s, pages_failed = %s, pages_skipped = %s,
                   notes = %s
             WHERE id = %s
            """,
            (status, pages_extracted, pages_failed, pages_skipped, notes, run_id),
        )

    def _delete_page_rows(self, raw_page_id: int) -> None:
        """Supprime toutes les lignes d'une page (classement, catégorie, fiche), avant la mise à jour de
        page_extraction : les clés composées refuseraient sinon le changement d'exécution."""
        for table in PAGE_TABLES:
            self.conn.execute(f"DELETE FROM staging.{table} WHERE raw_page_id = %s", (raw_page_id,))

    def _set_page(self, run_id: int, raw_page_id: int, status: str, message: str | None, count: int) -> None:
        self.conn.execute(
            """
            INSERT INTO staging.page_extraction (raw_page_id, extract_run_id, status, error_message, entry_count)
            VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (raw_page_id) DO UPDATE
               SET extract_run_id = EXCLUDED.extract_run_id, status = EXCLUDED.status,
                   error_message = EXCLUDED.error_message, entry_count = EXCLUDED.entry_count, extracted_at = now()
            """,
            (raw_page_id, run_id, status, message, count),
        )
