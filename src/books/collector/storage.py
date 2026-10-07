"""Dépôt des pages brutes sur disque (couche RAW, décision 001).

- Fichier compressé en gzip, jamais écrasé (création exclusive, mode « xb »).
- Empreinte SHA-256 et taille calculées sur le HTML d'origine, non compressé.
  L'empreinte sert à vérifier l'intégrité, jamais à dédoublonner : chaque réponse
  d'Amazon contient des jetons propres à la requête.
"""

import gzip
import hashlib
import os
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path, PurePosixPath

from books.collector.targets import PageRequest

SOURCE = "amazon_fr"


@dataclass(frozen=True)
class StoredFile:
    relative_path: str  # relatif à BOOKS_RAW_DIR : valable sur le PC comme sur atlas
    sha256: str
    size: int  # octets du HTML d'origine


def raw_relative_path(run_id: int, run_started_at: datetime, request: PageRequest) -> PurePosixPath:
    """Emplacement d'une page : amazon_fr/AAAA/MM/JJ/run-{id}/bestsellers_{node}_{liste}_p{n}.html.gz"""
    day = run_started_at.strftime("%Y/%m/%d")
    name = f"bestsellers_{request.node}_{request.list_type}_p{request.page_number}.html.gz"
    return PurePosixPath(SOURCE, day, f"run-{run_id}", name)


def capture_relative_paths(run_id: int, run_started_at: datetime, request: PageRequest,
                           captured_at: datetime) -> tuple[PurePosixPath, PurePosixPath]:
    """Emplacements du HTML et du JSON d'une capture (décision 008) :
    amazon_fr/AAAA/MM/JJ/run-{id}/bestsellers_{node}_{liste}_p{n}_{AAAA-MM-JJTHHMMSSZ}.html.gz (et .json.gz).

    L'horodatage de la capture distingue deux observations de la même page dans une même ingestion.
    """
    day = run_started_at.strftime("%Y/%m/%d")
    stem = (f"bestsellers_{request.node}_{request.list_type}_p{request.page_number}_"
            f"{captured_at.strftime('%Y-%m-%dT%H%M%SZ')}")
    folder = PurePosixPath(SOURCE, day, f"run-{run_id}")
    return folder / f"{stem}.html.gz", folder / f"{stem}.json.gz"


def store_raw(raw_dir: Path, relative_path: PurePosixPath, content: bytes) -> StoredFile:
    """Écrit la page compressée. Lève FileExistsError plutôt que d'écraser un fichier existant."""
    if not raw_dir.is_dir():
        raise FileNotFoundError(f"Dossier des pages brutes introuvable : {raw_dir}")
    path = raw_dir.joinpath(*relative_path.parts)
    path.parent.mkdir(parents=True, exist_ok=True)
    # mtime=0 : l'en-tête gzip ne contient pas la date, la compression est reproductible
    data = gzip.compress(content, mtime=0)
    with open(path, "xb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())  # données réellement écrites sur le disque avant l'enregistrement en base
    return StoredFile(
        relative_path=relative_path.as_posix(),
        sha256=hashlib.sha256(content).hexdigest(),
        size=len(content),
    )
