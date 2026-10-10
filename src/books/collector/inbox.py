"""Lecture des lots de inbox/, contrôles d'intégrité des captures et quarantaine (décisions 007 et 008).

- Les lots (inbox/{lot}/) sont lus dans l'ordre de leur nom (horodatage UTC du transfert),
  puis les fichiers dans l'ordre de leur nom.
- Rien n'est ignoré en silence : tout fichier hors format est mis en quarantaine, ou, faute de lot valide,
  signalé et laissé en place.
- Seules les captures de l'extension (extension-dom, format de la décision 007) sont acceptées ;
  les pages enregistrées à la main restent réservées au développement.
- Deux sortes de captures : les pages de classement (amazon_fr_bestsellers_…) et les fiches produit
  (amazon_fr_product_{ASIN}_…, décision 015).
"""

import hashlib
import json
import os
import re
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

# Adresses acceptables : définitions communes d'une page de classement (décision 014) et d'une fiche (décision 015)
from books.amazon.product_page import ProductRequest, asin_from_url
from books.amazon.ranking_page import PageRequest, request_from_url

EXTENSION_DOM = "extension-dom"
SCHEMA_VERSION = 1
# Champs du JSON, version 1 du schéma (décision 007, section 4), avec leur type exact
SCHEMA_FIELDS = {
    "schema_version": int,
    "displayed_url": str,
    "captured_at": str,
    "capture_method": str,
    "extension_version": str,
    "user_agent": str,
    "html_sha256": str,
    "html_bytes": int,
}
LOT_NAME = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z")
_STAMP = r"([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z"
# Nom d'une capture de page de classement sans son extension (décision 007, section 2)
CAPTURE_STEM = re.compile(r"amazon_fr_bestsellers_([0-9]+)_(paid|free)_p([12])_" + _STAMP)
# Nom d'une capture de fiche produit sans son extension (décision 015, section 4 ; décision 007 amendée)
PRODUCT_STEM = re.compile(r"amazon_fr_product_([A-Z0-9]{10})_" + _STAMP)
SHA256 = re.compile(r"[0-9a-f]{64}")


# --- Ce que contient inbox/ -------------------------------------------------------------

@dataclass(frozen=True)
class Pair:
    """Deux fichiers jumeaux au nom conforme, à contrôler."""
    lot: str
    stem: str
    html_path: Path
    json_path: Path


@dataclass(frozen=True)
class LoneHtml:
    """HTML sans son JSON : déjà ingéré (interruption pendant le retrait), ou orphelin."""
    lot: str
    stem: str
    html_path: Path


@dataclass(frozen=True)
class Rejected:
    """Fichier(s) à mettre en quarantaine, avec la raison."""
    lot: str
    stem: str
    paths: tuple[Path, ...]
    reason: str


@dataclass(frozen=True)
class Untouchable:
    """Élément signalé et laissé en place : faute de lot valide, aucune quarantaine possible."""
    path: Path
    reason: str


@dataclass(frozen=True)
class Capture:
    """Capture intègre, prête à être validée et déposée dans RAW."""
    lot: str
    stem: str
    html_path: Path
    json_path: Path
    request: PageRequest | ProductRequest
    captured_at: datetime
    displayed_url: str
    html: bytes
    json_bytes: bytes
    html_sha256: str
    json_sha256: str

    @property
    def label(self) -> str:
        return f"{self.lot}/{self.stem}"


def is_capture_stem(stem: str) -> bool:
    """Nom conforme d'une capture : page de classement ou fiche produit."""
    return bool(CAPTURE_STEM.fullmatch(stem) or PRODUCT_STEM.fullmatch(stem))


def scan_inbox(inbox_dir: Path) -> list[Pair | LoneHtml | Rejected | Untouchable]:
    """Inventaire ordonné de inbox/. Ne lit ni ne modifie aucun fichier."""
    items: list[Pair | LoneHtml | Rejected | Untouchable] = []
    for entry in sorted(inbox_dir.iterdir(), key=lambda p: p.name):
        if not entry.is_dir():
            items.append(Untouchable(entry, "fichier hors de tout lot"))
        elif not LOT_NAME.fullmatch(entry.name):
            items.append(Untouchable(entry, "dossier de lot au nom hors format"))
        else:
            items.extend(_scan_lot(entry))
    return items


def _scan_lot(lot_dir: Path) -> list[Pair | LoneHtml | Rejected | Untouchable]:
    lot = lot_dir.name
    by_stem: dict[str, dict[str, Path]] = {}
    items: list[Pair | LoneHtml | Rejected | Untouchable] = []
    for entry in sorted(lot_dir.iterdir(), key=lambda p: p.name):
        if entry.is_dir():
            items.append(Untouchable(entry, "sous-dossier dans un lot"))
            continue
        if entry.suffix in (".html", ".json") and is_capture_stem(entry.stem):
            by_stem.setdefault(entry.stem, {})[entry.suffix] = entry
        else:
            items.append(Rejected(lot, entry.name, (entry,), "nom hors format (décision 007, section 2)"))
    for stem in sorted(by_stem):
        files = by_stem[stem]
        if ".html" in files and ".json" in files:
            items.append(Pair(lot, stem, files[".html"], files[".json"]))
        elif ".html" in files:
            items.append(LoneHtml(lot, stem, files[".html"]))
        else:
            items.append(Rejected(lot, stem, (files[".json"],), "JSON orphelin : HTML jumeau absent"))
    # Ordre des noms dans le lot (les rejets et les captures, mêlés)
    return sorted(items, key=lambda i: i.path.name if isinstance(i, Untouchable)
                  else (i.paths[0].name if isinstance(i, Rejected) else i.stem))


# --- Contrôles d'intégrité (décision 007, section 6) ---------------------------------------
# L'adresse affichée est lue par request_from_url (books.amazon.ranking_page, décision 014) pour une page de
# classement, par asin_from_url (books.amazon.product_page, décision 015) pour une fiche.

def _check_displayed_url(url: str, expected: PageRequest | ProductRequest) -> tuple[PageRequest | ProductRequest | None,
                                                                                    str | None]:
    """Demande déduite de l'adresse affichée, à comparer à celle du nom ; ou motif de refus."""
    if isinstance(expected, ProductRequest):
        asin, why = asin_from_url(url)
        if asin is None:
            return None, f"displayed_url : {why}"
        if asin != expected.asin:
            return None, f"displayed_url (fiche {asin}) différente du nom (fiche {expected.asin})"
        return ProductRequest(asin), None
    request, why = request_from_url(url)
    if request is None:
        return None, f"displayed_url : {why}"
    if request != expected:
        return None, (f"displayed_url ({request.label}) différente du nom "
                      f"({expected.node} {expected.list_type} p{expected.page_number})")
    return request, None


def check_capture(pair: Pair) -> Capture | Rejected:
    """Contrôles d'intégrité de la décision 007 (section 6). Toute page de classement Kindle d'amazon.fr est dans le
    périmètre (décision 014) : l'adresse affichée suffit, aucune liste de catégories n'est consultée. Pour une fiche
    (décision 015), l'ASIN de l'adresse affichée doit être celui du nom."""
    def reject(reason: str) -> Rejected:
        return Rejected(pair.lot, pair.stem, (pair.html_path, pair.json_path), reason)

    named: PageRequest | ProductRequest  # demande d'après le nom du fichier
    if name := CAPTURE_STEM.fullmatch(pair.stem):
        named = PageRequest(name.group(1), name.group(2), int(name.group(3)))
        stamp = name.groups()[3:]
    else:
        name = PRODUCT_STEM.fullmatch(pair.stem)
        named = ProductRequest(name.group(1))
        stamp = name.groups()[1:]
    year, month, day, hour, minute, second = (int(g) for g in stamp)

    json_bytes = pair.json_path.read_bytes()
    if json_bytes.startswith(b"\xef\xbb\xbf"):
        return reject("JSON : marque d'ordre des octets (BOM) interdite")
    try:
        meta = json.loads(json_bytes.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        return reject(f"JSON illisible : {exc}")
    if not isinstance(meta, dict):
        return reject("JSON : un objet est attendu")
    if set(meta) != set(SCHEMA_FIELDS):
        missing, extra = set(SCHEMA_FIELDS) - set(meta), set(meta) - set(SCHEMA_FIELDS)
        return reject(f"JSON : champs manquants {sorted(missing)}, champs inconnus {sorted(extra)}")
    for field_name, expected in SCHEMA_FIELDS.items():
        if type(meta[field_name]) is not expected:  # type exact : un booléen n'est pas un entier
            return reject(f"JSON : {field_name} doit être de type {expected.__name__}")
    if meta["schema_version"] != SCHEMA_VERSION:
        return reject(f"JSON : schema_version {meta['schema_version']} non prise en charge")
    if meta["capture_method"] != EXTENSION_DOM:
        return reject(f"JSON : capture_method {meta['capture_method']!r}, {EXTENSION_DOM!r} attendu")

    try:
        captured_at = datetime(year, month, day, hour, minute, second, tzinfo=UTC)
    except ValueError:
        return reject("horodatage du nom impossible (date ou heure inexistante)")
    if meta["captured_at"] != captured_at.strftime("%Y-%m-%dT%H:%M:%SZ"):
        return reject("captured_at différent de l'horodatage du nom")

    request, why = _check_displayed_url(meta["displayed_url"], named)
    if request is None:
        return reject(why)

    html = pair.html_path.read_bytes()
    if not SHA256.fullmatch(meta["html_sha256"]):
        return reject("JSON : html_sha256 mal formé")
    if len(html) != meta["html_bytes"]:
        return reject(f"taille du HTML {len(html)} octets, {meta['html_bytes']} annoncés")
    html_sha256 = hashlib.sha256(html).hexdigest()
    if html_sha256 != meta["html_sha256"]:
        return reject("empreinte du HTML différente de html_sha256")

    return Capture(
        lot=pair.lot, stem=pair.stem, html_path=pair.html_path, json_path=pair.json_path,
        request=request, captured_at=captured_at, displayed_url=meta["displayed_url"],
        html=html, json_bytes=json_bytes, html_sha256=html_sha256,
        json_sha256=hashlib.sha256(json_bytes).hexdigest(),
    )


# --- Quarantaine et retrait ---------------------------------------------------------------

class QuarantineError(Exception):
    """Mise en quarantaine impossible sans écraser un fichier déjà présent."""


def quarantine(rejected: Rejected, quarantine_dir: Path) -> Path:
    """Déplace les fichiers dans quarantaine/{lot}/, avec {nom}.raison.txt. Jamais d'écrasement.

    Déplacement par lien physique puis suppression de l'ancien nom : contrairement à un renommage,
    la création du lien échoue si la destination existe déjà.
    """
    target_dir = quarantine_dir / rejected.lot
    reason_path = target_dir / f"{rejected.stem}.raison.txt"
    destinations = [target_dir / p.name for p in rejected.paths]
    taken = [d for d in (reason_path, *destinations) if d.exists()]
    if taken:
        raise QuarantineError(f"déjà présent en quarantaine : {', '.join(d.name for d in taken)}")
    target_dir.mkdir(parents=True, exist_ok=True)
    now = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(reason_path, "x", encoding="utf-8", newline="\n") as f:
        f.write(f"Raison : {rejected.reason}\nLot : {rejected.lot}\n"
                f"Fichiers : {', '.join(p.name for p in rejected.paths)}\nMis en quarantaine le : {now}\n")
    for source, destination in zip(rejected.paths, destinations):
        os.link(source, destination)
        os.remove(source)
    return target_dir


def remove_capture(json_path: Path | None, html_path: Path) -> None:
    """Retire une capture de inbox/ : le JSON d'abord, le HTML ensuite (décision 008).

    Une interruption entre les deux laisse un HTML seul, reconnu « déjà ingéré » par son empreinte.
    """
    if json_path is not None:
        os.remove(json_path)
    os.remove(html_path)


def remove_empty_lots(inbox_dir: Path) -> list[str]:
    """Supprime les dossiers de lot vides ; renvoie leurs noms."""
    removed = []
    for entry in sorted(inbox_dir.iterdir()):
        if entry.is_dir() and LOT_NAME.fullmatch(entry.name) and not any(entry.iterdir()):
            entry.rmdir()
            removed.append(entry.name)
    return removed
