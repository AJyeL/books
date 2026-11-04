"""Écritures en base des rapports Amazon Ads dans RAW, avec les seuls droits de books_collector (migration 011) :
INSERT dans ads_ingest_run et ads_report_file, UPDATE limité aux colonnes de clôture de ads_ingest_run.
"""

from dataclasses import dataclass
from datetime import date, datetime, time
from typing import Protocol

import psycopg

from books.collector.storage import StoredFile


@dataclass(frozen=True)
class AdsRunInfo:
    id: int
    started_at: datetime


@dataclass(frozen=True)
class ReportRecord:
    """Une ligne de raw.ads_report_file."""

    lot: str
    original_name: str
    stored: StoredFile
    status: str
    reason: str | None
    report_type: str | None
    export_date: date | None
    export_time: time | None


class AdsRepository(Protocol):
    def open_run(self, collector_version: str) -> AdsRunInfo: ...

    def record_report(self, run_id: int, record: ReportRecord) -> int: ...

    def close_run(self, run_id: int, status: str, files_ok: int, files_invalid: int, notes: str) -> None: ...

    def find_report(self, content_sha256: str) -> int | None: ...


class PgAdsRepository:
    """Connexion en autocommit : chaque fichier déposé est validé immédiatement."""

    def __init__(self, conn: psycopg.Connection) -> None:
        if not conn.autocommit:
            raise ValueError("PgAdsRepository exige une connexion en autocommit.")
        self.conn = conn

    def open_run(self, collector_version: str) -> AdsRunInfo:
        run_id, started_at = self.conn.execute(
            "INSERT INTO raw.ads_ingest_run (collector_version) VALUES (%s) RETURNING id, started_at",
            (collector_version,),
        ).fetchone()
        return AdsRunInfo(id=run_id, started_at=started_at)

    def record_report(self, run_id: int, record: ReportRecord) -> int:
        (report_id,) = self.conn.execute(
            """
            INSERT INTO raw.ads_report_file (
                run_id, lot, original_name, content_sha256, content_bytes, storage_path,
                report_type, export_date, export_time, status, reason)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            RETURNING id
            """,
            (run_id, record.lot, record.original_name, record.stored.sha256, record.stored.size,
             record.stored.relative_path, record.report_type, record.export_date, record.export_time,
             record.status, record.reason),
        ).fetchone()
        return report_id

    def close_run(self, run_id: int, status: str, files_ok: int, files_invalid: int, notes: str) -> None:
        self.conn.execute(
            """
            UPDATE raw.ads_ingest_run
               SET finished_at = now(), status = %s, files_ok = %s, files_invalid = %s, notes = %s
             WHERE id = %s
            """,
            (status, files_ok, files_invalid, notes, run_id),
        )

    def find_report(self, content_sha256: str) -> int | None:
        """Identifiant du fichier déjà déposé avec cette empreinte (index unique de la migration 011), sinon None."""
        row = self.conn.execute(
            "SELECT id FROM raw.ads_report_file WHERE content_sha256 = %s", (content_sha256,)
        ).fetchone()
        return row[0] if row else None
