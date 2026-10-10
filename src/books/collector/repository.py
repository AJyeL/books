"""Écritures en base de la couche RAW, avec les seuls droits de books_collector (migration 002) :
INSERT dans collect_run et raw_page, UPDATE limité aux colonnes de clôture de collect_run.
"""

from dataclasses import dataclass
from datetime import datetime
from typing import Protocol

import psycopg

from books.collector.storage import StoredFile
from books.amazon.ranking_page import PageRequest


@dataclass(frozen=True)
class RunInfo:
    id: int
    started_at: datetime


@dataclass(frozen=True)
class PageRecord:
    """Une ligne de raw.raw_page (page de classement)."""

    request: PageRequest
    fetched_at: datetime
    fetch_status: str
    capture_method: str  # obligatoire pour toute nouvelle ligne (migration 004)
    error_message: str | None = None
    http_status: int | None = None
    final_url: str | None = None
    stored: StoredFile | None = None
    metadata: StoredFile | None = None  # JSON d'une capture extension-dom (migration 004)
    # Adresse enregistrée dans requested_url : l'adresse affichée d'une capture (décision 008),
    # sinon l'adresse construite à partir de la demande
    requested_url: str | None = None


class Repository(Protocol):
    def open_run(self, collector_version: str) -> RunInfo: ...

    def record_page(self, run_id: int, record: PageRecord) -> int: ...

    def close_run(self, run_id: int, status: str, pages_ok: int, pages_failed: int, notes: str) -> None: ...

    def find_capture(self, content_sha256: str) -> int | None: ...

    def known_category(self, node: str) -> bool: ...


class PgRepository:
    """Connexion en autocommit : chaque écriture est validée immédiatement,
    et une tournée interrompue garde la trace des pages déjà traitées."""

    def __init__(self, conn: psycopg.Connection) -> None:
        if not conn.autocommit:
            raise ValueError("PgRepository exige une connexion en autocommit.")
        self.conn = conn

    def open_run(self, collector_version: str) -> RunInfo:
        run_id, started_at = self.conn.execute(
            "INSERT INTO raw.collect_run (collector_version) VALUES (%s) RETURNING id, started_at",
            (collector_version,),
        ).fetchone()
        return RunInfo(id=run_id, started_at=started_at)

    def record_page(self, run_id: int, record: PageRecord) -> int:
        stored = record.stored
        (page_id,) = self.conn.execute(
            """
            INSERT INTO raw.raw_page (
                run_id, page_type, category_node, list_type, page_number,
                requested_url, final_url, fetched_at, http_status, fetch_status, error_message,
                content_sha256, content_bytes, storage_path, capture_method, metadata_path, metadata_sha256)
            VALUES (%s, 'bestseller_list', %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            RETURNING id
            """,
            (
                run_id, record.request.node, record.request.list_type, record.request.page_number,
                record.requested_url or record.request.url, record.final_url, record.fetched_at, record.http_status,
                record.fetch_status, record.error_message,
                stored.sha256 if stored else None,
                stored.size if stored else None,
                stored.relative_path if stored else None,
                record.capture_method,
                record.metadata.relative_path if record.metadata else None,
                record.metadata.sha256 if record.metadata else None,
            ),
        ).fetchone()
        return page_id

    def close_run(self, run_id: int, status: str, pages_ok: int, pages_failed: int, notes: str) -> None:
        self.conn.execute(
            """
            UPDATE raw.collect_run
               SET finished_at = now(), status = %s, pages_ok = %s, pages_failed = %s, notes = %s
             WHERE id = %s
            """,
            (status, pages_ok, pages_failed, notes, run_id),
        )

    def find_capture(self, content_sha256: str) -> int | None:
        """Identifiant de la ligne d'une capture extension-dom déjà déposée avec cette empreinte, sinon None.
        Même condition que l'index unique partiel de la migration 004, qui sert donc à cette recherche."""
        row = self.conn.execute(
            "SELECT id FROM raw.raw_page WHERE capture_method = 'extension-dom' AND content_sha256 = %s",
            (content_sha256,),
        ).fetchone()
        return row[0] if row else None

    def known_category(self, node: str) -> bool:
        """La catégorie a-t-elle déjà au moins une page dans RAW, quel que soit son statut (décision 014) ?
        Lecture seule (droit SELECT de books_collector, migration 002)."""
        (known,) = self.conn.execute(
            "SELECT EXISTS (SELECT 1 FROM raw.raw_page WHERE category_node = %s)", (node,)
        ).fetchone()
        return known
