"""Extraction des rapports Amazon Ads : RAW → STAGING (décision 018, lot B).

Pour chaque fichier RAW ok à extraire, dans l'ordre de raw.ads_report_file :
1. intégrité du fichier RAW (books.transformer.integrity) ; écart : fichier « integrity_failed » ;
2. analyse du contenu (books.ads.parsing) : défaut : « parse_failed » avec son motif ; aucune ligne de données :
   « no_activity » (aucune activité rapportée), ni succès ni anomalie ;
3. codes des textes (mapping.code_for, paramètres liés) et lignes, dans une transaction par fichier.
Un fichier déjà extrait par la même version n'est pas réextrait ; un échec est retenté à la version suivante, et
reste signalé au bilan (anomalie) tant qu'il dure.

Contrôles du bilan (décision 018, section 7) : réconciliation Advertised product / Search term, jour par jour, pour
chaque export dont un fichier vient d'être extrait (même date d'export ; réunion des jours ; un jour présent d'un
seul côté est un écart) ; deux fichiers du même type et de même date d'export (information) ; emprunts et
redevances jamais vus non nuls (information) ; colonnes inconnues (information). La fraîcheur est contrôlée par
l'extraction des captures, qui tourne même quand aucun rapport n'arrive.

Statuts et codes de sortie, comme l'extracteur des pages : success (0) ; partial (1) au moins un fichier en échec ou
un écart de réconciliation ; failed (1) erreur d'exécution. Verrou occupé : AdsExtractionBusy (1).
"""

from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from books.ads.ingestion import TYPE_LABELS
from books.ads.parsing import MEASURES, AdsParseError, NoActivity, parse_report
from books.ads.transformer_repository import AdsTransformerRepository
from books.transformer.integrity import RawIntegrityError, read_raw_page

# Toute modification des règles d'analyse (books.ads.parsing) incrémente cette version, dans le même commit
ADS_EXTRACTOR_VERSION = "1"
EXIT_CODES = {"success": 0, "partial": 1, "failed": 1}
MEASURE_LABELS = {name: label for label, (name, _) in MEASURES.items()}
# Mesures comparées entre les deux types d'un même export (décision 018, section 7)
RECONCILED = ["cost", "clicks", "impressions", "purchases", "sales", "kenp_pages", "borrows"]


class AdsExtractionBusy(Exception):
    """Une autre extraction des rapports est en cours (verrou consultatif pris)."""


@dataclass
class AdsExtractionReport:
    """Bilan d'une exécution, affiché et enregistré dans ads_extract_run.notes : noms de fichiers, types, dates,
    motifs et totaux ; jamais un texte des lignes."""

    extractor_version: str
    force: bool
    to_extract: int = 0
    up_to_date: int = 0
    out_of_scope: int = 0
    extracted: list[str] = field(default_factory=list)
    no_activity: list[str] = field(default_factory=list)
    failures: list[str] = field(default_factory=list)
    known_failures: list[str] = field(default_factory=list)
    reconciliation_gaps: list[str] = field(default_factory=list)
    information: list[str] = field(default_factory=list)
    rows: dict = field(default_factory=lambda: {"advertised_product": 0, "search_term": 0})
    error: str | None = None

    @property
    def anomalies(self) -> int:
        return len(self.failures) + len(self.known_failures) + len(self.reconciliation_gaps)

    @property
    def status(self) -> str:
        if self.error is not None:
            return "failed"
        return "success" if self.anomalies == 0 else "partial"

    def lines(self) -> list[str]:
        def block(title: str, entries: list[str]) -> list[str]:
            return [f"  {title:<26}: {len(entries)}"] + [f"    - {e}" for e in entries]

        out = [f"Extracteur des rapports Ads version {self.extractor_version}"
               + (" (réextraction complète demandée)" if self.force else ""),
               f"  {'Fichiers à extraire':<26}: {self.to_extract}",
               f"  {'Déjà à jour':<26}: {self.up_to_date}",
               f"  {'Hors périmètre (invalid)':<26}: {self.out_of_scope}",
               f"  {'Lignes Advertised product':<26}: {self.rows['advertised_product']}",
               f"  {'Lignes Search term':<26}: {self.rows['search_term']}"]
        out += block("Extraits", self.extracted)
        out += block("Aucune activité rapportée", self.no_activity)
        out += block("Échecs", self.failures)
        out += block("Échecs connus (version)", self.known_failures)
        out += block("Écarts de réconciliation", self.reconciliation_gaps)
        out += block("Informations", self.information)
        if self.error:
            out.append(f"  {'Erreur':<26}: {self.error}")
        out.append(f"Résultat : {self.status}, {self.anomalies} anomalie(s) — code de sortie {EXIT_CODES[self.status]}")
        return out


@dataclass(frozen=True)
class AdsExtractionResult:
    run_id: int
    status: str
    report: AdsExtractionReport


def _reconcile(repo: AdsTransformerRepository, report: AdsExtractionReport, export_dates: list) -> None:
    """Réconciliation des exports touchés : le fichier retenu de chaque type (le plus récent par l'heure)."""
    chosen: dict = {}
    for export_date, report_type, file_id, label, export_time in repo.export_files(export_dates):
        key = (export_date, report_type)
        if key in chosen:
            report.information.append(
                f"export du {export_date.isoformat()} : deux fichiers {TYPE_LABELS[report_type]} ; retenu "
                f"{chosen[key][1]} (le plus récent par l'heure), écarté {label}")
            continue
        chosen[key] = (file_id, label)
    for export_date in export_dates:
        ap = chosen.get((export_date, "advertised_product"))
        st = chosen.get((export_date, "search_term"))
        if ap is None or st is None:
            present = TYPE_LABELS["advertised_product" if ap else "search_term"]
            absent = TYPE_LABELS["search_term" if ap else "advertised_product"]
            if ap or st:
                report.information.append(f"export du {export_date.isoformat()} : {present} sans {absent} "
                                          f"(aucune réconciliation)")
            continue
        totals_ap = repo.day_totals(ap[0], "advertised_product")
        totals_st = repo.day_totals(st[0], "search_term")
        prefix = f"export du {export_date.isoformat()}"
        for day in sorted(set(totals_ap) | set(totals_st)):
            if day not in totals_st or day not in totals_ap:
                side = "Advertised product" if day in totals_ap else "Search term"
                report.reconciliation_gaps.append(f"{prefix}, {day.isoformat()} : jour présent dans le seul {side}")
                continue
            for measure in RECONCILED:
                (sum_ap, null_ap), (sum_st, null_st) = totals_ap[day][measure], totals_st[day][measure]
                label = MEASURE_LABELS[measure]
                if null_ap or null_st:
                    report.information.append(f"{prefix}, {day.isoformat()} : « {label} » non comparée "
                                              f"(cellule vide)")
                elif sum_ap != sum_st:
                    report.reconciliation_gaps.append(
                        f"{prefix}, {day.isoformat()} : « {label} » Advertised product {sum_ap}, "
                        f"Search term {sum_st} (écart {sum_st - sum_ap})")


def extract_reports(repo: AdsTransformerRepository, raw_dir: Path, *, extractor_version: str = ADS_EXTRACTOR_VERSION,
                    force: bool = False, log: Callable[[str], None] = print) -> AdsExtractionResult:
    """Extrait les fichiers à faire ; lève AdsExtractionBusy si une autre extraction tient le verrou."""
    if not repo.try_lock():
        raise AdsExtractionBusy("extraction des rapports déjà en cours (verrou consultatif occupé)")
    report = AdsExtractionReport(extractor_version=extractor_version, force=force)
    run_id = repo.open_run(extractor_version)
    try:
        report.out_of_scope = repo.out_of_scope()
        if not force:
            report.up_to_date = repo.count_up_to_date(extractor_version)
        files = repo.files_to_extract(extractor_version, force)
        report.to_extract = len(files)
        touched = set()
        for ref in files:
            kind = TYPE_LABELS[ref.report_type]
            try:
                content = read_raw_page(raw_dir, ref.storage_path, ref.content_sha256, ref.content_bytes)
            except RawIntegrityError as exc:
                repo.save_failure(run_id, ref.id, "integrity_failed", str(exc))
                report.failures.append(f"{ref.label} : integrity_failed : {exc}")
                continue
            try:
                parsed = parse_report(content, ref.report_type, ref.export_date)
            except NoActivity as exc:
                repo.save_no_activity(run_id, ref.id, exc.unknown_columns)
                report.no_activity.append(f"{ref.label} : {kind}, export du {ref.export_date.isoformat()}")
                if exc.unknown_columns:
                    report.information.append(f"{ref.label} : colonnes inconnues : "
                                              + ", ".join(f"« {c} »" for c in exc.unknown_columns))
                continue
            except AdsParseError as exc:
                repo.save_failure(run_id, ref.id, "parse_failed", str(exc))
                report.failures.append(f"{ref.label} : parse_failed : {exc}")
                continue
            repo.save_report(run_id, ref.id, parsed)
            touched.add(ref.export_date)
            report.rows[ref.report_type] += len(parsed.rows)
            report.extracted.append(f"{ref.label} : {kind}, export du {ref.export_date.isoformat()}, "
                                    f"{len(parsed.rows)} lignes du {parsed.first_day.isoformat()} "
                                    f"au {parsed.last_day.isoformat()}")
            if parsed.unknown_columns:
                report.information.append(f"{ref.label} : colonnes inconnues : "
                                          + ", ".join(f"« {c} »" for c in parsed.unknown_columns))
        report.known_failures = repo.known_failures(extractor_version, [ref.id for ref in files])
        _reconcile(repo, report, sorted(touched))
        if repo.borrows_or_royalties_seen() is False:
            report.information.append("« Emprunts éligibles à l'abonnement Kindle » et « Estimation des redevances "
                                      "liées à l'abonnement Kindle » : jamais vues non nulles")
    except BaseException as exc:
        report.error = f"{type(exc).__name__} : {exc}"
        raise
    finally:
        lines = report.lines()
        for line in lines:
            log(line)
        try:
            repo.close_run(run_id, report.status, len(report.extracted), len(report.no_activity),
                           len(report.failures), "\n".join(lines))
        except Exception as exc:
            if report.error is None:
                raise
            # Erreur d'exécution déjà en cours : elle est conservée, la clôture impossible est signalée
            log(f"Clôture de l'exécution {run_id} impossible : {type(exc).__name__} : {exc}")
    return AdsExtractionResult(run_id=run_id, status=report.status, report=report)
