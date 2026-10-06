"""Déroulement d'une tournée de collecte (décisions 001, 002 et 004).

Pour chaque page demandée : obtenir, valider, déposer dans RAW (fichier + ligne raw_page).
- Les pages 1 viennent du fichier des cibles ; une page 2 n'est demandée que si deux signaux
  concordent sur la page 1 du même type : 50 rangs ET pagination annonçant une page 2.
  On ne demande jamais une page que le site n'annonce pas. Elle est demandée juste après sa page 1.
- Une page « blocked » ou « invalid » arrête la tournée (disjoncteur de la décision 002) ;
  la logique de reprise des nuits suivantes n'est pas encore écrite.
- Le plafond de requêtes est contrôlé au chargement des cibles, puis à nouveau pendant la tournée.
"""

from collections import deque
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from books.collector.repository import PageRecord, Repository
from books.collector.sources import PageSource
from books.collector.storage import raw_relative_path, store_raw
from books.collector.targets import MAX_PAGES_PER_LIST, MAX_REQUESTS_PER_RUN, PageRequest
from books.collector.validation import FULL_LIST_SIZE, Verdict, validate_bestseller_page

# Codes de sortie du collecteur (2 = configuration, dans __main__)
EXIT_CODES = {"success": 0, "partial": 1, "failed": 1, "aborted": 3}


@dataclass(frozen=True)
class RunResult:
    run_id: int
    status: str
    pages_ok: int
    pages_failed: int
    notes: str


def next_page(request: PageRequest, verdict: Verdict) -> tuple[PageRequest | None, str | None]:
    """Page suivante à demander après une page conforme, et éventuelle anomalie à signaler.

    Deux signaux doivent concorder : la page compte 50 rangs, et sa pagination annonce la page suivante.
    S'ils divergent, la page suivante n'est ni demandée ni comptée comme manquante : l'anomalie est signalée.
    """
    if request.page_number >= MAX_PAGES_PER_LIST:
        return None, None
    full = verdict.rank_count == FULL_LIST_SIZE
    announced = verdict.next_page_announced
    following = request.page_number + 1
    if full and announced:
        return PageRequest(request.node, request.list_type, following), None
    if full:
        return None, (f"{FULL_LIST_SIZE} rangs, mais la pagination n'annonce pas de page {following} : "
                      f"page {following} non demandée")
    if announced:
        return None, (f"page {following} annoncée par la pagination, mais seulement {verdict.rank_count} rangs : "
                      f"page {following} non demandée")
    return None, None


def collect(
    requests: Sequence[PageRequest],
    source: PageSource,
    repo: Repository,
    raw_dir: Path,
    collector_version: str,
    log: Callable[[str], None] = print,
    max_requests: int = MAX_REQUESTS_PER_RUN,
) -> RunResult:
    run = repo.open_run(collector_version)
    log(f"Tournée {run.id} ouverte ({len(requests)} page(s) 1, {source.description}).")
    pages_ok = pages_failed = requests_made = 0
    notes = [f"Source : {source.description}."]
    status: str | None = None
    queue = deque(requests)

    try:
        while queue:
            request = queue.popleft()
            if requests_made >= max_requests:
                # Ne devrait jamais arriver : le fichier des cibles est vérifié au chargement
                raise RuntimeError(f"plafond de {max_requests} requêtes par tournée atteint (décision 002)")
            requests_made += 1
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

            verdict = validate_bestseller_page(fetched.content, request)
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
                information = list(verdict.notes)
                following, anomaly = next_page(request, verdict)
                if anomaly:
                    information.append(anomaly)
                for note in information:
                    notes.append(f"{request.label} : {note}.")
                    log(f"  {request.label} : information : {note}")
                if following:
                    queue.appendleft(following)  # demandée juste après sa page 1
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
        notes.append(f"Requêtes : {requests_made}.")
        notes_text = "\n".join(notes)
        repo.close_run(run.id, status or "failed", pages_ok, pages_failed, notes_text)
        log(f"Tournée {run.id} close : {status}, {pages_ok} ok, {pages_failed} en échec, {requests_made} requête(s).")

    return RunResult(run_id=run.id, status=status, pages_ok=pages_ok,
                     pages_failed=pages_failed, notes=notes_text)
