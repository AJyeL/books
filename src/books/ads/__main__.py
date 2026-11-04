"""Point d'entrée de l'ingestion des rapports Amazon Ads : python -m books.ads

Dépose dans RAW les rapports de BOOKS_ADS_DIR/inbox/ (décision 018, lot A), avec le rôle books_collector seulement.
Même comportement en dev et en prod : aucun réseau, seulement des fichiers déposés à la main.

Codes de sortie (comme le collecteur, décision 008) : 0 aucune anomalie ; 1 au moins une anomalie (fichier invalid,
élément laissé en place), ingestion déjà en cours, ou erreur d'exécution ; 2 configuration invalide.
"""

import os
import sys
from pathlib import Path

import psycopg

from books import __version__
from books.ads.ingestion import INBOX, ingest_reports
from books.ads.repository import PgAdsRepository
from books.collector.lock import LockBusy, ingestion_lock
from books.collector.run import EXIT_CODES
from books.config import ConfigError, load_config

# Le seul rôle autorisé : avec un autre (le propriétaire par exemple), l'ajout seul de RAW ne serait plus protégé
# par les droits de la migration 011
EXPECTED_ROLE = "books_collector"


def main() -> int:
    try:
        config = load_config()
        if not config.raw_dir.is_dir():
            raise ConfigError(f"Dossier des pages brutes introuvable : {config.raw_dir}")
        if config.db_user != EXPECTED_ROLE:
            raise ConfigError(f"POSTGRES_USER vaut {config.db_user!r} : l'ingestion des rapports se connecte en "
                              f"{EXPECTED_ROLE}.")
        ads = os.environ.get("BOOKS_ADS_DIR", "").strip()
        if not ads:
            raise ConfigError("BOOKS_ADS_DIR est absente ou vide (dossier des rapports Amazon Ads à ingérer).")
        ads_dir = Path(ads)
        if not (ads_dir / INBOX).is_dir():
            raise ConfigError(f"Dossier des rapports à ingérer introuvable : {ads_dir / INBOX}")
    except ConfigError as exc:
        print(f"Erreur de configuration : {exc}", file=sys.stderr)
        return 2

    print(f"B.O.O.K.S. ingestion des rapports Amazon Ads {__version__} — environnement : {config.env}")
    print(f"Dossier des pages brutes : {config.raw_dir}")

    try:
        with ingestion_lock(ads_dir), psycopg.connect(
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
            result = ingest_reports(ads_dir, PgAdsRepository(conn), config.raw_dir, __version__)
    except LockBusy as exc:
        # Aucune ingestion ouverte : les rapports restent dans inbox/ pour l'ingestion suivante
        print(f"Ingestion non lancée : {exc}", file=sys.stderr)
        return 1
    except psycopg.Error as exc:
        print(f"Erreur PostgreSQL : {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        # Ex. : fichier brut déjà existant (jamais écrasé), dossier des rapports non accessible en écriture
        print(f"Erreur d'accès aux fichiers (pages brutes ou rapports) : {exc}", file=sys.stderr)
        return 1

    return EXIT_CODES[result.status]


if __name__ == "__main__":
    sys.exit(main())
