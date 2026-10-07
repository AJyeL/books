"""Ingestion des captures de inbox/ dans RAW (décision 008).

Pour chaque élément de inbox/, dans l'ordre des lots puis des noms :
1. intégrité (décision 007, section 6) et périmètre ; en cas d'échec, quarantaine, rien dans RAW ;
2. « déjà ingérée » : une capture dont l'empreinte est déjà dans RAW est retirée, sans nouvelle ligne ;
3. validation (décision 004) ; HTML et JSON déposés dans RAW, compressés, jamais écrasés ;
4. ligne raw_page validée en base, puis retrait de inbox/ (le JSON d'abord, le HTML ensuite).

Étape 2 de la décision 008 : une capture « blocked » ou « invalid » est déposée avec son statut, puis l'ingestion
s'arrête, comme la tournée de développement. La poursuite sans arrêt et les nouveaux codes de sortie
viendront à l'étape 3.
"""

import hashlib
from collections.abc import Callable
from pathlib import Path

from books.collector.inbox import (
    EXTENSION_DOM, Capture, LoneHtml, QuarantineError, Rejected, Untouchable,
    check_capture, quarantine, remove_capture, remove_empty_lots, scan_inbox,
)
from books.collector.repository import PageRecord, Repository
from books.collector.run import RunResult
from books.collector.storage import capture_relative_paths, store_raw
from books.collector.targets import MAX_REQUESTS_PER_RUN
from books.collector.validation import FULL_LIST_SIZE, validate_bestseller_page

INBOX = "inbox"
QUARANTINE = "quarantaine"


def ingest(
    captures_dir: Path,
    perimeter: set[tuple[str, str]],
    repo: Repository,
    raw_dir: Path,
    collector_version: str,
    log: Callable[[str], None] = print,
    max_captures: int = MAX_REQUESTS_PER_RUN,
) -> RunResult:
    inbox_dir = captures_dir / INBOX
    quarantine_dir = captures_dir / QUARANTINE
    if not inbox_dir.is_dir():
        raise FileNotFoundError(f"Dossier des captures à ingérer introuvable : {inbox_dir}")
    if not raw_dir.is_dir():
        raise FileNotFoundError(f"Dossier des pages brutes introuvable : {raw_dir}")

    run = repo.open_run(collector_version)
    items = scan_inbox(inbox_dir)
    log(f"Ingestion {run.id} ouverte : {len(items)} élément(s) dans {inbox_dir}.")
    notes = [f"Ingestion des captures de {inbox_dir}."]
    counts = {"ok": 0, "blocked": 0, "invalid": 0, "déjà ingérées": 0, "quarantaine": 0, "laissés en place": 0}
    handled = 0
    status: str | None = None

    def note(text: str) -> None:
        notes.append(text)
        log(f"  {text}")

    def to_quarantine(rejected: Rejected) -> None:
        try:
            quarantine(rejected, quarantine_dir)
        except QuarantineError as exc:
            counts["laissés en place"] += 1
            note(f"{rejected.lot}/{rejected.stem} : quarantaine impossible, laissé en place ({exc}).")
            return
        counts["quarantaine"] += 1
        note(f"{rejected.lot}/{rejected.stem} : quarantaine ({rejected.reason}).")

    try:
        for item in items:
            if isinstance(item, Untouchable):
                counts["laissés en place"] += 1
                note(f"{item.path.relative_to(inbox_dir)} : signalé, laissé en place ({item.reason}).")
                continue
            if handled >= max_captures:
                note(f"Plafond de {max_captures} captures atteint (décision 008) : la suite reste dans inbox/.")
                break
            handled += 1

            if isinstance(item, Rejected):
                to_quarantine(item)
                continue

            if isinstance(item, LoneHtml):
                # Empreinte d'un HTML resté seul : interruption entre le retrait du JSON et celui du HTML ?
                sha = hashlib.sha256(item.html_path.read_bytes()).hexdigest()
                if repo.find_capture(sha) is not None:
                    remove_capture(None, item.html_path)
                    counts["déjà ingérées"] += 1
                    note(f"{item.lot}/{item.stem} : déjà ingérée (HTML resté seul), retirée de inbox/.")
                else:
                    to_quarantine(Rejected(item.lot, item.stem, (item.html_path,),
                                           "HTML orphelin : JSON jumeau absent"))
                continue

            checked = check_capture(item, perimeter)
            if isinstance(checked, Rejected):
                to_quarantine(checked)
                continue
            capture: Capture = checked

            if repo.find_capture(capture.html_sha256) is not None:
                remove_capture(capture.json_path, capture.html_path)
                counts["déjà ingérées"] += 1
                note(f"{capture.label} : déjà ingérée, retirée de inbox/.")
                continue

            verdict = validate_bestseller_page(capture.html, capture.request)
            html_rel, json_rel = capture_relative_paths(run.id, run.started_at, capture.request, capture.captured_at)
            stored_html = store_raw(raw_dir, html_rel, capture.html)
            stored_json = store_raw(raw_dir, json_rel, capture.json_bytes)
            repo.record_page(run.id, PageRecord(
                request=capture.request, fetched_at=capture.captured_at, fetch_status=verdict.status,
                capture_method=EXTENSION_DOM, error_message=verdict.reason,
                stored=stored_html, metadata=stored_json, requested_url=capture.displayed_url,
            ))
            # Fichiers écrits et synchronisés, ligne validée (autocommit) : la capture peut quitter inbox/
            remove_capture(capture.json_path, capture.html_path)
            counts[verdict.status] += 1
            log(f"  {capture.label} : {verdict.status}, {verdict.rank_count} rangs -> {stored_html.relative_path}")
            if verdict.status == "ok":
                if verdict.short_list:
                    notes.append(f"{capture.label} : liste courte ({verdict.rank_count} rangs sur {FULL_LIST_SIZE}).")
                for information in verdict.notes:
                    note(f"{capture.label} : {information}.")
                continue

            # Provisoire (étape 2) : arrêt sur une capture blocked ou invalid ; poursuite à l'étape 3
            status = "aborted"
            note(f"Arrêt : {capture.label} : {verdict.reason}.")
            break

        removed = remove_empty_lots(inbox_dir)
        if removed:
            notes.append(f"Lots vidés et supprimés : {', '.join(removed)}.")
        if status is None:
            anomalies = counts["quarantaine"] + counts["laissés en place"]
            status = "success" if anomalies == 0 else "partial"
    except BaseException as exc:
        status = "failed"
        notes.append(f"Erreur : {type(exc).__name__} : {exc}.")
        raise
    finally:
        notes.append("Bilan : " + ", ".join(f"{k} {v}" for k, v in counts.items()) + ".")
        notes_text = "\n".join(notes)
        pages_ok = counts["ok"]
        pages_failed = counts["blocked"] + counts["invalid"]
        repo.close_run(run.id, status or "failed", pages_ok, pages_failed, notes_text)
        log(f"Ingestion {run.id} close : {status} ; " + ", ".join(f"{k} {v}" for k, v in counts.items()) + ".")

    return RunResult(run_id=run.id, status=status, pages_ok=pages_ok, pages_failed=pages_failed, notes=notes_text)
