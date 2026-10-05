"""Déroulement d'une tournée de collecte (décisions 001, 002 et 004).

Pour chaque page demandée : obtenir, valider, déposer dans RAW (fichier + ligne raw_page).
Une page « blocked » ou « invalid » arrête la tournée (disjoncteur de la décision 002) ;
la logique de reprise des nuits suivantes n'est pas encore écrite.
"""

from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from books.collector.repository import PageRecord, Repository
from books.collector.sources import PageSource
from books.collector.storage import raw_relative_path, store_raw
from books.collector.targets import PageRequest
from books.collector.validation import FULL_LIST_SIZE, validate_bestseller_page

# Codes de sortie du collecteur (2 = configuration, dans __main__)
EXIT_CODES = {"success": 0, "partial": 1, "failed": 1, "aborted": 3}


@dataclass(frozen=True)
class RunResult:
    run_id: int
    status: str
    pages_ok: int
    pages_failed: int
    notes: str


def collect(
    requests: Sequence[PageRequest],
    source: PageSource,
    repo: Repository,
    raw_dir: Path,
    collector_version: str,
    log: Callable[[str], None] = print,
) -> RunResult:
    run = repo.open_run(collector_version)
    log(f"Tournée {run.id} ouverte ({len(requests)} page(s), {source.description}).")
    pages_ok = pages_failed = 0
    notes = [f"Source : {source.description}."]
    status: str | None = None

    try:
        for request in requests:
            fetched_at = datetime.now(UTC)
            fetched = source.fetch(request)

            if fetched.content is None:
                repo.record_page(run.id, PageRecord(
                    request=request, fetched_at=fetched_at, fetch_status=fetched.error_status,
                    error_message=fetched.error, http_status=fetched.http_status,
                    final_url=fetched.final_url,
                ))
                pages_failed += 1
                notes.append(f"{request.label} : page non obtenue ({fetched.error}).")
                log(f"  {request.label} : page non obtenue : {fetched.error}")
                continue

            verdict = validate_bestseller_page(fetched.content, request.node)
            # Toute page reçue est conservée, même invalide : c'est la trace de ce qui a été reçu
            stored = store_raw(raw_dir, raw_relative_path(run.id, run.started_at, request), fetched.content)
            repo.record_page(run.id, PageRecord(
                request=request, fetched_at=fetched_at, fetch_status=verdict.status,
                error_message=verdict.reason, http_status=fetched.http_status,
                final_url=fetched.final_url, stored=stored,
            ))

            if verdict.status == "ok":
                pages_ok += 1
                log(f"  {request.label} : ok, {verdict.rank_count} rangs ({fetched.origin}) -> {stored.relative_path}")
                if verdict.short_list:
                    notes.append(f"{request.label} : liste courte ({verdict.rank_count} rangs sur {FULL_LIST_SIZE}).")
                continue

            pages_failed += 1
            status = "aborted"
            notes.append(f"Arrêt : {request.label} : {verdict.reason}.")
            log(f"  {request.label} : {verdict.status} : {verdict.reason}")
            log("  Arrêt de la tournée (décision 002).")
            break

        if status is None:
            if pages_failed == 0:
                status = "success"
            elif pages_ok == 0:
                status = "failed"
            else:
                status = "partial"
    except BaseException as exc:
        status = "failed"
        notes.append(f"Erreur : {type(exc).__name__} : {exc}.")
        raise
    finally:
        notes_text = "\n".join(notes)
        repo.close_run(run.id, status or "failed", pages_ok, pages_failed, notes_text)
        log(f"Tournée {run.id} close : {status}, {pages_ok} ok, {pages_failed} en échec.")

    return RunResult(run_id=run.id, status=status, pages_ok=pages_ok,
                     pages_failed=pages_failed, notes=notes_text)
