-- Tests de la migration 008 : rôle de lecture books_reader (décision 016, section 8)
--
-- À exécuter EN TANT QUE PROPRIÉTAIRE de la base, depuis le dossier du dépôt (bash), migrations 001 à 008 appliquées :
--   docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_008_role_lecture.sql
-- Même principe que test_007 : le propriétaire prépare raw, puis endosse books_reader (SET LOCAL ROLE). Les réglages du
-- rôle ne s'appliquent qu'à une vraie connexion : ils sont vérifiés dans le catalogue (test 7) et par la recette.
-- Tout se déroule dans une transaction annulée par ROLLBACK : aucune donnée ni aucun objet n'est conservé.
--
-- Liste blanche (test 6) : toute migration qui ouvre ou ferme un accès à books_reader, ou ajoute une colonne à une table
-- qu'il lit, met à jour la liste attendue ci-dessous dans le même commit (décision 016, section 7).

BEGIN;

CREATE FUNCTION pg_temp.expect_refusal(num int, label text, sql text, state text, expected text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    accepted boolean := false;
    got_state text;
    got_constraint text;
    got_message text;
BEGIN
    BEGIN
        EXECUTE sql;
        accepted := true;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS got_state = RETURNED_SQLSTATE, got_constraint = CONSTRAINT_NAME,
                                got_message = MESSAGE_TEXT;
    END;
    IF accepted THEN
        RAISE EXCEPTION 'ÉCHEC test % : % accepté alors qu''il devait être refusé', num, label;
    END IF;
    IF got_state <> state OR NULLIF(got_constraint, '') IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'ÉCHEC test % : % refusé par % / % (%) au lieu de % / %',
            num, label, got_state, got_constraint, got_message, state, expected;
    END IF;
    RAISE NOTICE 'OK test % : % refusé (%)', num, label, coalesce(expected, got_message);
END;
$$;

-- Tables lues par books_reader (liste blanche de la décision 016, section 3)
CREATE FUNCTION pg_temp.reader_tables() RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
    SELECT ARRAY['staging.extract_run', 'staging.page_extraction', 'staging.ranking_entry',
                 'staging.category_observation', 'staging.product_observation', 'staging.product_format',
                 'staging.product_sales_rank', 'staging.product_rating_share', 'raw.collect_run', 'raw.raw_page',
                 'public.schema_migration']
$$;

-- Préparation, en tant que propriétaire : une page RAW de test, et une correspondance simulée de la décision 013
DO $$
BEGIN
    IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : connecté en tant que %, le propriétaire (superutilisateur) est attendu', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.schema_migration WHERE version = 8) THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : migration 8 absente de schema_migration';
    END IF;
    INSERT INTO raw.collect_run (collector_version) VALUES ('test');
    INSERT INTO raw.raw_page (run_id, page_type, asin, requested_url, fetch_status, content_sha256, content_bytes,
                              storage_path, capture_method, metadata_path, metadata_sha256)
        SELECT id, 'product', 'B0FAUX0001', 'https://test', 'ok', 'fe' || repeat('a', 62), 1, 'test',
               'extension-dom', 'test.json', 'fe' || repeat('c', 62)
          FROM raw.collect_run WHERE collector_version = 'test';

    -- Correspondance simulée (décision 013) : schéma séparé, table, fonction SECURITY DEFINER qui ne rend qu'un code,
    -- fermée à PUBLIC et accordée au seul books_transformer, selon la règle de la décision 016 (section 4)
    CREATE SCHEMA test_correspondance;
    CREATE TABLE test_correspondance.author_map (code text PRIMARY KEY, display_name text, amazon_author_id text);
    INSERT INTO test_correspondance.author_map VALUES ('A0001', 'Camille Sentinelle-Rgpd', 'B0SENTAUT1');
    CREATE FUNCTION test_correspondance.code_for(author_id text) RETURNS text
        LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog
        AS $f$ SELECT code FROM test_correspondance.author_map WHERE amazon_author_id = author_id $f$;
    REVOKE EXECUTE ON FUNCTION test_correspondance.code_for(text) FROM PUBLIC;
    GRANT USAGE ON SCHEMA test_correspondance TO books_transformer;
    GRANT EXECUTE ON FUNCTION test_correspondance.code_for(text) TO books_transformer;
    RAISE NOTICE 'OK test 0 : propriétaire, migration 8 présente, page RAW de test et correspondance simulée créées';
END;
$$;

CREATE TEMP TABLE test_ids ON COMMIT DROP AS
    SELECT (SELECT id FROM raw.raw_page WHERE requested_url = 'https://test') AS page1;
GRANT SELECT ON test_ids TO books_reader;

-- ============================================================================================================
-- Tests 5 et 7 : attributs et réglages, relevés dans le catalogue par le propriétaire
-- ============================================================================================================
DO $$
DECLARE
    r pg_roles%ROWTYPE;
BEGIN
    -- Test 5 : connexion permise, aucun autre attribut, membre d'aucun rôle
    SELECT * INTO r FROM pg_roles WHERE rolname = 'books_reader';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ÉCHEC test 5 : rôle books_reader absent';
    END IF;
    IF NOT r.rolcanlogin OR r.rolsuper OR r.rolcreatedb OR r.rolcreaterole OR r.rolreplication OR r.rolbypassrls THEN
        RAISE EXCEPTION 'ÉCHEC test 5 : attributs inattendus (login %, super %, createdb %, createrole %, réplication %, bypassrls %)',
            r.rolcanlogin, r.rolsuper, r.rolcreatedb, r.rolcreaterole, r.rolreplication, r.rolbypassrls;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_auth_members WHERE member = r.oid) THEN
        RAISE EXCEPTION 'ÉCHEC test 5 : books_reader est membre de %',
            (SELECT string_agg(roleid::regrole::text, ', ') FROM pg_auth_members WHERE member = r.oid);
    END IF;
    IF pg_has_role('books_reader', 'books_transformer', 'USAGE') OR pg_has_role('books_reader', 'books_collector', 'USAGE')
       OR pg_has_role('books_reader', 'pg_read_all_data', 'USAGE')
       OR pg_has_role('books_reader', 'pg_read_server_files', 'USAGE') THEN
        RAISE EXCEPTION 'ÉCHEC test 5 : books_reader hérite des droits d''un autre rôle';
    END IF;
    RAISE NOTICE 'OK test 5 : connexion permise, aucun autre attribut, membre d''aucun rôle';

    -- Test 7 : réglages de session et limite de connexions
    IF r.rolconnlimit <> 2 THEN
        RAISE EXCEPTION 'ÉCHEC test 7 : limite de connexions % au lieu de 2', r.rolconnlimit;
    END IF;
    IF (SELECT array_agg(s ORDER BY s) FROM pg_db_role_setting, unnest(setconfig) AS s
         WHERE setrole = r.oid AND setdatabase = 0)
       IS DISTINCT FROM ARRAY['default_transaction_read_only=on', 'idle_in_transaction_session_timeout=5min',
                              'statement_timeout=2min'] THEN
        RAISE EXCEPTION 'ÉCHEC test 7 : réglages inattendus : %',
            (SELECT array_agg(s ORDER BY s) FROM pg_db_role_setting, unnest(setconfig) AS s
              WHERE setrole = r.oid AND setdatabase = 0);
    END IF;
    RAISE NOTICE 'OK test 7 : lecture seule par défaut, délais de 2 min et 5 min, 2 connexions au plus';
END;
$$;

-- ============================================================================================================
-- books_reader
-- ============================================================================================================
SET LOCAL ROLE books_reader;

DO $$
DECLARE
    page1 bigint := (SELECT page1 FROM test_ids);
    t text;
    n int;
BEGIN
    IF current_user <> 'books_reader' THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : rôle courant %, books_reader attendu', current_user;
    END IF;

    -- Test 1 : lecture de chaque table de la liste, et des colonnes permises de raw.raw_page
    FOREACH t IN ARRAY pg_temp.reader_tables() LOOP
        IF t = 'raw.raw_page' THEN
            CONTINUE;
        END IF;
        EXECUTE format('SELECT count(*) FROM %s', t) INTO n;
    END LOOP;
    IF (SELECT asin FROM raw.raw_page WHERE id = page1) IS DISTINCT FROM 'B0FAUX0001'
       OR (SELECT count(*) FROM raw.raw_page WHERE id = page1 AND storage_path = 'test' AND fetch_status = 'ok') <> 1 THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : page RAW de test illisible par ses colonnes permises';
    END IF;
    RAISE NOTICE 'OK test 1 : les 11 tables de la liste se lisent (raw.raw_page par ses colonnes permises)';

    -- Test 2 : adresses de RAW illisibles
    PERFORM pg_temp.expect_refusal(2, 'lecture de raw.raw_page.requested_url',
        'SELECT requested_url FROM raw.raw_page', '42501', NULL);
    PERFORM pg_temp.expect_refusal(2, 'lecture de raw.raw_page.final_url',
        'SELECT final_url FROM raw.raw_page', '42501', NULL);
    PERFORM pg_temp.expect_refusal(2, 'SELECT * sur raw.raw_page', 'SELECT * FROM raw.raw_page', '42501', NULL);
    PERFORM pg_temp.expect_refusal(2, 'filtre sur requested_url',
        'SELECT id FROM raw.raw_page WHERE requested_url LIKE ''https://%''', '42501', NULL);

    -- Test 3 : aucune écriture (refus par les droits : la lecture seule de session ne s'applique pas à SET ROLE)
    IF current_setting('transaction_read_only') <> 'off' THEN
        RAISE EXCEPTION 'ÉCHEC test 3 : transaction en lecture seule, le refus ne prouverait pas l''absence de droits';
    END IF;
    FOREACH t IN ARRAY pg_temp.reader_tables() LOOP
        PERFORM pg_temp.expect_refusal(3, 'INSERT dans ' || t, format('INSERT INTO %s DEFAULT VALUES', t), '42501', NULL);
        PERFORM pg_temp.expect_refusal(3, 'UPDATE de ' || t,
            format('UPDATE %s SET %I = %I', t, a.attname, a.attname), '42501', NULL)
          FROM (SELECT attname FROM pg_attribute  -- première colonne qui n'est pas une identité (refus 428C9 sinon)
                 WHERE attrelid = t::regclass AND attnum > 0 AND attidentity = '' ORDER BY attnum LIMIT 1) AS a;
        PERFORM pg_temp.expect_refusal(3, 'DELETE dans ' || t, format('DELETE FROM %s', t), '42501', NULL);
        PERFORM pg_temp.expect_refusal(3, 'TRUNCATE de ' || t, format('TRUNCATE %s', t), '42501', NULL);
    END LOOP;

    -- Test 4 : aucune création d'objet
    FOREACH t IN ARRAY ARRAY['public', 'raw', 'staging'] LOOP
        PERFORM pg_temp.expect_refusal(4, 'CREATE TABLE dans ' || t,
            format('CREATE TABLE %I.test_lecteur (x int)', t), '42501', NULL);
    END LOOP;
    PERFORM pg_temp.expect_refusal(4, 'CREATE TEMP TABLE', 'CREATE TEMP TABLE test_lecteur (x int)', '42501', NULL);
    PERFORM pg_temp.expect_refusal(4, 'CREATE SCHEMA', 'CREATE SCHEMA test_lecteur', '42501', NULL);
    PERFORM pg_temp.expect_refusal(4, 'CREATE FUNCTION dans public',
        'CREATE FUNCTION public.test_lecteur() RETURNS int LANGUAGE sql AS ''SELECT 1''', '42501', NULL);

    -- Test 6d : correspondance simulée (décision 013) illisible et inexécutable
    PERFORM pg_temp.expect_refusal(6, 'lecture de la correspondance simulée',
        'SELECT display_name FROM test_correspondance.author_map', '42501', NULL);
    PERFORM pg_temp.expect_refusal(6, 'appel de la fonction de la correspondance simulée',
        'SELECT test_correspondance.code_for(''B0SENTAUT1'')', '42501', NULL);
    PERFORM pg_temp.expect_refusal(6, 'appel de raw.forbid_change',
        'SELECT raw.forbid_change()', '42501', NULL);

    -- Test 8 : lecture seule explicitement désactivée : l'écriture reste refusée par les droits
    SET LOCAL default_transaction_read_only = off;
    SET LOCAL transaction_read_only = off;
    PERFORM pg_temp.expect_refusal(8, 'INSERT après désactivation de la lecture seule',
        'INSERT INTO staging.extract_run (extractor_version) VALUES (''test'')', '42501', NULL);
END;
$$;

RESET ROLE;

-- ============================================================================================================
-- Test 6 : liste blanche, relevée dans le catalogue par le propriétaire
-- ============================================================================================================
DO $$
DECLARE
    expected text[] := ARRAY[
        'public.schema_migration.applied_at', 'public.schema_migration.description', 'public.schema_migration.version',
        'raw.collect_run.collector_version', 'raw.collect_run.finished_at', 'raw.collect_run.id', 'raw.collect_run.notes',
        'raw.collect_run.pages_failed', 'raw.collect_run.pages_ok', 'raw.collect_run.started_at', 'raw.collect_run.status',
        'raw.raw_page.asin', 'raw.raw_page.capture_method', 'raw.raw_page.category_node', 'raw.raw_page.content_bytes',
        'raw.raw_page.content_sha256', 'raw.raw_page.error_message', 'raw.raw_page.fetch_status',
        'raw.raw_page.fetched_at', 'raw.raw_page.http_status', 'raw.raw_page.id', 'raw.raw_page.list_type',
        'raw.raw_page.metadata_path', 'raw.raw_page.metadata_sha256', 'raw.raw_page.page_number',
        'raw.raw_page.page_type', 'raw.raw_page.run_id', 'raw.raw_page.source', 'raw.raw_page.storage_path',
        'staging.category_observation.display_name', 'staging.category_observation.extract_run_id',
        'staging.category_observation.raw_page_id', 'staging.category_observation.short_name',
        'staging.extract_run.extractor_version', 'staging.extract_run.finished_at', 'staging.extract_run.id',
        'staging.extract_run.notes', 'staging.extract_run.pages_extracted', 'staging.extract_run.pages_failed',
        'staging.extract_run.pages_skipped', 'staging.extract_run.started_at', 'staging.extract_run.status',
        'staging.page_extraction.entry_count', 'staging.page_extraction.error_message',
        'staging.page_extraction.extract_run_id', 'staging.page_extraction.extracted_at',
        'staging.page_extraction.raw_page_id', 'staging.page_extraction.status',
        'staging.product_format.currency', 'staging.product_format.extract_run_id', 'staging.product_format.is_selected',
        'staging.product_format.ku_borrow', 'staging.product_format.label', 'staging.product_format.linked_asin',
        'staging.product_format.position', 'staging.product_format.price_amount',
        'staging.product_format.price_qualifier', 'staging.product_format.raw_page_id',
        'staging.product_format.swatch_kind',
        'staging.product_observation.breadcrumb', 'staging.product_observation.cover_url',
        'staging.product_observation.description_markup', 'staging.product_observation.description_markup_sha256',
        'staging.product_observation.description_text', 'staging.product_observation.description_text_sha256',
        'staging.product_observation.extract_run_id', 'staging.product_observation.file_size_unit',
        'staging.product_observation.file_size_value', 'staging.product_observation.format_label',
        'staging.product_observation.has_aplus', 'staging.product_observation.isbn13',
        'staging.product_observation.language', 'staging.product_observation.print_pages',
        'staging.product_observation.publication_date', 'staging.product_observation.rating',
        'staging.product_observation.raw_page_id', 'staging.product_observation.review_count',
        'staging.product_observation.series_form', 'staging.product_observation.series_name',
        'staging.product_observation.series_position', 'staging.product_observation.series_total',
        'staging.product_observation.title',
        'staging.product_rating_share.extract_run_id', 'staging.product_rating_share.percent',
        'staging.product_rating_share.raw_page_id', 'staging.product_rating_share.stars',
        'staging.product_sales_rank.category_node', 'staging.product_sales_rank.extract_run_id',
        'staging.product_sales_rank.is_general', 'staging.product_sales_rank.list_type',
        'staging.product_sales_rank.position', 'staging.product_sales_rank.rank',
        'staging.product_sales_rank.raw_page_id', 'staging.product_sales_rank.store',
        'staging.ranking_entry.asin', 'staging.ranking_entry.cover_url', 'staging.ranking_entry.currency',
        'staging.ranking_entry.extract_run_id', 'staging.ranking_entry.has_card', 'staging.ranking_entry.ku_sticker_hint',
        'staging.ranking_entry.price_amount', 'staging.ranking_entry.rank', 'staging.ranking_entry.rating',
        'staging.ranking_entry.raw_page_id', 'staging.ranking_entry.review_count', 'staging.ranking_entry.title'];
    readable text[];
    extra text;
    missing text;
BEGIN
    -- Test 6a : colonnes lisibles par books_reader, dans tous les schémas hors catalogue système et schémas temporaires
    SELECT array_agg(n.nspname || '.' || c.relname || '.' || a.attname ORDER BY 1) INTO readable
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
     WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
       AND n.nspname NOT IN ('pg_catalog', 'information_schema')
       AND n.nspname NOT LIKE 'pg\_toast%' AND n.nspname NOT LIKE 'pg\_temp\_%'
       AND has_column_privilege('books_reader', c.oid, a.attnum, 'SELECT');
    SELECT string_agg(x, ', ') INTO extra FROM unnest(readable) AS x WHERE x <> ALL (expected);
    SELECT string_agg(x, ', ') INTO missing FROM unnest(expected) AS x WHERE x <> ALL (coalesce(readable, '{}'));
    IF extra IS NOT NULL OR missing IS NOT NULL THEN
        RAISE EXCEPTION 'ÉCHEC test 6 : colonnes lisibles hors liste : % ; colonnes de la liste non lisibles : %',
            coalesce(extra, 'aucune'), coalesce(missing, 'aucune');
    END IF;
    IF cardinality(readable) <> 106 THEN
        RAISE EXCEPTION 'ÉCHEC test 6 : % colonnes lisibles, 106 attendues', cardinality(readable);
    END IF;
    RAISE NOTICE 'OK test 6a : 106 colonnes lisibles, exactement la liste blanche (adresses de RAW et correspondance exclues)';

    -- Test 6b : aucune fonction exécutable, aucune séquence utilisable hors du catalogue système
    SELECT string_agg(n.nspname || '.' || p.proname, ', ') INTO extra
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\_temp\_%'
       AND has_function_privilege('books_reader', p.oid, 'EXECUTE');
    IF extra IS NOT NULL THEN
        RAISE EXCEPTION 'ÉCHEC test 6 : fonctions exécutables par books_reader : %', extra;
    END IF;
    SELECT string_agg(n.nspname || '.' || c.relname, ', ') INTO extra
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind = 'S' AND n.nspname NOT LIKE 'pg\_temp\_%'
       AND CASE WHEN c.relkind = 'S' THEN has_sequence_privilege('books_reader', c.oid, 'USAGE, SELECT, UPDATE') END;
    IF extra IS NOT NULL THEN
        RAISE EXCEPTION 'ÉCHEC test 6 : séquences utilisables par books_reader : %', extra;
    END IF;
    RAISE NOTICE 'OK test 6b : aucune fonction exécutable ni séquence utilisable hors du catalogue système';

    -- Test 6c : schémas visibles (USAGE) : public, raw, staging ; aucun droit de création, ni de schéma dans la base
    SELECT string_agg(nspname, ', ' ORDER BY nspname) INTO extra
      FROM pg_namespace
     WHERE nspname NOT IN ('pg_catalog', 'information_schema') AND nspname NOT LIKE 'pg\_toast%'
       AND nspname NOT LIKE 'pg\_temp\_%'
       AND has_schema_privilege('books_reader', oid, 'USAGE');
    IF extra IS DISTINCT FROM 'public, raw, staging' THEN
        RAISE EXCEPTION 'ÉCHEC test 6 : schémas visibles par books_reader : % (attendu : public, raw, staging)', extra;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname NOT LIKE 'pg\_temp\_%'
                AND has_schema_privilege('books_reader', oid, 'CREATE'))
       OR has_database_privilege('books_reader', current_database(), 'CREATE')
       OR has_database_privilege('books_reader', current_database(), 'TEMPORARY') THEN
        RAISE EXCEPTION 'ÉCHEC test 6 : books_reader peut créer un objet (schéma, table ou table temporaire)';
    END IF;
    RAISE NOTICE 'OK test 6c : schémas visibles public, raw et staging ; aucun droit de création';
END;
$$;

-- ============================================================================================================
-- Test 9 : raw.forbid_change fermée à PUBLIC, les déclencheurs d'ajout seul s'appliquent toujours
-- ============================================================================================================
CREATE ROLE test_sans_execute;
GRANT USAGE ON SCHEMA raw TO test_sans_execute;
GRANT SELECT (id, source), UPDATE (source) ON raw.raw_page TO test_sans_execute;
GRANT SELECT ON test_ids TO test_sans_execute;

SET LOCAL ROLE test_sans_execute;

DO $$
BEGIN
    IF has_function_privilege('test_sans_execute', 'raw.forbid_change()', 'EXECUTE') THEN
        RAISE EXCEPTION 'ÉCHEC test 9 : raw.forbid_change est exécutable par un rôle quelconque (PUBLIC)';
    END IF;
    PERFORM pg_temp.expect_refusal(9, 'UPDATE de raw.raw_page sans droit d''exécuter raw.forbid_change',
        format('UPDATE raw.raw_page SET source = source WHERE id = %s', (SELECT page1 FROM test_ids)), 'P0001', NULL);
END;
$$;

RESET ROLE;

-- Test 10 : la correspondance simulée reste utilisable par le rôle à qui elle est accordée (la simulation est fidèle)
SET LOCAL ROLE books_transformer;

DO $$
BEGIN
    IF test_correspondance.code_for('B0SENTAUT1') IS DISTINCT FROM 'A0001' THEN
        RAISE EXCEPTION 'ÉCHEC test 10 : la fonction simulée ne rend pas le code à books_transformer';
    END IF;
    PERFORM pg_temp.expect_refusal(10, 'lecture de la correspondance simulée par books_transformer',
        'SELECT display_name FROM test_correspondance.author_map', '42501', NULL);
    RAISE NOTICE 'OK test 10 : books_transformer obtient le code par la fonction, jamais le nom';
END;
$$;

RESET ROLE;

ROLLBACK;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM raw.collect_run WHERE collector_version = 'test')
       OR EXISTS (SELECT 1 FROM raw.raw_page WHERE requested_url = 'https://test')
       OR EXISTS (SELECT 1 FROM staging.extract_run WHERE extractor_version LIKE 'test%')
       OR EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'test_correspondance')
       OR EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'test_sans_execute') THEN
        RAISE EXCEPTION 'ÉCHEC : des lignes ou des objets de test ont été conservés';
    END IF;
    RAISE NOTICE 'OK : aucune ligne ni aucun objet de test conservé';
END;
$$;
