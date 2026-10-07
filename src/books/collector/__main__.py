"""Point d'entrée du collecteur : python -m books.collector

- En prod : ingestion des captures de l'extension déposées dans BOOKS_CAPTURES_DIR/inbox/ (décision 008).
- En dev : tournée sur les pages enregistrées à la main (data/samples/, manual-html).

Codes de sortie (décision 008) : 0 aucune anomalie ; 1 au moins une anomalie (statut partial), erreur d'exécution
(statut failed) ou erreur de base de données ; 2 configuration invalide.
"""

import os
import sys
from collections.abc import Callable
from contextlib import AbstractContextManager, nullcontext
from pathlib import Path

import psycopg

from books import __version__
from books.collector.inbox import perimeter_of
from books.collector.ingestion import ingest
from books.collector.lock import LockBusy, ingestion_lock
from books.collector.repository import PgRepository
from books.collector.run import EXIT_CODES, RunResult, collect
from books.collector.sources import SourceError, make_source
from books.collector.targets import TargetsError, load_targets, plan_requests
from books.config import ConfigError, load_config


def main() -> int:
    try:
        config = load_config()
        categories = load_targets(config.targets_file)
        if not config.raw_dir.is_dir():
            raise ConfigError(f"Dossier des pages brutes introuvable : {config.raw_dir}")
        task: Callable[[PgRepository], RunResult]
        lock: AbstractContextManager = nullcontext()  # la tournée de dev n'a pas besoin de verrou
        if config.env == "prod":
            captures = os.environ.get("BOOKS_CAPTURES_DIR", "").strip()
            if not captures:
                raise ConfigError("BOOKS_CAPTURES_DIR est absente ou vide (dossier des captures à ingérer).")
            captures_dir = Path(captures)
            if not (captures_dir / "inbox").is_dir():
                raise ConfigError(f"Dossier des captures à ingérer introuvable : {captures_dir / 'inbox'}")
            perimeter = perimeter_of(categories)
            lock = ingestion_lock(captures_dir)  # pris avant toute connexion à la base
            task = lambda repo: ingest(captures_dir, perimeter, repo, config.raw_dir, __version__)  # noqa: E731
        else:
            requests = plan_requests(categories)
            source = make_source(config.env, os.environ)
            task = lambda repo: collect(requests, source, repo, config.raw_dir, __version__)  # noqa: E731
    except (ConfigError, TargetsError, SourceError) as exc:
        print(f"Erreur de configuration : {exc}", file=sys.stderr)
        return 2

    print(f"B.O.O.K.S. collecteur {__version__} — environnement : {config.env}")
    print(f"Dossier des pages brutes : {config.raw_dir}")

    try:
        with lock, psycopg.connect(
            host=config.db_host,
            port=config.db_port,
            dbname=config.db_name,
            user=config.db_user,
            password=config.db_password,
            connect_timeout=10,
            autocommit=True,
        ) as conn:
            server_version, role = conn.execute(
                "SELECT current_setting('server_version'), current_user"
            ).fetchone()
            print(f"PostgreSQL {server_version} ({config.db_host}:{config.db_port}, base {config.db_name})")
            print(f"Rôle connecté : {role}")
            result = task(PgRepository(conn))
    except LockBusy as exc:
        # Aucune tournée créée : les captures restent dans inbox/ pour l'ingestion suivante
        print(f"Ingestion non lancée : {exc}", file=sys.stderr)
        return 1
    except psycopg.Error as exc:
        print(f"Erreur PostgreSQL : {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        # Ex. : fichier brut déjà existant (jamais écrasé), dossier des captures non accessible en écriture
        # (verrou impossible à créer) ; une tournée ouverte a été close en « failed »
        print(f"Erreur d'accès aux fichiers (pages brutes ou captures) : {exc}", file=sys.stderr)
        return 1

    return EXIT_CODES[result.status]


if __name__ == "__main__":
    sys.exit(main())
