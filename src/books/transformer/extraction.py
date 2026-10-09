"""Extraction : pages RAW du périmètre → lignes de staging.ranking_entry (décision 011).

Pour chaque page à extraire, dans l'ordre de raw.raw_page :
1. intégrité du fichier RAW (books.transformer.integrity) ; écart : page « integrity_failed » ;
2. analyse (books.transformer.parsing) ; forme inconnue : page « parse_failed » ;
3. écriture des lignes, dans une transaction par page.
Une page en échec n'arrête pas les suivantes ; ses anciennes lignes sont supprimées. Seule une erreur d'exécution
(base de données, disque) arrête l'extraction : l'exécution est alors close en « failed ».

Statuts et codes de sortie, comme l'ingestion (décision 008) : success (0) aucune anomalie ; partial (1) au moins une
page en échec ; failed (1) erreur d'exécution. Verrou occupé : ExtractionBusy, aucune exécution enregistrée (1).
"""

from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from books.transformer.integrity import RawIntegrityError, read_raw_page
from books.transformer.parsing import EXTRACTOR_VERSION, ParseError, parse_ranking_page
from books.transformer.repository import TransformerRepository

EXIT_CODES = {"success": 0, "partial": 1, "failed": 1}


class ExtractionBusy(Exception):
    """Une autre extraction est en cours (verrou consultatif pris)."""


@dataclass
class ExtractionReport:
    """Bilan d'une exécution, affiché et enregistré dans extract_run.notes."""

    extractor_version: str
    force: bool
    to_extract: int = 0
    up_to_date: int = 0
    extracted: int = 0
    rows: int = 0
    rows_with_card: int = 0
    parse_failures: list[str] = field(default_factory=list)
    integrity_failures: list[str] = field(default_factory=list)
    out_of_scope: dict[str, int] = field(default_factory=dict)
    error: str | None = None

    @property
    def pages_failed(self) -> int:
        return len(self.parse_failures) + len(self.integrity_failures)

    @property
    def anomalies(self) -> int:
        return self.pages_failed

    @property
    def status(self) -> str:
        if self.error is not None:
            return "failed"
        return "success" if self.anomalies == 0 else "partial"

    def lines(self) -> list[str]:
        out = [f"Extracteur version {self.extractor_version}"
               + (" (réextraction complète demandée)" if self.force else ""),
               f"  Pages à extraire     : {self.to_extract}",
               f"  Déjà à jour          : {self.up_to_date}",
               f"  Extraites            : {self.extracted} ({self.rows} lignes, dont {self.rows_with_card} avec carte"
               f" et {self.rows - self.rows_with_card} sans carte)",
               f"  Échec d'analyse      : {len(self.parse_failures)}",
               f"  Échec d'intégrité    : {len(self.integrity_failures)}"]
        hors = sum(self.out_of_scope.values())
        out.append(f"  Hors périmètre       : {hors}"
                   + (" (" + ", ".join(f"{m} : {n}" for m, n in self.out_of_scope.items()) + ")" if hors else ""))
        for title, items in (("Échecs d'intégrité", self.integrity_failures), ("Échecs d'analyse", self.parse_failures)):
            if items:
                out.append(f"{title} :")
                out.extend(f"  - {item}" for item in items)
        if self.error:
            out.append(f"Erreur d'exécution : {self.error}")
        out.append(f"Résultat : {self.status}, {self.anomalies} anomalie(s)")
        return out


@dataclass(frozen=True)
class ExtractionResult:
    run_id: int
    status: str
    report: ExtractionReport
    notes: str


def extract(repo: TransformerRepository, raw_dir: Path, *, extractor_version: str = EXTRACTOR_VERSION,
            force: bool = False, log: Callable[[str], None] = print) -> ExtractionResult:
    """Extrait les pages à faire ; lève ExtractionBusy si une autre extraction tient le verrou."""
    if not repo.try_lock():
        raise ExtractionBusy("extraction déjà en cours (verrou consultatif occupé)")
    report = ExtractionReport(extractor_version=extractor_version, force=force)
    run_id = repo.open_run(extractor_version)
    try:
        report.out_of_scope = repo.out_of_scope()
        report.up_to_date = 0 if force else repo.count_up_to_date(extractor_version)
        pages = repo.pages_to_extract(extractor_version, force)
        report.to_extract = len(pages)
        for page in pages:
            try:
                content = read_raw_page(raw_dir, page.storage_path, page.content_sha256, page.content_bytes)
            except RawIntegrityError as exc:
                repo.save_failure(run_id, page.id, "integrity_failed", str(exc))
                report.integrity_failures.append(f"{page.label} : {exc}")
                continue
            try:
                entries = parse_ranking_page(content)
            except ParseError as exc:
                repo.save_failure(run_id, page.id, "parse_failed", str(exc))
                report.parse_failures.append(f"{page.label} : {exc}")
                continue
            repo.save_extraction(run_id, page.id, entries)
            report.extracted += 1
            report.rows += len(entries)
            report.rows_with_card += sum(e.has_card for e in entries)
    except BaseException as exc:
        report.error = f"{type(exc).__name__} : {exc}"
        raise
    finally:
        lines = report.lines()
        for line in lines:
            log(line)
        try:
            repo.close_run(run_id, report.status, report.extracted, report.pages_failed, "\n".join(lines))
        except Exception as exc:
            if report.error is None:
                raise
            # Erreur d'exécution déjà en cours (ex. : connexion perdue) : elle est conservée, la clôture est signalée
            log(f"Clôture de l'exécution {run_id} impossible : {type(exc).__name__} : {exc}")
    notes = "\n".join(lines)
    return ExtractionResult(run_id=run_id, status=report.status, report=report, notes=notes)
