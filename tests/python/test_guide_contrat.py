"""Contrat du guide de veille (décision 017, sections 2 et 4) : format du fichier et règles de comparaison.

- check_document : contrôle du format version 1, mêmes règles que la réception sur le PC (scripts/recevoir-guide.ps1)
  et que l'import dans l'extension.
- compare : implémentation de référence des règles de comparaison. Elle sert à vérifier les vecteurs
  (tests/fixtures/guide_vecteurs.json), copiés dans le dépôt de l'extension avec le commit d'origine.
- Un export réel, construit par l'extracteur à partir de fausses pages puis lu par books_reader dans
  guide.export_document, respecte le format (base PostgreSQL de test).
"""

import copy
import json
import re
from datetime import datetime

import pytest

from books.transformer.extraction import extract
from books.transformer.repository import PgTransformerRepository
from conftest import FIXTURES

DATE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
ASIN = re.compile(r"^[A-Z0-9]{10}$")
NODE = re.compile(r"^[0-9]+$")
TOP_KEYS = ["schema_version", "generated_at", "lists", "kindle_asins"]
LIST_KEYS = ["category_node", "list_type", "entries"]
ENTRY_KEYS = ["asin", "rank", "observed_at"]


def _date(value) -> datetime | None:
    if not isinstance(value, str) or not DATE.match(value):
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return None


def _is_int(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def check_document(doc) -> list[str]:
    """Écarts au format version 1 (décision 017, section 4) ; liste vide si le document est conforme."""
    errors = []
    if not isinstance(doc, dict) or list(doc) != TOP_KEYS:
        return [f"clés du document : {list(doc) if isinstance(doc, dict) else type(doc).__name__}"]
    if not _is_int(doc["schema_version"]) or doc["schema_version"] != 1:
        errors.append("schema_version différent de 1")
    generated = _date(doc["generated_at"])
    if generated is None:
        errors.append("generated_at mal formé")
    lists = doc["lists"]
    if not isinstance(lists, list):
        return errors + ["lists n'est pas un tableau"]
    keys = []
    for i, item in enumerate(lists):
        if not isinstance(item, dict) or list(item) != LIST_KEYS:
            errors.append(f"liste {i} : clés inattendues")
            continue
        node, kind, entries = item["category_node"], item["list_type"], item["entries"]
        if not isinstance(node, str) or not NODE.match(node):
            errors.append(f"liste {i} : category_node mal formé")
        if kind not in ("paid", "free"):
            errors.append(f"liste {i} : list_type inconnu")
        keys.append((str(node), str(kind)))
        if not isinstance(entries, list) or not entries:
            errors.append(f"liste {i} : entries vide ou absent")
            continue
        ranks, asins = [], []
        for j, entry in enumerate(entries):
            if not isinstance(entry, dict) or list(entry) != ENTRY_KEYS:
                errors.append(f"liste {i}, entrée {j} : clés inattendues")
                continue
            if not isinstance(entry["asin"], str) or not ASIN.match(entry["asin"]):
                errors.append(f"liste {i}, entrée {j} : asin mal formé")
            if not _is_int(entry["rank"]) or not 1 <= entry["rank"] <= 100:
                errors.append(f"liste {i}, entrée {j} : rank hors de 1 à 100")
            observed = _date(entry["observed_at"])
            if observed is None:
                errors.append(f"liste {i}, entrée {j} : observed_at mal formé")
            elif generated is not None and observed > generated:
                errors.append(f"liste {i}, entrée {j} : observed_at postérieur à generated_at")
            ranks.append(entry["rank"])
            asins.append(entry["asin"])
        if len(set(map(str, asins))) != len(asins) or len(set(map(str, ranks))) != len(ranks):
            errors.append(f"liste {i} : ASIN ou rang en double")
        elif all(_is_int(r) for r in ranks) and ranks != sorted(ranks):
            errors.append(f"liste {i} : entries non triées par rang")
    if keys != sorted(keys) or len(set(keys)) != len(keys):
        errors.append("lists non triées par category_node puis list_type, ou liste en double")
    kindle = doc["kindle_asins"]
    if not isinstance(kindle, list) or not all(isinstance(a, str) and ASIN.match(a) for a in kindle):
        errors.append("kindle_asins mal formé")
    elif kindle != sorted(set(kindle)):
        errors.append("kindle_asins non triés ou en double")
    return errors


def compare(guide: dict, displayed: dict) -> dict:
    """Règles de comparaison de la décision 017 (section 2), implémentation de référence."""
    entries = sorted(displayed["entries"], key=lambda e: e["rank"])
    kindle = set(guide["kindle_asins"])
    missing = [e["asin"] for e in entries if e["asin"] not in kindle]
    reference = next((item for item in guide["lists"] if item["category_node"] == displayed["category_node"]
                      and item["list_type"] == displayed["list_type"]), None)
    if reference is None:
        return {"no_reference": True, "new_entrants": [], "missing_kindle": missing, "rank_changes": []}
    by_asin = {e["asin"]: e for e in reference["entries"]}
    new = [e["asin"] for e in entries if e["asin"] not in by_asin]
    changes = [{"asin": e["asin"], "rank": e["rank"], "reference_rank": by_asin[e["asin"]]["rank"],
                "delta": by_asin[e["asin"]]["rank"] - e["rank"],  # +N : N places gagnées ; -N : N places perdues
                "observed_at": by_asin[e["asin"]]["observed_at"]}
               for e in entries if e["asin"] in by_asin and by_asin[e["asin"]]["rank"] != e["rank"]]
    return {"no_reference": False, "new_entrants": new, "missing_kindle": missing, "rank_changes": changes}


def load(name: str):
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


EXEMPLE = load("guide_exemple.json")
VECTEURS = load("guide_vecteurs.json")


def test_exemple_conforme():
    assert check_document(EXEMPLE) == []


def test_fichiers_du_contrat_en_utf8_sans_bom():
    for name in ("guide_exemple.json", "guide_vecteurs.json"):
        assert not (FIXTURES / name).read_bytes().startswith(b"\xef\xbb\xbf"), name


def _set(path: list, value):
    def mutate(doc):
        target = doc
        for key in path[:-1]:
            target = target[key]
        target[path[-1]] = value
    return mutate


def _delete(path: list):
    def mutate(doc):
        target = doc
        for key in path[:-1]:
            target = target[key]
        del target[path[-1]]
    return mutate


def _add_key(path: list, key: str):
    def mutate(doc):
        target = doc
        for k in path:
            target = target[k]
        target[key] = "x"
    return mutate


# Chaque mutation de l'exemple doit être refusée, avec le motif attendu (contre-épreuves du contrôle de format)
MUTATIONS = [
    ("champ inconnu au premier niveau", _add_key([], "extra"), "clés du document"),
    ("champ manquant au premier niveau", _delete(["kindle_asins"]), "clés du document"),
    ("champ inconnu dans une liste", _add_key(["lists", 0], "extra"), "liste 0 : clés inattendues"),
    ("champ inconnu dans une entrée", _add_key(["lists", 0, "entries", 0], "title"), "entrée 0 : clés inattendues"),
    ("version 2", _set(["schema_version"], 2), "schema_version"),
    ("version en texte", _set(["schema_version"], "1"), "schema_version"),
    ("date sans Z", _set(["generated_at"], "2026-10-11T18:00:00"), "generated_at mal formé"),
    ("date impossible", _set(["generated_at"], "2026-02-30T18:00:00Z"), "generated_at mal formé"),
    ("type de liste inconnu", _set(["lists", 0, "list_type"], "kindle"), "list_type inconnu"),
    ("catégorie non numérique", _set(["lists", 0, "category_node"], "fantasy"), "category_node mal formé"),
    ("catégorie en nombre", _set(["lists", 0, "category_node"], 10000000001), "category_node mal formé"),
    ("liste vide", _set(["lists", 0, "entries"], []), "entries vide"),
    ("ASIN mal formé", _set(["lists", 1, "entries", 0, "asin"], "b0faux0001"), "asin mal formé"),
    ("rang 0", _set(["lists", 1, "entries", 0, "rank"], 0), "rank hors de 1 à 100"),
    ("rang 101", _set(["lists", 1, "entries", 7, "rank"], 101), "rank hors de 1 à 100"),
    ("rang en texte", _set(["lists", 1, "entries", 0, "rank"], "1"), "rank hors de 1 à 100"),
    ("rang booléen", _set(["lists", 1, "entries", 0, "rank"], True), "rank hors de 1 à 100"),
    ("rang en double", _set(["lists", 1, "entries", 1, "rank"], 1), "en double"),
    ("ASIN en double", _set(["lists", 1, "entries", 1, "asin"], "B0FAUX0001"), "en double"),
    ("entrées non triées", _set(["lists", 1, "entries", 0, "rank"], 6), "non triées par rang"),
    ("observation postérieure à l'export", _set(["lists", 0, "entries", 0, "observed_at"], "2026-10-12T00:00:00Z"),
     "postérieur à generated_at"),
    ("listes non triées", _set(["lists", 0, "list_type"], "paid"), "lists non triées"),
    ("fiches Kindle non triées", _set(["kindle_asins"], ["B0FAUX0002", "B0FAUX0001"]), "kindle_asins non triés"),
    ("fiche Kindle en double", _set(["kindle_asins"], ["B0FAUX0001", "B0FAUX0001"]), "kindle_asins non triés"),
    ("fiche Kindle mal formée", _set(["kindle_asins"], ["B0FAUX01"]), "kindle_asins mal formé"),
]


@pytest.mark.parametrize("label, mutate, motif", MUTATIONS, ids=[m[0] for m in MUTATIONS])
def test_document_non_conforme_refuse(label, mutate, motif):
    doc = copy.deepcopy(EXEMPLE)
    mutate(doc)
    errors = check_document(doc)
    assert any(motif in e for e in errors), (label, errors)


def test_vecteurs_sur_l_exemple():
    assert VECTEURS["guide"] == "guide_exemple.json"
    assert check_document(load(VECTEURS["guide"])) == []


@pytest.mark.parametrize("case", VECTEURS["cases"], ids=[c["name"] for c in VECTEURS["cases"]])
def test_vecteur(case):
    assert compare(EXEMPLE, case["displayed"]) == case["expected"]


def test_vecteurs_couvrent_les_regles():
    # Sans ces situations, les vecteurs ne fixeraient pas les règles de la section 2
    changes = [c for case in VECTEURS["cases"] for c in case["expected"]["rank_changes"]]
    deltas = {c["delta"] for c in changes}
    assert {1, -1} <= deltas  # changement d'une seule place, dans les deux sens
    assert any(c["reference_rank"] > 50 >= c["rank"] for c in changes)  # montée de la page 2 à la page 1
    assert any(c["reference_rank"] <= 50 < c["rank"] for c in changes)  # descente de la page 1 à la page 2
    assert len({c["observed_at"] for c in changes}) > 1  # dates de référence différentes selon la page
    assert any(case["expected"]["no_reference"] for case in VECTEURS["cases"])
    assert any(not any(case["expected"][k] for k in ("new_entrants", "missing_kindle", "rank_changes"))
               and not case["expected"]["no_reference"] for case in VECTEURS["cases"])  # écarts nuls
    for case in VECTEURS["cases"]:
        expected = case["expected"]
        ranks = {e["asin"]: e["rank"] for e in case["displayed"]["entries"]}
        for key in ("new_entrants", "missing_kindle"):
            assert [ranks[a] for a in expected[key]] == sorted(ranks[a] for a in expected[key]), (case["name"], key)
        assert [c["rank"] for c in expected["rank_changes"]] == sorted(c["rank"] for c in expected["rank_changes"])
        assert all(c["delta"] == c["reference_rank"] - c["rank"] != 0 for c in expected["rank_changes"])


def test_export_reel_conforme(pg):
    """Pages de test extraites par l'extracteur, puis document lu par books_reader dans guide.export_document."""
    pg.add_page((FIXTURES / "extraction_page1_complete.html").read_bytes())
    pg.add_page((FIXTURES / "fiche_extraction_exemple.html").read_bytes(), page_type="product", asin="B0FAUX0001")
    pg.add_page((FIXTURES / "fiche_extraction_papier.html").read_bytes(), page_type="product", asin="2000000001")
    result = extract(PgTransformerRepository(pg.transformer), pg.raw_dir, log=lambda _: None)
    assert result.status == "success"

    pg.owner.execute("SET ROLE books_reader")
    try:
        (document,) = pg.owner.execute("SELECT document FROM guide.export_document").fetchone()
        (fetched_at,) = pg.owner.execute(
            "SELECT to_char(fetched_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') FROM raw.raw_page "
            "WHERE page_type = 'bestseller_list'").fetchone()
    finally:
        pg.owner.execute("RESET ROLE")
    doc = json.loads(document) if isinstance(document, str) else document

    assert check_document(doc) == []
    assert [(item["category_node"], item["list_type"]) for item in doc["lists"]] == [("10000000001", "paid")]
    entries = doc["lists"][0]["entries"]
    assert [e["rank"] for e in entries] == list(range(1, 51))
    assert {e["observed_at"] for e in entries} == {fetched_at}
    assert doc["kindle_asins"] == ["B0FAUX0001"]  # la fiche papier (skipped) n'y est pas

    # La page de référence réaffichée telle quelle : aucun entrant, aucun changement (rythme d'usage, section 6)
    displayed = {"category_node": "10000000001", "list_type": "paid", "page": 1,
                 "entries": [{"asin": e["asin"], "rank": e["rank"]} for e in entries]}
    result = compare(doc, displayed)
    assert result["new_entrants"] == [] and result["rank_changes"] == [] and not result["no_reference"]
