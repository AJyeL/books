"""Ingestion des captures de inbox/ dans RAW (décision 008).

Pour chaque élément de inbox/, dans l'ordre des lots puis des noms :
1. intégrité (décision 007, section 6) et périmètre ; en cas d'échec, quarantaine, rien dans RAW ;
2. « déjà ingérée » : une capture dont l'empreinte est déjà dans RAW est retirée, sans nouvelle ligne ;
3. validation (décision 004) ; HTML et JSON déposés dans RAW, compressés, jamais écrasés ;
   une capture « blocked » ou « invalid » est déposée avec son statut, et l'ingestion continue ;
4. ligne raw_page validée en base, puis retrait de inbox/ (le JSON d'abord, le HTML ensuite).
En fin d'ingestion : page 2 manquante vérifiée au sein de chaque lot, puis bilan.

Statuts : success (aucune anomalie), partial (le programme a fonctionné, au moins une anomalie),
failed (erreur d'exécution). Anomalies : capture blocked ou invalid, quarantaine, élément laissé en place,
page 2 manquante, plafond de captures atteint.
"""

import hashlib
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from books.collector.inbox import (
    CAPTURE_STEM, EXTENSION_DOM, Capture, LoneHtml, Pair, QuarantineError, Rejected, Untouchable,
    check_capture, quarantine, remove_capture, remove_empty_lots, scan_inbox,
)
from books.collector.repository import PageRecord, Repository
from books.collector.run import EXIT_CODES, RunResult
from books.collector.storage import capture_relative_paths, store_raw
from books.collector.targets import MAX_REQUESTS_PER_RUN, PageRequest
from books.collector.validation import FULL_LIST_SIZE, next_page, validate_bestseller_page

INBOX = "inbox"
QUARANTINE = "quarantaine"


@dataclass
class Report:
    """Ce qu'une ingestion a fait, pour le bilan et les notes de la tournée."""
    run_id: int
    lots: list[str] = field(default_factory=list)
    deposited: dict[str, int] = field(default_factory=lambda: {"ok": 0, "blocked": 0, "invalid": 0})
    already: int = 0
    rejected_pages: list[str] = field(default_factory=list)    # captures blocked ou invalid, avec la raison
    quarantined: list[str] = field(default_factory=list)
    left_in_place: list[str] = field(default_factory=list)
    missing_page2: list[str] = field(default_factory=list)
    cap_reached: str | None = None
    information: list[str] = field(default_factory=list)
    error: str | None = None

    @property
    def anomalies(self) -> int:
        return (len(self.rejected_pages) + len(self.quarantined) + len(self.left_in_place)
                + len(self.missing_page2) + (1 if self.cap_reached else 0))

    @property
    def status(self) -> str:
        if self.error:
            return "failed"
        return "success" if self.anomalies == 0 else "partial"

    def lines(self) -> list[str]:
        """Bilan lisible : noms de fichiers et numéros de catégorie seulement, aucune donnée de livre."""
        d = self.deposited

        def block(title: str, entries: list[str]) -> list[str]:
            return [f"  {title:<19}: {len(entries)}"] + [f"    - {e}" for e in entries]

        out = [f"Bilan de l'ingestion {self.run_id} — lot(s) : {', '.join(self.lots) or 'aucun'}",
               f"  {'Déposées dans RAW':<19}: {sum(d.values())} "
               f"(ok {d['ok']}, blocked {d['blocked']}, invalid {d['invalid']})",
               f"  {'Déjà ingérées':<19}: {self.already}"]
        out += block("Pages anormales", self.rejected_pages)
        out += block("Quarantaine", self.quarantined)
        out += block("Laissés en place", self.left_in_place)
        out += block("Pages 2 manquantes", self.missing_page2)
        if self.cap_reached:
            out.append(f"  {'Plafond':<19}: {self.cap_reached}")
        out += block("Informations", self.information)
        if self.error:
            out.append(f"  {'Erreur':<19}: {self.error}")
        out.append(f"Résultat : {self.status}, {self.anomalies} anomalie(s) — "
                   f"code de sortie {EXIT_CODES[self.status]}")
        return out


@dataclass(frozen=True)
class IngestionResult(RunResult):
    """Résultat d'une ingestion : celui d'une tournée, plus le bilan structuré (compteurs et anomalies)."""
    report: Report | None = None


def _page_of(stem: str) -> tuple[str, str, int] | None:
    """(catégorie, liste, page) d'après un nom de capture conforme, sinon None."""
    match = CAPTURE_STEM.fullmatch(stem)
    return (match.group(1), match.group(2), int(match.group(3))) if match else None


def ingest(
    captures_dir: Path,
    perimeter: set[tuple[str, str]],
    repo: Repository,
    raw_dir: Path,
    collector_version: str,
    log: Callable[[str], None] = print,
    max_captures: int = MAX_REQUESTS_PER_RUN,
) -> IngestionResult:
    inbox_dir = captures_dir / INBOX
    quarantine_dir = captures_dir / QUARANTINE
    if not inbox_dir.is_dir():
        raise FileNotFoundError(f"Dossier des captures à ingérer introuvable : {inbox_dir}")
    if not raw_dir.is_dir():
        raise FileNotFoundError(f"Dossier des pages brutes introuvable : {raw_dir}")

    run = repo.open_run(collector_version)
    report = Report(run_id=run.id)
    items = scan_inbox(inbox_dir)
    log(f"Ingestion {run.id} ouverte : {len(items)} élément(s) dans {inbox_dir}.")

    # Inventaire des pages présentes dans chaque lot, d'après les noms (y compris celles qui partiront
    # en quarantaine) : une page 2 présente dans le lot n'est jamais comptée comme manquante.
    in_lot: dict[str, set[tuple[str, str, int]]] = {}
    for item in items:
        if isinstance(item, Pair | LoneHtml | Rejected):
            if item.lot not in report.lots:
                report.lots.append(item.lot)
            page = _page_of(item.stem)
            if page:
                in_lot.setdefault(item.lot, set()).add(page)
    first_pages: list[tuple[str, PageRequest]] = []  # (lot, page 2 attendue)

    def to_quarantine(rejected: Rejected) -> None:
        try:
            quarantine(rejected, quarantine_dir)
        except QuarantineError as exc:
            report.left_in_place.append(f"{rejected.lot}/{rejected.stem} : quarantaine impossible ({exc})")
            return
        report.quarantined.append(f"{rejected.lot}/{rejected.stem} : {rejected.reason}")

    handled = 0
    try:
        for item in items:
            if isinstance(item, Untouchable):
                report.left_in_place.append(f"{item.path.relative_to(inbox_dir).as_posix()} : {item.reason}")
                continue
            if handled >= max_captures:
                report.cap_reached = (f"{max_captures} captures atteint (décision 008) : "
                                      f"la suite reste dans inbox/ pour l'ingestion suivante")
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
                    report.already += 1
                    report.information.append(f"{item.lot}/{item.stem} : déjà ingérée (HTML resté seul)")
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
                report.already += 1
                report.information.append(f"{capture.label} : déjà ingérée")
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
            report.deposited[verdict.status] += 1
            log(f"  {capture.label} : {verdict.status}, {verdict.rank_count} rangs")

            if verdict.status != "ok":
                # Déposée avec son statut ; l'ingestion continue (décision 008)
                report.rejected_pages.append(f"{capture.label} : {verdict.status} : {verdict.reason}")
                continue
            if verdict.short_list:
                report.information.append(
                    f"{capture.label} : liste courte ({verdict.rank_count} rangs sur {FULL_LIST_SIZE})")
            report.information.extend(f"{capture.label} : {n}" for n in verdict.notes)
            expected, divergence = next_page(capture.request, verdict)
            if divergence:
                report.information.append(f"{capture.label} : {divergence}")
            if expected:
                first_pages.append((capture.lot, expected))

        # Page 2 manquante, au sein du même lot (une séance donne un lot)
        for lot, expected in first_pages:
            if (expected.node, expected.list_type, expected.page_number) not in in_lot.get(lot, set()):
                report.missing_page2.append(
                    f"{expected.node} {expected.list_type} : page {expected.page_number} annoncée, "
                    f"absente du lot {lot}")

        removed = remove_empty_lots(inbox_dir)
        if removed:
            report.information.append(f"lots vidés et supprimés : {', '.join(removed)}")
    except BaseException as exc:
        report.error = f"{type(exc).__name__} : {exc}"
        raise
    finally:
        lines = report.lines()
        for line in lines:
            log(line)
        repo.close_run(run.id, report.status, report.deposited["ok"],
                       report.deposited["blocked"] + report.deposited["invalid"], "\n".join(lines))

    return IngestionResult(run_id=run.id, status=report.status, pages_ok=report.deposited["ok"],
                           pages_failed=report.deposited["blocked"] + report.deposited["invalid"],
                           notes="\n".join(lines), report=report)
