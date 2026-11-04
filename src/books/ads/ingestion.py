"""Ingestion des rapports Amazon Ads de inbox/ dans RAW (décision 018, lot A).

Pour chaque élément de inbox/, dans l'ordre des lots (horodatage UTC du transfert) puis des noms :
1. un élément hors lot, un sous-dossier, un élément qui n'est pas un fichier ordinaire ou un fichier de plus de
   20 Mo est signalé et laissé en place (anomalie) ;
2. « déjà ingéré » : un fichier dont l'empreinte est déjà dans RAW est retiré, sans nouvelle ligne ni anomalie ;
3. nature du fichier (books.ads.validation) ; le fichier est déposé dans RAW, compressé, jamais écrasé, avec son
   statut : ok, ou invalid avec son motif (anomalie). Aucun fichier n'est ignoré ni mis en quarantaine ;
4. ligne raw.ads_report_file validée en base, puis retrait de inbox/.
Le contenu (forme CSV, colonnes requises, valeurs, doublons) n'est pas jugé ici : il le sera à l'extraction (lot B).

Statuts : success (aucune anomalie), partial (au moins une anomalie), failed (erreur d'exécution).
"""

import hashlib
import os
import re
import stat
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath

from books.ads.repository import AdsRepository, AdsRunInfo, ReportRecord
from books.ads.validation import classify
from books.collector.run import EXIT_CODES
from books.collector.storage import store_raw

INBOX = "inbox"
SOURCE = "amazon_ads"
MAX_FILE_BYTES = 20 * 1024 * 1024  # 20 Mo ; les rapports observés pèsent moins de 1 Mo
LOT_NAME = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z")
TYPE_LABELS = {"advertised_product": "Advertised product", "search_term": "Search term"}


@dataclass
class AdsReport:
    """Ce qu'une ingestion a fait, pour le bilan et les notes de l'exécution."""
    run_id: int
    lots: list[str] = field(default_factory=list)
    deposited_ok: list[str] = field(default_factory=list)
    deposited_invalid: list[str] = field(default_factory=list)  # avec le motif
    already: list[str] = field(default_factory=list)
    left_in_place: list[str] = field(default_factory=list)
    information: list[str] = field(default_factory=list)
    error: str | None = None

    @property
    def anomalies(self) -> int:
        return len(self.deposited_invalid) + len(self.left_in_place)

    @property
    def status(self) -> str:
        if self.error:
            return "failed"
        return "success" if self.anomalies == 0 else "partial"

    def lines(self) -> list[str]:
        """Bilan lisible : noms de fichiers, types, dates d'export et motifs, aucune valeur des lignes."""
        def block(title: str, entries: list[str]) -> list[str]:
            return [f"  {title:<19}: {len(entries)}"] + [f"    - {e}" for e in entries]

        out = [f"Bilan de l'ingestion de rapports Ads {self.run_id} — lot(s) : {', '.join(self.lots) or 'aucun'}"]
        out += block("Déposés ok", self.deposited_ok)
        out += block("Déposés invalid", self.deposited_invalid)
        out += block("Déjà ingérés", self.already)
        out += block("Laissés en place", self.left_in_place)
        out += block("Informations", self.information)
        if self.error:
            out.append(f"  {'Erreur':<19}: {self.error}")
        out.append(f"Résultat : {self.status}, {self.anomalies} anomalie(s) — code de sortie {EXIT_CODES[self.status]}")
        return out


@dataclass(frozen=True)
class AdsIngestionResult:
    run_id: int
    status: str
    report: AdsReport


def report_relative_path(run: AdsRunInfo, sha256: str) -> PurePosixPath:
    """Emplacement d'un fichier de rapport : amazon_ads/AAAA/MM/JJ/run-{id}/{empreinte}.csv.gz"""
    return PurePosixPath(SOURCE, run.started_at.strftime("%Y/%m/%d"), f"run-{run.id}", f"{sha256}.csv.gz")


def _scan_inbox(inbox_dir: Path, report: AdsReport) -> list[tuple[str, Path]]:
    """(lot, fichier) à traiter, dans l'ordre ; tout le reste est signalé et laissé en place."""
    files = []
    for entry in sorted(inbox_dir.iterdir(), key=lambda p: p.name):
        if not entry.is_dir() or entry.is_symlink():
            report.left_in_place.append(f"{entry.name} : élément hors de tout lot")
            continue
        if not LOT_NAME.fullmatch(entry.name):
            report.left_in_place.append(f"{entry.name} : dossier de lot au nom hors format")
            continue
        report.lots.append(entry.name)
        for item in sorted(entry.iterdir(), key=lambda p: p.name):
            label = f"{entry.name}/{item.name}"
            mode = item.lstat().st_mode
            if stat.S_ISDIR(mode):
                report.left_in_place.append(f"{label} : sous-dossier dans un lot")
            elif not stat.S_ISREG(mode):
                report.left_in_place.append(f"{label} : pas un fichier ordinaire")
            elif item.lstat().st_size > MAX_FILE_BYTES:
                report.left_in_place.append(f"{label} : plus de 20 Mo")
            else:
                files.append((entry.name, item))
    return files


def _remove_empty_lots(inbox_dir: Path) -> list[str]:
    removed = []
    for entry in sorted(inbox_dir.iterdir(), key=lambda p: p.name):
        if entry.is_dir() and not entry.is_symlink() and LOT_NAME.fullmatch(entry.name) and not any(entry.iterdir()):
            entry.rmdir()
            removed.append(entry.name)
    return removed


def ingest_reports(
    ads_dir: Path,
    repo: AdsRepository,
    raw_dir: Path,
    collector_version: str,
    log: Callable[[str], None] = print,
) -> AdsIngestionResult:
    inbox_dir = ads_dir / INBOX
    if not inbox_dir.is_dir():
        raise FileNotFoundError(f"Dossier des rapports à ingérer introuvable : {inbox_dir}")
    if not raw_dir.is_dir():
        raise FileNotFoundError(f"Dossier des pages brutes introuvable : {raw_dir}")

    run = repo.open_run(collector_version)
    report = AdsReport(run_id=run.id)
    log(f"Ingestion de rapports Ads {run.id} ouverte : {inbox_dir}.")
    try:
        for lot, path in _scan_inbox(inbox_dir, report):
            label = f"{lot}/{path.name}"
            content = path.read_bytes()
            sha256 = hashlib.sha256(content).hexdigest()
            if repo.find_report(sha256) is not None:
                os.remove(path)
                report.already.append(label)
                continue

            verdict = classify(path.name, content)
            stored = store_raw(raw_dir, report_relative_path(run, sha256), content)
            repo.record_report(run.id, ReportRecord(
                lot=lot, original_name=path.name, stored=stored, status=verdict.status, reason=verdict.reason,
                report_type=verdict.report_type, export_date=verdict.export_date, export_time=verdict.export_time,
            ))
            # Fichier écrit et synchronisé, ligne validée (autocommit) : il peut quitter inbox/
            os.remove(path)
            kind = TYPE_LABELS.get(verdict.report_type, "type inconnu")
            exported = f"export du {verdict.export_date.isoformat()}" if verdict.export_date else "date d'export illisible"
            if verdict.status == "ok":
                report.deposited_ok.append(f"{label} : {kind}, {exported}")
            else:
                report.deposited_invalid.append(f"{label} : {kind}, {exported} : {verdict.reason}")
            log(f"  {label} : {verdict.status}")

        removed = _remove_empty_lots(inbox_dir)
        if removed:
            report.information.append(f"lots vidés et supprimés : {', '.join(removed)}")
    except BaseException as exc:
        report.error = f"{type(exc).__name__} : {exc}"
        raise
    finally:
        lines = report.lines()
        for line in lines:
            log(line)
        repo.close_run(run.id, report.status, len(report.deposited_ok), len(report.deposited_invalid),
                       "\n".join(lines))
    return AdsIngestionResult(run_id=run.id, status=report.status, report=report)
