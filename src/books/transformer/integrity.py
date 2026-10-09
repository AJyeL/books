"""Intégrité d'une page RAW avant son extraction (décision 011, section 2).

Le fichier est stocké compressé en gzip (books.collector.storage) ; content_sha256 et content_bytes portent sur le
contenu d'origine, non compressé. Le fichier est donc décompressé, puis sa taille et son empreinte sont comparées
à celles enregistrées dans raw.raw_page. RAW n'est jamais modifié : le fichier est seulement lu.
"""

import gzip
import hashlib
import zlib
from pathlib import Path, PurePosixPath


class RawIntegrityError(Exception):
    """Le fichier RAW ne correspond pas à sa ligne de raw.raw_page ; le message donne le motif."""


def read_raw_page(raw_dir: Path, storage_path: str, content_sha256: str, content_bytes: int) -> bytes:
    """Contenu d'origine d'une page RAW, vérifié ; lève RawIntegrityError en cas d'écart."""
    relative = PurePosixPath(storage_path)
    # storage_path est relatif à BOOKS_RAW_DIR : un chemin absolu ou remontant (« .. ») sortirait du dossier
    if relative.is_absolute() or ".." in relative.parts or not relative.parts:
        raise RawIntegrityError(f"emplacement RAW invalide : {storage_path!r}")
    path = raw_dir.joinpath(*relative.parts)
    try:
        compressed = path.read_bytes()
    except FileNotFoundError:
        raise RawIntegrityError(f"fichier RAW absent : {storage_path}") from None
    except OSError as exc:
        raise RawIntegrityError(f"fichier RAW illisible : {storage_path} ({exc.strerror})") from None
    try:
        content = gzip.decompress(compressed)
    except (OSError, EOFError, zlib.error):
        raise RawIntegrityError(f"fichier RAW non décompressible : {storage_path}") from None
    if len(content) != content_bytes:
        raise RawIntegrityError(
            f"taille différente : {len(content)} octets au lieu de {content_bytes} ({storage_path})")
    if hashlib.sha256(content).hexdigest() != content_sha256:
        raise RawIntegrityError(f"empreinte SHA-256 différente ({storage_path})")
    return content
