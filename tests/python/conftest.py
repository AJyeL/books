"""Éléments communs aux tests Python."""

import hashlib
import os
import uuid
from pathlib import Path, PurePosixPath

import pytest

from books.collector.storage import store_raw
from books.amazon.ranking_page import PageRequest

# Fausses pages de test, aux valeurs inventées (voir tests/fixtures/README.md)
FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"
# Catégorie inventée des fixtures
FIXTURE_NODE = "10000000001"


def demande(list_type: str = "paid", page_number: int = 1, node: str = FIXTURE_NODE) -> PageRequest:
    """Demande de page (par défaut : Top payant, page 1, catégorie des fixtures)."""
    return PageRequest(node, list_type, page_number)


@pytest.fixture
def fixture_page():
    """Contenu brut (octets) d'une fausse page, par son nom de fichier."""
    def read(name: str) -> bytes:
        return (FIXTURES / name).read_bytes()
    return read


# --- PostgreSQL 17 jetable (tests de l'extracteur, décision 011) ----------------------------------------------
# Préparé par tests/lancer-tests-postgres.sh : base modèle migrée, mots de passe de test de books_transformer et de
# books_collector, variables BOOKS_TEST_PG_*. Sans elles, les tests qui demandent la fixture « pg » sont sautés.

PG_SKIP = "PostgreSQL de test non configuré : lancer tests/lancer-tests-postgres.sh"


class PgTestDb:
    """Base de test neuve (copie de la base modèle) : connexions et pages RAW de test."""

    def __init__(self, owner, transformer, raw_dir: Path, connect_transformer, connect_collector) -> None:
        self.owner = owner  # propriétaire : prépare raw, que books_transformer ne peut pas écrire
        self.transformer = transformer  # connexion de l'extracteur, avec ses seuls droits
        self.raw_dir = raw_dir
        self.connect_transformer = connect_transformer  # seconde connexion (verrou occupé)
        self.connect_collector = connect_collector  # connexion du collecteur, avec ses seuls droits (autocommit)
        self._run_id = None
        self._count = 0

    def add_page(self, content: bytes, *, method: str | None = "extension-dom", status: str = "ok",
                 page_type: str = "bestseller_list", node: str = "10000000001", list_type: str = "paid",
                 page: int = 1, unique: bool = True) -> int:
        """Dépose une page dans RAW (fichier gzip et ligne raw.raw_page) ; identifiant de la ligne.
        unique : un commentaire numéroté rend le contenu distinct (index unique des captures extension-dom)."""
        if self._run_id is None:
            (self._run_id,) = self.owner.execute(
                "INSERT INTO raw.collect_run (collector_version) VALUES ('test') RETURNING id").fetchone()
        self._count += 1
        if unique:
            content = content + f"\n<!-- page de test {self._count} -->".encode("utf-8")
        relative = PurePosixPath(f"amazon_fr/2026/10/09/run-{self._run_id}/page_{self._count}.html.gz")
        stored = store_raw(self.raw_dir, relative, content)
        product = page_type == "product"
        extension = method == "extension-dom"
        if method is None:  # ligne antérieure à la migration 004 : contrainte NOT VALID levée le temps de l'insertion
            self.owner.execute("ALTER TABLE raw.raw_page DROP CONSTRAINT raw_page_capture_method_nn")
        (page_id,) = self.owner.execute(
            """
            INSERT INTO raw.raw_page (run_id, page_type, category_node, list_type, page_number, asin, requested_url,
                                      fetch_status, content_sha256, content_bytes, storage_path,
                                      capture_method, metadata_path, metadata_sha256)
            VALUES (%s, %s, %s, %s, %s, %s, 'https://test', %s, %s, %s, %s, %s, %s, %s) RETURNING id
            """,
            (self._run_id, page_type, None if product else node, None if product else list_type,
             None if product else page, "B0FAUX0001" if product else None, status,
             stored.sha256, stored.size, stored.relative_path, method,
             "test.json" if extension else None,
             hashlib.sha256(stored.relative_path.encode()).hexdigest() if extension else None),
        ).fetchone()
        if method is None:
            self.owner.execute("ALTER TABLE raw.raw_page ADD CONSTRAINT raw_page_capture_method_nn "
                               "CHECK (capture_method IS NOT NULL) NOT VALID")
        return page_id

    def raw_file(self, page_id: int) -> Path:
        (storage_path,) = self.owner.execute(
            "SELECT storage_path FROM raw.raw_page WHERE id = %s", (page_id,)).fetchone()
        return self.raw_dir.joinpath(*PurePosixPath(storage_path).parts)

    def query(self, sql: str, params=None) -> list[tuple]:
        return self.owner.execute(sql, params).fetchall()


@pytest.fixture
def pg(tmp_path):
    """Base PostgreSQL neuve pour un test, copiée de la base modèle, supprimée à la fin."""
    env = os.environ
    if not env.get("BOOKS_TEST_PG_HOST"):
        pytest.skip(PG_SKIP)
    import psycopg
    from psycopg import sql

    template = env["BOOKS_TEST_PG_TEMPLATE"]
    # Garde-fou : uniquement des bases de test, jamais une base de développement ou de production
    assert template.startswith("books_test_"), template
    server = dict(host=env["BOOKS_TEST_PG_HOST"], port=int(env["BOOKS_TEST_PG_PORT"]), connect_timeout=10)
    owner_login = dict(server, user=env["BOOKS_TEST_PG_OWNER"], password=env["BOOKS_TEST_PG_OWNER_PASSWORD"])
    name = f"books_test_{uuid.uuid4().hex[:12]}"

    def connect_transformer():
        return psycopg.connect(dbname=name, user="books_transformer",
                               password=env["BOOKS_TEST_PG_TRANSFORMER_PASSWORD"], autocommit=True, **server)

    def connect_collector():
        conn = psycopg.connect(dbname=name, user="books_collector",
                               password=env["BOOKS_TEST_PG_COLLECTOR_PASSWORD"], autocommit=True, **server)
        connections.append(conn)  # fermée à la fin du test
        return conn

    with psycopg.connect(dbname="postgres", autocommit=True, **owner_login) as admin:
        admin.execute(sql.SQL("CREATE DATABASE {} TEMPLATE {}").format(sql.Identifier(name), sql.Identifier(template)))
    connections = []
    try:
        owner = psycopg.connect(dbname=name, autocommit=True, **owner_login)
        connections.append(owner)
        transformer = connect_transformer()
        connections.append(transformer)
        raw_dir = tmp_path / "raw"
        raw_dir.mkdir()
        yield PgTestDb(owner, transformer, raw_dir, connect_transformer, connect_collector)
    finally:
        for conn in connections:
            conn.close()
        with psycopg.connect(dbname="postgres", autocommit=True, **owner_login) as admin:
            admin.execute(sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(sql.Identifier(name)))
