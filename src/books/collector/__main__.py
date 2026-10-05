"""Point d'entrée du collecteur : python -m books.collector

Ouvre une tournée, obtient chaque page de classement depuis la source autorisée par BOOKS_ENV,
la valide, la dépose dans RAW, puis clôt la tournée.

Codes de sortie : 0 succès ; 1 tournée partielle ou en échec, ou erreur de base de données ;
2 configuration invalide ; 3 arrêt de sécurité (page bloquée ou non conforme).
"""

import os
import sys

import psycopg

from books import __version__
from books.collector.repository import PgRepository
from books.collector.run import EXIT_CODES, collect
from books.collector.sources import SourceError, make_source
from books.collector.targets import TargetsError, load_targets, plan_requests
from books.config import ConfigError, load_config


def main() -> int:
    try:
        config = load_config()
        requests = plan_requests(load_targets(config.targets_file))
        source = make_source(config.env, os.environ)
        if not config.raw_dir.is_dir():
            raise ConfigError(f"Dossier des pages brutes introuvable : {config.raw_dir}")
    except (ConfigError, TargetsError, SourceError) as exc:
        print(f"Erreur de configuration : {exc}", file=sys.stderr)
        return 2

    print(f"B.O.O.K.S. collecteur {__version__} — environnement : {config.env}")
    print(f"Dossier des pages brutes : {config.raw_dir}")

    try:
        with psycopg.connect(
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
            result = collect(requests, source, PgRepository(conn), config.raw_dir, __version__)
    except psycopg.Error as exc:
        print(f"Erreur PostgreSQL : {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        # Ex. : fichier brut déjà existant (jamais écrasé) ; la tournée a été close en « failed »
        print(f"Erreur d'écriture des pages brutes : {exc}", file=sys.stderr)
        return 1

    return EXIT_CODES[result.status]


if __name__ == "__main__":
    sys.exit(main())
