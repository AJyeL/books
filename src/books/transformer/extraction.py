"""Extraction : pages RAW du périmètre → STAGING (décisions 011, 014 et 015).

Pour chaque page à extraire, dans l'ordre de raw.raw_page :
1. intégrité du fichier RAW (books.transformer.integrity) ; écart : page « integrity_failed » ;
2. analyse : page de classement (books.transformer.parsing) ou fiche produit (books.transformer.product_parsing) ;
   forme inconnue : page « parse_failed » ; fiche papier : page « skipped » (motif « format papier ») ;
3. écriture des lignes, dans une transaction par page.
Une page en échec n'arrête pas les suivantes ; ses anciennes lignes sont supprimées. Seule une erreur d'exécution
(base de données, disque) arrête l'extraction : l'exécution est alors close en « failed ».

Après les pages, CORE est reconstruite en entier à partir des pages extraites par cette version (décision 020),
même s'il n'y avait aucune page à extraire. Construction refusée par la base : CORE garde son contenu précédent, et
c'est une anomalie.

Statuts et codes de sortie, comme l'ingestion (décision 008) : success (0) aucune anomalie ; partial (1) au moins une
page en échec, ou CORE non reconstruite ; failed (1) erreur d'exécution. Une fiche mise à part n'est ni un succès ni une anomalie : elle est
comptée à part et n'a aucun effet sur le statut (décision 015, note du 11 octobre 2026).
Verrou occupé : ExtractionBusy, aucune exécution enregistrée (1).

Le bilan porte aussi la fraîcheur des rapports Amazon Ads (décision 018, section 7, note du 5 novembre 2026), en
information sans effet sur le statut : cette extraction tourne après chaque envoi de captures, même quand aucun
rapport n'arrive.
"""

from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, date, datetime
from pathlib import Path

from books.transformer.integrity import RawIntegrityError, read_raw_page
from books.transformer.parsing import EXTRACTOR_VERSION, ParseError, parse_ranking_page
from books.transformer.product_parsing import PageSkipped, ParsedProduct, parse_product_page
from books.transformer.repository import CoreBuild, CoreBuildError, TransformerRepository

EXIT_CODES = {"success": 0, "partial": 1, "failed": 1}
# Fraîcheur des rapports Amazon Ads : un rapport de moins de 10 jours attendu pour chaque type (décision 018)
ADS_FRESHNESS_DAYS = 10
ADS_TYPE_LABELS = {"advertised_product": "Advertised product", "search_term": "Search term"}
# Champs d'une fiche dont l'absence est comptée au bilan (information)
PRODUCT_FIELDS = {
    "série": "series_form", "date de publication": "publication_date", "langue": "language",
    "pages imprimées": "print_pages", "taille du fichier": "file_size_value", "ISBN-13": "isbn13",
    "note": "rating", "nombre d'avis": "review_count", "couverture": "cover_url", "description": "description_text",
    "bloc A+": "has_aplus", "fil de catégories": "breadcrumb",
}


class ExtractionBusy(Exception):
    """Une autre extraction est en cours (verrou consultatif pris)."""


@dataclass
class ExtractionReport:
    """Bilan d'une exécution, affiché et enregistré dans extract_run.notes."""

    extractor_version: str
    force: bool
    to_extract: int = 0
    up_to_date: int = 0
    up_to_date_skipped: int = 0
    extracted: int = 0
    rows: int = 0
    rows_with_card: int = 0
    # Pages extraites dont un nom de catégorie n'a pas été lu (décision 014) : information, jamais une anomalie
    without_display_name: int = 0
    without_short_name: int = 0
    products_extracted: int = 0
    skipped: list[str] = field(default_factory=list)
    product_missing: Counter = field(default_factory=Counter)
    unknown_span_classes: Counter = field(default_factory=Counter)
    removed_tags: Counter = field(default_factory=Counter)
    parse_failures: list[str] = field(default_factory=list)
    integrity_failures: list[str] = field(default_factory=list)
    out_of_scope: dict[str, int] = field(default_factory=dict)
    ads_freshness: list[str] = field(default_factory=list)  # information seulement, jamais une anomalie
    core: CoreBuild | None = None  # construction de CORE réussie (décision 020)
    core_error: str | None = None  # construction de CORE annulée : une anomalie
    error: str | None = None

    @property
    def pages_extracted(self) -> int:
        return self.extracted + self.products_extracted

    @property
    def pages_failed(self) -> int:
        return len(self.parse_failures) + len(self.integrity_failures)

    @property
    def anomalies(self) -> int:
        return self.pages_failed + (self.core_error is not None)

    @property
    def status(self) -> str:
        if self.error is not None:
            return "failed"
        return "success" if self.anomalies == 0 else "partial"

    def add_product(self, product: ParsedProduct) -> None:
        self.products_extracted += 1
        self.product_missing.update(label for label, name in PRODUCT_FIELDS.items() if getattr(product, name) is None)
        self.unknown_span_classes.update(dict(product.unknown_span_classes))
        self.removed_tags.update(dict(product.removed_tags))

    def lines(self) -> list[str]:
        out = [f"Extracteur version {self.extractor_version}"
               + (" (réextraction complète demandée)" if self.force else ""),
               f"  Pages à extraire     : {self.to_extract}",
               f"  Déjà à jour          : {self.up_to_date}"
               + (f" (dont {self.up_to_date_skipped} fiche(s) papier mise(s) à part)" if self.up_to_date_skipped else ""),
               f"  Extraites            : {self.extracted} ({self.rows} lignes, dont {self.rows_with_card} avec carte"
               f" et {self.rows - self.rows_with_card} sans carte)",
               f"  Sans nom d'affichage : {self.without_display_name}",
               f"  Sans nom court       : {self.without_short_name}",
               f"  Fiches extraites     : {self.products_extracted}",
               f"  Fiches mises à part  : {len(self.skipped)} (format papier ; ni succès ni anomalie)",
               f"  Échec d'analyse      : {len(self.parse_failures)}",
               f"  Échec d'intégrité    : {len(self.integrity_failures)}"]
        hors = sum(self.out_of_scope.values())
        out.append(f"  Hors périmètre       : {hors}"
                   + (" (" + ", ".join(f"{m} : {n}" for m, n in self.out_of_scope.items()) + ")" if hors else ""))
        c = self.core
        if c is not None:
            out.append(f"  CORE version {c.core_version}       : {c.pages_used} page(s) retenue(s) sur {c.pages_eligible}, "
                       f"{c.list_days} liste(s) du jour (dont {c.list_days_incomplete} incomplète(s)), "
                       f"{c.ranking_rows} ligne(s), {c.books} livre(s), {c.categories} catégorie(s), "
                       f"{c.category_name_versions} version(s) de nom")
            out.append(f"  CORE fiches          : {c.product_pages_used} fiche(s) retenue(s) sur {c.product_pages_eligible}, "
                       f"{c.product_days} livre-jour(s), {c.attribute_versions} version(s) d'attributs, "
                       f"{c.product_category_ranks} rang(s) par catégorie")
        info = []
        if c is not None and c.cross_page_duplicates:
            info.append(f"CORE : {c.cross_page_duplicates} livre(s) présent(s) sur la p1 et la p2 retenues d'une liste "
                        "du jour (ligne de la capture la plus récente gardée)")
        if c is not None and c.pages_other_version:
            info.append(f"CORE : {c.pages_other_version} page(s) extraite(s) par une autre version de l'extracteur, "
                        "exclue(s) (jamais deux versions mélangées)")
        if c is not None and c.product_pages_other_version:
            info.append(f"CORE : {c.product_pages_other_version} fiche(s) extraite(s) par une autre version de "
                        "l'extracteur, exclue(s) (jamais deux versions mélangées)")
        if c is not None and c.product_pages_failed:
            info.append(f"CORE : {c.product_pages_failed} fiche(s) en échec d'extraction, hors de CORE")
        if self.product_missing:
            info.append("champs absents des fiches extraites : "
                        + ", ".join(f"{k} : {n}" for k, n in sorted(self.product_missing.items())))
        if self.unknown_span_classes:
            info.append("classes de span inconnues dans les descriptions : "
                        + ", ".join(f"{k} : {n}" for k, n in sorted(self.unknown_span_classes.items())))
        if self.removed_tags:
            info.append("balises retirées des descriptions : "
                        + ", ".join(f"{k} : {n}" for k, n in sorted(self.removed_tags.items())))
        info.extend(self.ads_freshness)
        if info:
            out.append("Informations :")
            out.extend(f"  - {item}" for item in info)
        for title, items in (("Échecs d'intégrité", self.integrity_failures), ("Échecs d'analyse", self.parse_failures)):
            if items:
                out.append(f"{title} :")
                out.extend(f"  - {item}" for item in items)
        if self.core_error:
            out.append(f"CORE non reconstruite : {self.core_error} ; contenu précédent conservé")
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


def ads_freshness(latest: dict[str, date | None], today: date) -> list[str]:
    """Informations de fraîcheur : un type dont les données extraites les plus récentes ont ADS_FRESHNESS_DAYS jours
    ou plus (dernière date des données, jamais l'horodatage du nom)."""
    out = []
    for kind, label in ADS_TYPE_LABELS.items():
        last = latest.get(kind)
        if last is None or (today - last).days >= ADS_FRESHNESS_DAYS:
            seen = f"données jusqu'au {last.isoformat()}" if last else "aucun extrait"
            out.append(f"Aucun rapport Amazon Ads {label} de moins de {ADS_FRESHNESS_DAYS} jours ({seen})")
    return out


def extract(repo: TransformerRepository, raw_dir: Path, *, extractor_version: str = EXTRACTOR_VERSION,
            force: bool = False, log: Callable[[str], None] = print, today: date | None = None) -> ExtractionResult:
    """Extrait les pages à faire ; lève ExtractionBusy si une autre extraction tient le verrou."""
    if not repo.try_lock():
        raise ExtractionBusy("extraction déjà en cours (verrou consultatif occupé)")
    report = ExtractionReport(extractor_version=extractor_version, force=force)
    run_id = repo.open_run(extractor_version)
    try:
        report.out_of_scope = repo.out_of_scope()
        if not force:
            report.up_to_date, report.up_to_date_skipped = repo.count_up_to_date(extractor_version)
            report.up_to_date += report.up_to_date_skipped
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
                if page.is_product:
                    product = parse_product_page(content)
                else:
                    parsed = parse_ranking_page(content)
            except PageSkipped as exc:
                repo.save_skipped(run_id, page.id, str(exc))
                report.skipped.append(page.label)
                continue
            except ParseError as exc:
                repo.save_failure(run_id, page.id, "parse_failed", str(exc))
                report.parse_failures.append(f"{page.label} : {exc}")
                continue
            if page.is_product:
                repo.save_product(run_id, page.id, product)
                report.add_product(product)
                continue
            repo.save_extraction(run_id, page.id, parsed)
            report.extracted += 1
            report.rows += len(parsed.entries)
            report.rows_with_card += sum(e.has_card for e in parsed.entries)
            report.without_display_name += parsed.display_name is None
            report.without_short_name += parsed.short_name is None
        report.ads_freshness = ads_freshness(repo.latest_ads_data_days(), today or datetime.now(UTC).date())
        # CORE : reconstruite après chaque exécution, sous le verrou de l'extracteur (décision 020, section 8)
        try:
            report.core = repo.rebuild_core(extractor_version)
        except CoreBuildError as exc:
            report.core_error = str(exc)
    except BaseException as exc:
        report.error = f"{type(exc).__name__} : {exc}"
        raise
    finally:
        lines = report.lines()
        for line in lines:
            log(line)
        try:
            repo.close_run(run_id, report.status, report.pages_extracted, report.pages_failed, len(report.skipped),
                           "\n".join(lines))
        except Exception as exc:
            if report.error is None:
                raise
            # Erreur d'exécution déjà en cours (ex. : connexion perdue) : elle est conservée, la clôture est signalée
            log(f"Clôture de l'exécution {run_id} impossible : {type(exc).__name__} : {exc}")
    notes = "\n".join(lines)
    return ExtractionResult(run_id=run_id, status=report.status, report=report, notes=notes)
