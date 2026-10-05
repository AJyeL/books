"""Point d'entrée du collecteur : python -m books.collector

Squelette : charge la configuration, vérifie la connexion à PostgreSQL, puis s'arrête.
Aucune requête réseau vers Amazon.
"""

import sys

import psycopg

from books import __version__
from books.config import ConfigError, load_config


def main() -> int:
    try:
        config = load_config()
    except ConfigError as exc:
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
        ) as conn:
            server_version, role = conn.execute(
                "SELECT current_setting('server_version'), current_user"
            ).fetchone()
    except psycopg.OperationalError as exc:
        print(f"Connexion à PostgreSQL impossible : {exc}", file=sys.stderr)
        return 1

    print(f"PostgreSQL {server_version} ({config.db_host}:{config.db_port}, base {config.db_name})")
    print(f"Rôle connecté : {role}")
    print("Squelette : aucune collecte à ce stade. Arrêt.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
