"""Lectures et écritures en base de l'extracteur des rapports Amazon Ads (décision 018, lot B), avec les seuls droits
de books_transformer (migration 012) : lecture de raw.ads_report_file ; dans staging, ajout et suppression des lignes,
remplacement limité de ads_file_extraction, clôture limitée de ads_extract_run ; codes par mapping.code_for.

Les textes ne sont transmis qu'à mapping.code_for, toujours en paramètres liés (décision 019, section 6) : la requête
ne contient jamais le texte, qui ne peut donc pas être recopié dans un journal d'erreur du serveur.
"""

from collections import defaultdict
from dataclasses import dataclass
from datetime import date, time
from typing import Protocol

import psycopg

from books.ads.parsing import MEASURES, ParsedReport

# Numéro du verrou consultatif de l'extracteur des rapports, distinct de celui des pages (4_211_011_005)
LOCK_KEY = 4_211_011_012
# Requête d'obtention d'un code : la seule qui reçoive un texte, toujours en paramètre lié
CODE_SQL = "SELECT mapping.code_for(%s, %s)"
MEASURE_COLUMNS = [name for name, _ in MEASURES.values()]
FAILED = ("parse_failed", "integrity_failed")


@dataclass(frozen=True)
class ReportFileRef:
    """Un fichier RAW de rapport à extraire."""
    id: int
    lot: str
    original_name: str
    storage_path: str
    content_sha256: str
    content_bytes: int
    report_type: str
    export_date: date | None  # horodatage du nom, pour mémoire : jamais utilisé dans un calcul
    export_time: time | None

    @property
    def label(self) -> str:
        return f"{self.lot}/{self.original_name}"


class AdsTransformerRepository(Protocol):
    def try_lock(self) -> bool: ...

    def open_run(self, extractor_version: str) -> int: ...

    def files_to_extract(self, extractor_version: str, force: bool) -> list[ReportFileRef]: ...

    def count_up_to_date(self, extractor_version: str) -> int: ...

    def known_failures(self, extractor_version: str, exclude: list[int]) -> list[str]: ...

    def out_of_scope(self) -> int: ...

    def save_report(self, run_id: int, file_id: int, report: ParsedReport) -> None: ...

    def save_no_activity(self, run_id: int, file_id: int, unknown_columns: list[str]) -> None: ...

    def save_failure(self, run_id: int, file_id: int, status: str, message: str) -> None: ...

    def close_run(self, run_id: int, status: str, files_ok: int, files_no_activity: int, files_failed: int,
                  notes: str) -> None: ...

    def export_files(self, last_days: list[date]) -> list[tuple]: ...

    def day_totals(self, file_id: int, report_type: str) -> dict: ...

    def borrows_or_royalties_seen(self) -> bool | None: ...


class PgAdsTransformerRepository:
    """Connexion en autocommit ; chaque fichier est écrit dans sa propre transaction."""

    def __init__(self, conn: psycopg.Connection) -> None:
        if not conn.autocommit:
            raise ValueError("PgAdsTransformerRepository exige une connexion en autocommit.")
        self.conn = conn

    def try_lock(self) -> bool:
        (taken,) = self.conn.execute("SELECT pg_try_advisory_lock(%s)", (LOCK_KEY,)).fetchone()
        return taken

    def open_run(self, extractor_version: str) -> int:
        (run_id,) = self.conn.execute(
            "INSERT INTO staging.ads_extract_run (extractor_version) VALUES (%s) RETURNING id", (extractor_version,)
        ).fetchone()
        return run_id

    def files_to_extract(self, extractor_version: str, force: bool) -> list[ReportFileRef]:
        """Fichiers RAW ok jamais extraits, ou extraits par une autre version ; tous si force. Un fichier déjà extrait
        par cette version ne l'est pas de nouveau, quel que soit son statut : son échec reste signalé au bilan."""
        rows = self.conn.execute(
            """
            SELECT f.id, f.lot, f.original_name, f.storage_path, f.content_sha256, f.content_bytes,
                   f.report_type, f.export_date, f.export_time
              FROM raw.ads_report_file f
              LEFT JOIN staging.ads_file_extraction e ON e.ads_report_file_id = f.id
              LEFT JOIN staging.ads_extract_run r ON r.id = e.extract_run_id
             WHERE f.status = 'ok'
               AND (%(force)s OR e.ads_report_file_id IS NULL OR r.extractor_version <> %(version)s)
             ORDER BY f.id
            """,
            {"force": force, "version": extractor_version},
        ).fetchall()
        return [ReportFileRef(*row) for row in rows]

    def count_up_to_date(self, extractor_version: str) -> int:
        (n,) = self.conn.execute(
            """
            SELECT count(*) FROM staging.ads_file_extraction e
              JOIN staging.ads_extract_run r ON r.id = e.extract_run_id
             WHERE r.extractor_version = %s
            """,
            (extractor_version,),
        ).fetchone()
        return n

    def known_failures(self, extractor_version: str, exclude: list[int]) -> list[str]:
        """Échecs déjà enregistrés par cette version (fichiers non réextraits) : « lot/nom : motif »."""
        rows = self.conn.execute(
            """
            SELECT f.lot || '/' || f.original_name || ' : ' || e.status || ' : ' || e.error_message
              FROM staging.ads_file_extraction e
              JOIN staging.ads_extract_run r ON r.id = e.extract_run_id
              JOIN raw.ads_report_file f ON f.id = e.ads_report_file_id
             WHERE r.extractor_version = %s AND e.status = ANY (%s::text[]) AND NOT (f.id = ANY (%s::bigint[]))
             ORDER BY f.id
            """,
            (extractor_version, list(FAILED), exclude),
        ).fetchall()
        return [row[0] for row in rows]

    def out_of_scope(self) -> int:
        """Fichiers RAW invalid : jamais extraits (leur motif est dans RAW)."""
        (n,) = self.conn.execute("SELECT count(*) FROM raw.ads_report_file WHERE status <> 'ok'").fetchone()
        return n

    def _code(self, cache: dict, nature: str, key: str | None) -> int | None:
        if key is None:
            return None
        if (nature, key) not in cache:
            (cache[(nature, key)],) = self.conn.execute(CODE_SQL, (nature, key)).fetchone()
        return cache[(nature, key)]

    def save_report(self, run_id: int, file_id: int, report: ParsedReport) -> None:
        """Remplace les lignes du fichier, dans une transaction : suppression, ligne d'extraction, codes, lignes.
        Les codes sont obtenus dans la même transaction : une erreur n'en laisse aucun (décision 019, section 6)."""
        cache: dict = {}
        with self.conn.transaction():
            self._delete_rows(file_id)
            self._set_extraction(run_id, file_id, "ok", None, len(report.rows), report.first_day, report.last_day,
                                 report.unknown_columns)
            if report.report_type == "advertised_product":
                values = [
                    (file_id, run_id, r.day, r.campaign_id, r.ad_group_id, r.advertised_product_id,
                     self._code(cache, "campaign", r.campaign_name), self._code(cache, "ad_group", r.ad_group_name),
                     self._code(cache, "product_title", r.product_title),
                     *(r.measures[m] for m in MEASURE_COLUMNS))
                    for r in report.rows]
                columns = ("ads_report_file_id, extract_run_id, day, campaign_id, ad_group_id, advertised_product_id, "
                           "campaign_name_code, ad_group_name_code, product_title_code")
                table = "staging.ads_product_day"
            else:
                values = [
                    (file_id, run_id, r.day, r.campaign_id, r.ad_group_id, r.target_id, r.target_type, r.match_type,
                     self._code(cache, "search_term", r.search_term), self._code(cache, "targeting", r.targeting),
                     self._code(cache, "campaign", r.campaign_name), self._code(cache, "ad_group", r.ad_group_name),
                     *(r.measures[m] for m in MEASURE_COLUMNS))
                    for r in report.rows]
                columns = ("ads_report_file_id, extract_run_id, day, campaign_id, ad_group_id, target_id, target_type, "
                           "match_type, search_term_code, targeting_code, campaign_name_code, ad_group_name_code")
                table = "staging.ads_search_term_day"
            placeholders = ", ".join(["%s"] * len(values[0]))
            with self.conn.cursor() as cur:
                cur.executemany(f"INSERT INTO {table} ({columns}, {', '.join(MEASURE_COLUMNS)}) "
                                f"VALUES ({placeholders})", values)

    def save_no_activity(self, run_id: int, file_id: int, unknown_columns: list[str]) -> None:
        with self.conn.transaction():
            self._delete_rows(file_id)
            self._set_extraction(run_id, file_id, "no_activity", None, 0, None, None, unknown_columns)

    def save_failure(self, run_id: int, file_id: int, status: str, message: str) -> None:
        """Fichier en échec : ses anciennes lignes sont supprimées (jamais deux versions mélangées)."""
        with self.conn.transaction():
            self._delete_rows(file_id)
            self._set_extraction(run_id, file_id, status, message, 0, None, None, [])

    def close_run(self, run_id: int, status: str, files_ok: int, files_no_activity: int, files_failed: int,
                  notes: str) -> None:
        self.conn.execute(
            """
            UPDATE staging.ads_extract_run
               SET finished_at = now(), status = %s, files_ok = %s, files_no_activity = %s, files_failed = %s,
                   notes = %s
             WHERE id = %s
            """,
            (status, files_ok, files_no_activity, files_failed, notes, run_id),
        )

    def export_files(self, last_days: list[date]) -> list[tuple]:
        """Fichiers extraits ok des exports de ces dernières dates de données : (dernière date, type, identifiant,
        lot/nom, première date), pour chaque export et chaque type du dernier ingéré au premier (décision 018,
        note du 9 novembre 2026 : le nom n'intervient pas)."""
        return self.conn.execute(
            """
            SELECT e.last_day, f.report_type, f.id, f.lot || '/' || f.original_name, e.first_day
              FROM raw.ads_report_file f
              JOIN staging.ads_file_extraction e ON e.ads_report_file_id = f.id
             WHERE e.status = 'ok' AND e.last_day = ANY (%s::date[])
             ORDER BY e.last_day, f.report_type, f.ingested_at DESC, f.id DESC
            """,
            (last_days,),
        ).fetchall()

    def day_totals(self, file_id: int, report_type: str) -> dict:
        """Par jour, pour chaque mesure : (somme des valeurs connues, au moins une cellule vide ?)."""
        table = "staging.ads_product_day" if report_type == "advertised_product" else "staging.ads_search_term_day"
        sums = ", ".join(f"sum({m}), bool_or({m} IS NULL)" for m in MEASURE_COLUMNS)
        rows = self.conn.execute(
            f"SELECT day, {sums} FROM {table} WHERE ads_report_file_id = %s GROUP BY day ORDER BY day", (file_id,)
        ).fetchall()
        totals = defaultdict(dict)
        for row in rows:
            for i, m in enumerate(MEASURE_COLUMNS):
                totals[row[0]][m] = (row[1 + 2 * i], row[2 + 2 * i])
        return dict(totals)

    def borrows_or_royalties_seen(self) -> bool | None:
        """Une valeur non nulle d'emprunts ou de redevances a-t-elle été vue ? None si aucun fichier n'est extrait."""
        (any_ok, seen) = self.conn.execute(
            """
            SELECT EXISTS (SELECT 1 FROM staging.ads_file_extraction WHERE status = 'ok'),
                   EXISTS (SELECT 1 FROM staging.ads_product_day WHERE borrows > 0 OR royalties > 0)
                   OR EXISTS (SELECT 1 FROM staging.ads_search_term_day WHERE borrows > 0 OR royalties > 0)
            """
        ).fetchone()
        return seen if any_ok else None

    def _delete_rows(self, file_id: int) -> None:
        for table in ("ads_product_day", "ads_search_term_day"):
            self.conn.execute(f"DELETE FROM staging.{table} WHERE ads_report_file_id = %s", (file_id,))

    def _set_extraction(self, run_id, file_id, status, message, count, first_day, last_day, unknown) -> None:
        self.conn.execute(
            """
            INSERT INTO staging.ads_file_extraction (ads_report_file_id, extract_run_id, status, error_message,
                                                     row_count, first_day, last_day, unknown_columns)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (ads_report_file_id) DO UPDATE
               SET extract_run_id = EXCLUDED.extract_run_id, status = EXCLUDED.status,
                   error_message = EXCLUDED.error_message, row_count = EXCLUDED.row_count,
                   first_day = EXCLUDED.first_day, last_day = EXCLUDED.last_day,
                   unknown_columns = EXCLUDED.unknown_columns, extracted_at = now()
            """,
            (file_id, run_id, status, message, count, first_day, last_day, unknown),
        )
