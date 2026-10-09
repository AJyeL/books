"""Point d'entrée de l'extracteur : python -m books.transformer [--force]

Extrait les pages RAW du périmètre vers STAGING (décision 011). --force : réextraction complète du périmètre.

Codes de sortie (décision 011, section 10) : 0 aucune anomalie (ou rien à extraire) ; 1 au moins une page en échec,
extraction déjà en cours, ou erreur d'exécution (base de données, fichiers) ; 2 configuration invalide.
"""

import argparse
import sys

import psycopg

from books.config import ConfigError, load_config
from books.transformer.extraction import EXIT_CODES, ExtractionBusy, extract
from books.transformer.parsing import EXTRACTOR_VERSION
from books.transformer.repository import PgTransformerRepository

# Le seul rôle autorisé : avec un autre (le propriétaire par exemple), les droits limités de la migration 005
# ne protégeraient plus RAW
EXPECTED_ROLE = "books_transformer"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m books.transformer",
                                     description="Extraction des pages RAW vers STAGING (décision 011).")
    parser.add_argument("--force", action="store_true", help="réextraire tout le périmètre")
    args = parser.parse_args(argv)

    try:
        config = load_config()
        if not config.raw_dir.is_dir():
            raise ConfigError(f"Dossier des pages brutes introuvable : {config.raw_dir}")
        if config.db_user != EXPECTED_ROLE:
            raise ConfigError(f"POSTGRES_USER vaut {config.db_user!r} : l'extracteur se connecte en {EXPECTED_ROLE}.")
    except ConfigError as exc:
        print(f"Erreur de configuration : {exc}", file=sys.stderr)
        return 2

    print(f"B.O.O.K.S. extracteur version {EXTRACTOR_VERSION} — environnement : {config.env}")
    print(f"Dossier des pages brutes (lecture seule) : {config.raw_dir}")

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
            result = extract(PgTransformerRepository(conn), config.raw_dir, force=args.force)
    except ExtractionBusy as exc:
        print(f"Extraction non lancée : {exc}", file=sys.stderr)
        return 1
    except psycopg.Error as exc:
        print(f"Erreur PostgreSQL : {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"Erreur d'accès aux fichiers : {exc}", file=sys.stderr)
        return 1

    return EXIT_CODES[result.status]


if __name__ == "__main__":
    sys.exit(main())
