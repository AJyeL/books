"""Point d'entrée de l'extraction des rapports Amazon Ads : python -m books.ads.extract [--force]

Extrait les rapports RAW ok vers STAGING (décision 018, lot B). --force : réextraction complète.
Lancé par scripts/recevoir-ads.sh après chaque ingestion, quel que soit son résultat (décision 012).

Codes de sortie : 0 aucune anomalie (ou rien à extraire) ; 1 au moins un fichier en échec, un écart de
réconciliation, extraction déjà en cours, ou erreur d'exécution ; 2 configuration invalide.
"""

import argparse
import sys

import psycopg

from books.ads.extraction import ADS_EXTRACTOR_VERSION, EXIT_CODES, AdsExtractionBusy, extract_reports
from books.ads.transformer_repository import PgAdsTransformerRepository
from books.config import ConfigError, load_config

# Le seul rôle autorisé : avec un autre, les droits limités de la migration 012 ne protégeraient plus RAW ni mapping
EXPECTED_ROLE = "books_transformer"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m books.ads.extract",
                                     description="Extraction des rapports Amazon Ads de RAW vers STAGING (décision 018).")
    parser.add_argument("--force", action="store_true", help="réextraire tous les rapports")
    args = parser.parse_args(argv)

    try:
        config = load_config()
        if not config.raw_dir.is_dir():
            raise ConfigError(f"Dossier des pages brutes introuvable : {config.raw_dir}")
        if config.db_user != EXPECTED_ROLE:
            raise ConfigError(f"POSTGRES_USER vaut {config.db_user!r} : l'extraction des rapports se connecte en "
                              f"{EXPECTED_ROLE}.")
    except ConfigError as exc:
        print(f"Erreur de configuration : {exc}", file=sys.stderr)
        return 2

    print(f"B.O.O.K.S. extracteur des rapports Ads version {ADS_EXTRACTOR_VERSION} — environnement : {config.env}")
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
            result = extract_reports(PgAdsTransformerRepository(conn), config.raw_dir, force=args.force)
    except AdsExtractionBusy as exc:
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
