"""Tournée de développement sur les pages enregistrées à la main (décisions 004 et 008).

Pour chaque page demandée : obtenir, valider, déposer dans RAW (fichier + ligne raw_page).
- Les pages 1 viennent du fichier des cibles ; une page 2 n'est demandée que si deux signaux
  concordent sur la page 1 du même type : 50 rangs ET pagination annonçant une page 2
  (books.collector.validation.next_page). Elle est demandée juste après sa page 1.
- Une page « blocked » ou « invalid » est déposée avec son statut et la tournée continue,
  comme l'ingestion des captures (décision 008).
- Statuts : success (aucune anomalie), partial (le programme a fonctionné, au moins une anomalie),
  failed (erreur d'exécution). Le plafond de requêtes est contrôlé au chargement des cibles, puis pendant la tournée.
"""

from collections import deque
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from books.collector.repository import PageRecord, Repository
from books.collector.sources import PageSource
from books.collector.storage import raw_relative_path, store_raw
from books.amazon.ranking_page import PageRequest
from books.collector.validation import FULL_LIST_SIZE, next_page, validate_bestseller_page

# Codes de sortie du collecteur (décision 008) : 0 sans anomalie, 1 au moins une anomalie ou erreur
# d'exécution ; 2 = configuration, dans __main__. Le code 3 et le statut « aborted » ne sont plus utilisés.
EXIT_CODES = {"success": 0, "partial": 1, "failed": 1}
# Plafond de pages lues par tournée ou par ingestion (décision 002, compté en pages depuis la décision 005)
MAX_REQUESTS_PER_RUN = 200


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
                    capture_method=fetched.capture_method, error_message=fetched.error, http_status=fetched.http_status,
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
                capture_method=fetched.capture_method, error_message=verdict.reason, http_status=fetched.http_status,
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

            # Page déposée avec son statut ; la tournée continue (décision 008)
            pages_failed += 1
            notes.append(f"Anomalie : {request.label} : {verdict.status} : {verdict.reason}.")
            log(f"  {request.label} : {verdict.status} : {verdict.reason}")

        status = "success" if pages_failed == 0 else "partial"
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
