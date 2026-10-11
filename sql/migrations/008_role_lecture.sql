-- Migration 008 : rôle de lecture books_reader pour les explorations SQL (décision 016)
-- À appliquer par le propriétaire de la base. Aucun mot de passe ici (dépôt public) :
-- il est défini à la main avec \password, une fois par environnement (voir README).
--
-- Garde-fou contre les erreurs humaines (écriture accidentelle, requête trop lourde, transaction oubliée), pas contre
-- un intrus (décision 016, section 1). Liste blanche explicite : aucun privilège par défaut ; chaque future migration
-- décide de l'accès de books_reader à ce qu'elle crée, et met à jour la liste attendue de tests/sql/test_008_role_lecture.sql.

BEGIN;

-- Rôle de connexion, sans aucun autre attribut, membre d'aucun rôle
CREATE ROLE books_reader LOGIN CONNECTION LIMIT 2;

-- Garde-fous de session (la lecture seule vient de l'absence de droits d'écriture, pas de ces réglages)
ALTER ROLE books_reader SET default_transaction_read_only = on;
ALTER ROLE books_reader SET statement_timeout = '2min';
ALTER ROLE books_reader SET idle_in_transaction_session_timeout = '5min';

-- STAGING : lecture de toutes les tables
GRANT USAGE ON SCHEMA staging TO books_reader;
GRANT SELECT ON staging.extract_run, staging.page_extraction, staging.ranking_entry, staging.category_observation,
    staging.product_observation, staging.product_format, staging.product_sales_rank, staging.product_rating_share
    TO books_reader;

-- RAW : lecture des tournées, et des pages sans leurs adresses (requested_url et final_url peuvent porter
-- l'identifiant de session Amazon du navigateur de veille dans le paramètre ref= : décision 015, section 2)
GRANT USAGE ON SCHEMA raw TO books_reader;
GRANT SELECT ON raw.collect_run TO books_reader;
GRANT SELECT (id, run_id, source, page_type, category_node, list_type, page_number, asin, fetched_at, http_status,
              fetch_status, error_message, content_sha256, content_bytes, storage_path, capture_method,
              metadata_path, metadata_sha256)
    ON raw.raw_page TO books_reader;

-- Migrations appliquées
GRANT SELECT ON public.schema_migration TO books_reader;

-- Toute fonction hors du catalogue système est fermée à PUBLIC (décisions 013 et 016) : PostgreSQL accorde par défaut
-- l'exécution de toute nouvelle fonction à tous les rôles. raw.forbid_change est la fonction des déclencheurs d'ajout
-- seul de raw.raw_page : le droit d'exécution n'est vérifié qu'à la création d'un déclencheur, jamais quand il se
-- déclenche ; les déclencheurs existants continuent donc de s'appliquer à tous (vérifié par le test 9).
REVOKE EXECUTE ON FUNCTION raw.forbid_change() FROM PUBLIC;

INSERT INTO public.schema_migration (version, description)
VALUES (8, 'Rôle books_reader : lecture seule pour les explorations SQL');

COMMIT;
