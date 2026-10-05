"""Tests de books.collector.targets : fichier des cibles et pages à demander."""

from pathlib import Path

import pytest

from books.collector.targets import (
    MAX_REQUESTS_PER_RUN, PageRequest, TargetsError, canonical_url, load_targets, plan_requests,
)

REPO_TARGETS = Path(__file__).resolve().parents[2] / "config" / "targets.toml"


def write(tmp_path, text: str) -> Path:
    path = tmp_path / "targets.toml"
    path.write_text(text, encoding="utf-8")
    return path


def category(node: str, lists: str = '["paid"]') -> str:
    return f'[[categorie]]\nnode = "{node}"\nnom = "Catégorie {node}"\nlistes = {lists}\n\n'


def test_fichier_du_depot_valide():
    categories = load_targets(REPO_TARGETS)
    requests = plan_requests(categories)
    assert len(requests) == len(categories) >= 1
    assert all(r.list_type == "paid" and r.page_number == 1 for r in requests)


def test_pages_demandees(tmp_path):
    path = write(tmp_path, category("10000000001") + category("10000000002"))
    assert plan_requests(load_targets(path)) == [
        PageRequest("10000000001", "paid", 1),
        PageRequest("10000000002", "paid", 1),
    ]


def test_adresse_de_la_page_1():
    request = PageRequest("10000000001", "paid", 1)
    assert request.url == canonical_url("10000000001") == \
        "https://www.amazon.fr/gp/bestsellers/digital-text/10000000001"
    assert request.label == "10000000001 paid p1"


def test_fichier_absent(tmp_path):
    with pytest.raises(TargetsError, match="introuvable"):
        load_targets(tmp_path / "absent.toml")


def test_toml_illisible(tmp_path):
    with pytest.raises(TargetsError, match="illisible"):
        load_targets(write(tmp_path, "[[categorie]\n"))


def test_aucune_categorie(tmp_path):
    with pytest.raises(TargetsError, match="Aucune catégorie"):
        load_targets(write(tmp_path, "# vide\n"))


@pytest.mark.parametrize("node", ["", "12a45", "12 345", "-1"])
def test_node_invalide(tmp_path, node):
    with pytest.raises(TargetsError, match="chaîne de chiffres"):
        load_targets(write(tmp_path, category(node)))


def test_node_numerique_non_texte(tmp_path):
    text = '[[categorie]]\nnode = 10000000001\nnom = "X"\nlistes = ["paid"]\n'
    with pytest.raises(TargetsError, match="chaîne de chiffres"):
        load_targets(write(tmp_path, text))


def test_doublon(tmp_path):
    with pytest.raises(TargetsError, match="deux fois"):
        load_targets(write(tmp_path, category("10000000001") * 2))


def test_liste_gratuite_pas_encore_prise_en_charge(tmp_path):
    with pytest.raises(TargetsError, match="non prise en charge"):
        load_targets(write(tmp_path, category("10000000001", '["paid", "free"]')))


def test_plafond_de_requetes(tmp_path):
    # Chaque liste peut compter 2 pages : 101 catégories = 202 requêtes possibles > 200
    count = MAX_REQUESTS_PER_RUN // 2 + 1
    text = "".join(category(str(10000000000 + i)) for i in range(count))
    with pytest.raises(TargetsError, match="plafond"):
        load_targets(write(tmp_path, text))


def test_plafond_atteint_sans_le_depasser(tmp_path):
    count = MAX_REQUESTS_PER_RUN // 2
    text = "".join(category(str(10000000000 + i)) for i in range(count))
    assert len(load_targets(write(tmp_path, text))) == count
