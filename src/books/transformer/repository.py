"""Lectures et écritures en base de l'extracteur, avec les seuls droits de books_transformer (migration 005) :
lecture de raw ; dans staging, INSERT et DELETE sur ranking_entry, INSERT et UPDATE limité sur page_extraction,
INSERT et UPDATE des colonnes de clôture sur extract_run.
"""

from collections.abc import Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Protocol

import psycopg

from books.transformer.parsing import RankingEntry

# Numéro du verrou consultatif de l'extracteur (pg_try_advisory_lock) : une seule extraction à la fois.
# Valeur arbitraire, propre à B.O.O.K.S. ; libéré par le serveur à la fin de la connexion.
LOCK_KEY = 4_211_011_005

# Périmètre de l'extracteur (décision 011, section 1). IS NOT DISTINCT FROM : une méthode NULL (lignes antérieures
# à la migration 004) est hors périmètre, et non « inconnue » ; NOT (…) reste donc vrai pour elle.
SCOPE = ("rp.page_type = 'bestseller_list' AND rp.fetch_status = 'ok' "
         "AND rp.capture_method IS NOT DISTINCT FROM 'extension-dom'")


@dataclass(frozen=True)
class RawPageRef:
    """Une page RAW à extraire : de quoi vérifier son fichier, et la nommer dans le bilan."""

    id: int
    storage_path: str
    content_sha256: str
    content_bytes: int
    category_node: str
    list_type: str
    page_number: int
    fetched_at: datetime

    @property
    def label(self) -> str:
        stamp = self.fetched_at.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")  # horodatages en UTC
        return f"{self.category_node} {self.list_type} p{self.page_number} {stamp} (page RAW {self.id})"


class TransformerRepository(Protocol):
    def try_lock(self) -> bool: ...

    def open_run(self, extractor_version: str) -> int: ...

    def pages_to_extract(self, extractor_version: str, force: bool) -> list[RawPageRef]: ...

    def count_up_to_date(self, extractor_version: str) -> int: ...

    def out_of_scope(self) -> dict[str, int]: ...

    def save_extraction(self, run_id: int, raw_page_id: int, entries: Sequence[RankingEntry]) -> None: ...

    def save_failure(self, run_id: int, raw_page_id: int, status: str, message: str) -> None: ...

    def close_run(self, run_id: int, status: str, pages_extracted: int, pages_failed: int, notes: str) -> None: ...


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
        """Pages du périmètre jamais extraites, extraites par une autre version, ou en échec ; toutes si force.
        Une page en échec est reprise à chaque exécution : son anomalie reste visible tant qu'elle n'est pas résolue."""
        rows = self.conn.execute(
            f"""
            SELECT rp.id, rp.storage_path, rp.content_sha256, rp.content_bytes,
                   rp.category_node, rp.list_type, rp.page_number, rp.fetched_at
              FROM raw.raw_page rp
              LEFT JOIN staging.page_extraction pe ON pe.raw_page_id = rp.id
              LEFT JOIN staging.extract_run er ON er.id = pe.extract_run_id
             WHERE {SCOPE}
               AND (%(force)s OR pe.raw_page_id IS NULL OR er.extractor_version <> %(version)s
                    OR pe.status <> 'ok')
             ORDER BY rp.id
            """,
            {"force": force, "version": extractor_version},
        ).fetchall()
        return [RawPageRef(*row) for row in rows]

    def count_up_to_date(self, extractor_version: str) -> int:
        """Pages du périmètre déjà extraites avec succès par cette version."""
        (count,) = self.conn.execute(
            f"""
            SELECT count(*)
              FROM raw.raw_page rp
              JOIN staging.page_extraction pe ON pe.raw_page_id = rp.id
              JOIN staging.extract_run er ON er.id = pe.extract_run_id
             WHERE {SCOPE} AND pe.status = 'ok' AND er.extractor_version = %s
            """,
            (extractor_version,),
        ).fetchone()
        return count

    def out_of_scope(self) -> dict[str, int]:
        """Pages RAW hors périmètre, comptées par motif (décision 011, section 1)."""
        rows = self.conn.execute(
            f"""
            SELECT CASE WHEN rp.page_type <> 'bestseller_list' THEN 'type ' || rp.page_type
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

    def save_extraction(self, run_id: int, raw_page_id: int, entries: Sequence[RankingEntry]) -> None:
        """Remplace les lignes de la page, dans une transaction, dans l'ordre imposé par la clé composée de la
        migration 005 : suppression des anciennes lignes, mise à jour de page_extraction, insertion des nouvelles."""
        with self.conn.transaction():
            self._delete_entries(raw_page_id)
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

    def save_failure(self, run_id: int, raw_page_id: int, status: str, message: str) -> None:
        """Page en échec : ses anciennes lignes sont supprimées (jamais deux versions mélangées), aucune n'est écrite."""
        with self.conn.transaction():
            self._delete_entries(raw_page_id)
            self._set_page(run_id, raw_page_id, status, message, 0)

    def close_run(self, run_id: int, status: str, pages_extracted: int, pages_failed: int, notes: str) -> None:
        self.conn.execute(
            """
            UPDATE staging.extract_run
               SET finished_at = now(), status = %s, pages_extracted = %s, pages_failed = %s, notes = %s
             WHERE id = %s
            """,
            (status, pages_extracted, pages_failed, notes, run_id),
        )

    def _delete_entries(self, raw_page_id: int) -> None:
        self.conn.execute("DELETE FROM staging.ranking_entry WHERE raw_page_id = %s", (raw_page_id,))

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
