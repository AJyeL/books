"""Écritures en base de la couche RAW, avec les seuls droits de books_collector (migration 002) :
INSERT dans collect_run et raw_page, UPDATE limité aux colonnes de clôture de collect_run.
"""

from dataclasses import dataclass
from datetime import datetime
from typing import Protocol

import psycopg

from books.collector.storage import StoredFile
from books.collector.targets import PageRequest


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


class Repository(Protocol):
    def open_run(self, collector_version: str) -> RunInfo: ...

    def record_page(self, run_id: int, record: PageRecord) -> int: ...

    def close_run(self, run_id: int, status: str, pages_ok: int, pages_failed: int, notes: str) -> None: ...


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
                content_sha256, content_bytes, storage_path, capture_method)
            VALUES (%s, 'bestseller_list', %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            RETURNING id
            """,
            (
                run_id, record.request.node, record.request.list_type, record.request.page_number,
                record.request.url, record.final_url, record.fetched_at, record.http_status,
                record.fetch_status, record.error_message,
                stored.sha256 if stored else None,
                stored.size if stored else None,
                stored.relative_path if stored else None,
                record.capture_method,
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
