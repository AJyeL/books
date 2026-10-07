"""Verrou d'ingestion : une seule ingestion à la fois (décision 008).

Verrou consultatif du noyau (flock) sur BOOKS_CAPTURES_DIR/ingestion.lock :
- partagé entre les conteneurs, puisque le fichier est sur le disque de l'hôte (dossier monté) ;
- pris sans attendre : si une autre ingestion le tient, la prise échoue immédiatement ;
- libéré par le noyau à la fin du processus, quelle qu'en soit la raison (fin normale, plantage, arrêt forcé) :
  aucun verrou fantôme possible.
Le fichier n'est jamais supprimé : le supprimer permettrait à deux processus de croire tenir chacun le verrou.
Il est placé hors de inbox/, où il serait pris pour un fichier hors format.
"""

import fcntl
import os
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

LOCK_NAME = "ingestion.lock"


class LockBusy(Exception):
    """Une autre ingestion tient déjà le verrou."""


@contextmanager
def ingestion_lock(captures_dir: Path) -> Iterator[Path]:
    """Tient le verrou d'ingestion pendant le bloc « with » ; lève LockBusy s'il est déjà pris."""
    path = captures_dir / LOCK_NAME
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise LockBusy(f"ingestion déjà en cours (verrou {path} tenu par un autre processus)") from None
        yield path
    finally:
        os.close(fd)  # fermer le descripteur rend le verrou ; le noyau le ferait aussi si le processus mourait
