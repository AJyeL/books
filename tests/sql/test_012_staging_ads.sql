-- Tests de la migration 012 : rapports Amazon Ads dans STAGING (décision 018, lot B)
--
-- À exécuter EN TANT QUE PROPRIÉTAIRE de la base, depuis le dossier du dépôt (bash), toutes les migrations appliquées :
--   docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_012_staging_ads.sql
-- Même principe que test_008 : le propriétaire relève le catalogue et prépare RAW (fichiers de test, lot
-- 2026-12-21T080000Z, empreintes en « fd… »), puis endosse books_transformer, books_collector et books_reader.
-- Les lignes déjà présentes dans la base ne gênent pas : chaque contrôle se limite aux fichiers de test.
-- Les vues de meilleure estimation, remplacées par la migration 013, sont testées par test_013.
-- Tout se déroule dans une transaction annulée par ROLLBACK : aucune donnée n'est conservée.

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

DO $$
BEGIN
    IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : connecté en tant que %, le propriétaire (superutilisateur) est attendu', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.schema_migration WHERE version = 12) THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : migration 12 absente de schema_migration';
    END IF;
    RAISE NOTICE 'OK test 0 : propriétaire, migration 12 présente';
END;
$$;

-- ============================================================================================================
-- Test 1 : droits et vues, relevés dans le catalogue
-- ============================================================================================================
DO $$
DECLARE
    got text;
BEGIN
    SELECT string_agg(g, ', ' ORDER BY g) INTO got FROM (
        SELECT c.relname || ':' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END
               || ':' || a.privilege_type AS g
          FROM pg_class c, aclexplode(c.relacl) a
         WHERE c.relnamespace = 'staging'::regnamespace AND c.relname LIKE 'ads\_%' AND a.grantee <> c.relowner) x;
    IF got IS DISTINCT FROM
        'ads_day_source:books_transformer:SELECT, ads_extract_run:books_transformer:INSERT, '
        'ads_extract_run:books_transformer:SELECT, ads_file_extraction:books_transformer:INSERT, '
        'ads_file_extraction:books_transformer:SELECT, ads_product_day:books_transformer:DELETE, '
        'ads_product_day:books_transformer:INSERT, ads_product_day:books_transformer:SELECT, '
        'ads_product_day_best:books_transformer:SELECT, ads_search_term_day:books_transformer:DELETE, '
        'ads_search_term_day:books_transformer:INSERT, ads_search_term_day:books_transformer:SELECT, '
        'ads_search_term_day_best:books_transformer:SELECT' THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : droits de table : %', got;
    END IF;
    SELECT string_agg(g, ', ' ORDER BY g) INTO got FROM (
        SELECT c.relname || '.' || at.attname || ':' || a.grantee::regrole::text || ':' || a.privilege_type AS g
          FROM pg_class c
          JOIN pg_attribute at ON at.attrelid = c.oid AND at.attnum > 0
          CROSS JOIN LATERAL aclexplode(at.attacl) a
         WHERE c.relnamespace = 'staging'::regnamespace AND c.relname LIKE 'ads\_%') x;
    IF got IS DISTINCT FROM
        'ads_extract_run.files_failed:books_transformer:UPDATE, ads_extract_run.files_no_activity:books_transformer:UPDATE, '
        'ads_extract_run.files_ok:books_transformer:UPDATE, ads_extract_run.finished_at:books_transformer:UPDATE, '
        'ads_extract_run.notes:books_transformer:UPDATE, ads_extract_run.status:books_transformer:UPDATE, '
        'ads_file_extraction.error_message:books_transformer:UPDATE, ads_file_extraction.extract_run_id:books_transformer:UPDATE, '
        'ads_file_extraction.extracted_at:books_transformer:UPDATE, ads_file_extraction.first_day:books_transformer:UPDATE, '
        'ads_file_extraction.last_day:books_transformer:UPDATE, ads_file_extraction.row_count:books_transformer:UPDATE, '
        'ads_file_extraction.status:books_transformer:UPDATE, ads_file_extraction.unknown_columns:books_transformer:UPDATE' THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : droits de colonne : %', got;
    END IF;
    IF (SELECT count(*) FROM pg_class WHERE relnamespace = 'staging'::regnamespace AND relkind = 'v'
          AND relname IN ('ads_day_source', 'ads_product_day_best', 'ads_search_term_day_best')
          AND 'security_invoker=true' = ANY (reloptions)) <> 3 THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : les trois vues ne sont pas toutes en security_invoker';
    END IF;
    IF NOT has_table_privilege('books_transformer', 'raw.ads_report_file', 'SELECT')
       OR has_table_privilege('books_transformer', 'raw.ads_report_file', 'INSERT') THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : books_transformer doit lire raw.ads_report_file, sans l''écrire';
    END IF;
    RAISE NOTICE 'OK test 1 : droits de books_transformer seulement, colonnes de remplacement et de clôture, 3 vues en security_invoker';
END;
$$;

-- ============================================================================================================
-- Préparation, en tant que propriétaire : cinq fichiers RAW ok
--   export du 5 décembre : AP (19 h 59) et AP plus récent (21 h), ST ; export du 20 décembre : AP et ST
-- ============================================================================================================
INSERT INTO raw.ads_ingest_run (collector_version) VALUES ('test');
INSERT INTO raw.ads_report_file (run_id, lot, original_name, content_sha256, content_bytes, storage_path,
                                 report_type, export_date, export_time, status)
SELECT r.id, '2026-12-21T080000Z', f.name, 'fd' || repeat(f.n, 62), 1, 'test/' || f.name, f.kind, f.d, f.t, 'ok'
  FROM raw.ads_ingest_run r,
       (VALUES ('ap1', '1', 'advertised_product', date '2026-12-05', time '19:59:56'),
               ('ap1b', '2', 'advertised_product', date '2026-12-05', time '21:00:00'),
               ('st1', '3', 'search_term', date '2026-12-05', time '20:05:45'),
               ('ap2', '4', 'advertised_product', date '2026-12-20', time '09:00:00'),
               ('st2', '5', 'search_term', date '2026-12-20', time '09:00:00')) AS f(name, n, kind, d, t)
 WHERE r.collector_version = 'test';
CREATE TEMP TABLE test_files ON COMMIT DROP AS
    SELECT original_name AS name, id FROM raw.ads_report_file WHERE lot = '2026-12-21T080000Z' AND content_sha256 LIKE 'fd%';
GRANT SELECT ON test_files TO books_transformer, books_reader, books_collector;

-- ============================================================================================================
-- Tests 2 à 4 : sous books_transformer
-- ============================================================================================================
SET LOCAL ROLE books_transformer;

INSERT INTO staging.ads_extract_run (extractor_version) VALUES ('test');
-- Bornes : ap1 et ap1b du 15/10 au 01/12 ; st1 du 15/10 au 01/12 ; ap2 du 15/10 au 01/12 ; st2 du 04/11 au 01/12
INSERT INTO staging.ads_file_extraction (ads_report_file_id, extract_run_id, status, row_count, first_day, last_day)
SELECT t.id, (SELECT id FROM staging.ads_extract_run WHERE extractor_version = 'test'), 'ok', 1,
       CASE WHEN t.name = 'st2' THEN date '2026-11-04' ELSE date '2026-10-15' END, date '2026-12-01'
  FROM test_files t;
INSERT INTO staging.ads_product_day (ads_report_file_id, extract_run_id, day, campaign_id, ad_group_id,
                                     advertised_product_id, impressions)
SELECT t.id, e.extract_run_id, v.day, '1', '2', 'B0FAUX0001', v.impressions
  FROM test_files t JOIN staging.ads_file_extraction e ON e.ads_report_file_id = t.id
  JOIN (VALUES ('ap1', date '2026-10-15', 100), ('ap1', date '2026-11-04', 110),
               ('ap1b', date '2026-10-15', 101), ('ap1b', date '2026-11-04', 111),
               ('ap2', date '2026-10-15', 200), ('ap2', date '2026-12-01', 210)) AS v(name, day, impressions)
    ON v.name = t.name;
INSERT INTO staging.ads_search_term_day (ads_report_file_id, extract_run_id, day, campaign_id, ad_group_id, target_id,
                                         match_type, search_term_code, impressions)
SELECT t.id, e.extract_run_id, v.day, '1', '2', '3', 'TARGETING_EXPRESSION', 1, v.impressions
  FROM test_files t JOIN staging.ads_file_extraction e ON e.ads_report_file_id = t.id
  JOIN (VALUES ('st1', date '2026-10-15', 100), ('st1', date '2026-11-04', 110),
               ('st2', date '2026-11-04', 220)) AS v(name, day, impressions)
    ON v.name = t.name;

DO $$
DECLARE
    run bigint := (SELECT id FROM staging.ads_extract_run WHERE extractor_version = 'test');
    st1 bigint := (SELECT id FROM test_files WHERE name = 'st1');
    run2 bigint;
    base text;
BEGIN
    INSERT INTO staging.ads_extract_run (extractor_version) VALUES ('test') RETURNING id INTO run2;
    -- Test 2 : contraintes, chacune avec sa contre-épreuve
    base := format('UPDATE staging.ads_file_extraction SET %%s WHERE ads_report_file_id = %s', st1);
    PERFORM pg_temp.expect_refusal(2, 'ok avec un motif', format(base, $q$error_message = 'x'$q$), '23514', 'ads_file_extraction_result_ck');
    PERFORM pg_temp.expect_refusal(2, 'ok sans ligne', format(base, 'row_count = 0'), '23514', 'ads_file_extraction_result_ck');
    PERFORM pg_temp.expect_refusal(2, 'ok sans bornes', format(base, 'first_day = NULL'), '23514', 'ads_file_extraction_result_ck');
    PERFORM pg_temp.expect_refusal(2, 'bornes inversées', format(base, $q$first_day = '2026-12-02'$q$), '23514', 'ads_file_extraction_result_ck');
    PERFORM pg_temp.expect_refusal(2, 'aucune activité avec des bornes',
        format(base, $q$status = 'no_activity', row_count = 0$q$), '23514', 'ads_file_extraction_result_ck');
    PERFORM pg_temp.expect_refusal(2, 'échec sans motif',
        format(base, $q$status = 'parse_failed', row_count = 0, first_day = NULL, last_day = NULL$q$),
        '23514', 'ads_file_extraction_result_ck');
    -- Les contraintes CHECK sont évaluées par ordre alphabétique de nom : result_ck refuse le statut inconnu la première
    PERFORM pg_temp.expect_refusal(2, 'statut inconnu', format(base, $q$status = 'skipped'$q$), '23514', 'ads_file_extraction_result_ck');
    PERFORM pg_temp.expect_refusal(2, 'mesure négative',
        format('INSERT INTO staging.ads_search_term_day (ads_report_file_id, extract_run_id, day, campaign_id, '
               'ad_group_id, target_id, match_type, search_term_code, clicks) VALUES (%s, %s, ''2026-11-05'', '
               '''1'', ''2'', ''3'', ''x'', 1, -1)', st1, run), '23514', 'ads_search_term_day_clicks_ck');
    PERFORM pg_temp.expect_refusal(2, 'identifiant de campagne vide',
        format('INSERT INTO staging.ads_search_term_day (ads_report_file_id, extract_run_id, day, campaign_id, '
               'ad_group_id, target_id, match_type, search_term_code) VALUES (%s, %s, ''2026-11-05'', '
               ''''', ''2'', ''3'', ''x'', 1)', st1, run), '23514', 'ads_search_term_day_campaign_ck');
    PERFORM pg_temp.expect_refusal(2, 'doublon de grain',
        format('INSERT INTO staging.ads_search_term_day (ads_report_file_id, extract_run_id, day, campaign_id, '
               'ad_group_id, target_id, match_type, search_term_code) VALUES (%s, %s, ''2026-10-15'', '
               '''1'', ''2'', ''3'', ''TARGETING_EXPRESSION'', 1)', st1, run), '23505', 'ads_search_term_day_pk');
    PERFORM pg_temp.expect_refusal(2, 'ligne d''une autre exécution que celle du fichier (versions mélangées)',
        format('INSERT INTO staging.ads_search_term_day (ads_report_file_id, extract_run_id, day, campaign_id, '
               'ad_group_id, target_id, match_type, search_term_code) VALUES (%s, %s, ''2026-11-05'', '
               '''1'', ''2'', ''3'', ''x'', 1)', st1, -1), '23503', 'ads_search_term_day_extraction_fk');
    PERFORM pg_temp.expect_refusal(2, 'changement d''exécution tant que des lignes existent',
        format(base, format('extract_run_id = %s', run2)),
        '23503', 'ads_search_term_day_extraction_fk');

    -- Tests 3 et 4 (vues de meilleure estimation) : remplacées par la migration 013, testées par test_013

    -- Test 5 : books_transformer ne modifie ni l'identité d'une extraction, ni RAW, ni mapping
    PERFORM pg_temp.expect_refusal(5, 'changement du fichier d''une extraction',
        format(base, 'ads_report_file_id = ads_report_file_id + 1000000'), '42501', NULL);
    PERFORM pg_temp.expect_refusal(5, 'suppression d''une extraction',
        format('DELETE FROM staging.ads_file_extraction WHERE ads_report_file_id = %s', st1), '42501', NULL);
    PERFORM pg_temp.expect_refusal(5, 'modification de la version d''une exécution',
        $q$UPDATE staging.ads_extract_run SET extractor_version = 'x' WHERE extractor_version = 'test'$q$, '42501', NULL);
    PERFORM pg_temp.expect_refusal(5, 'lecture de mapping.text_code', 'SELECT key FROM mapping.text_code', '42501', NULL);
END;
$$;
RESET ROLE;

-- ============================================================================================================
-- Test 6 : books_collector et books_reader n'ont aucun droit sur STAGING des rapports
-- ============================================================================================================
SET LOCAL ROLE books_collector;
DO $$
BEGIN
    PERFORM pg_temp.expect_refusal(6, 'lecture des lignes par books_collector', 'SELECT 1 FROM staging.ads_product_day', '42501', NULL);
    PERFORM pg_temp.expect_refusal(6, 'lecture d''une vue par books_collector', 'SELECT 1 FROM staging.ads_day_source', '42501', NULL);
END;
$$;
RESET ROLE;

SET LOCAL ROLE books_reader;
DO $$
DECLARE
    v text;
BEGIN
    FOREACH v IN ARRAY ARRAY['ads_extract_run', 'ads_file_extraction', 'ads_product_day', 'ads_search_term_day',
                             'ads_day_source', 'ads_product_day_best', 'ads_search_term_day_best'] LOOP
        PERFORM pg_temp.expect_refusal(6, 'lecture de staging.' || v || ' par books_reader',
            format('SELECT 1 FROM staging.%I', v), '42501', NULL);
    END LOOP;
END;
$$;
RESET ROLE;

ROLLBACK;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM staging.ads_extract_run WHERE extractor_version = 'test')
       OR EXISTS (SELECT 1 FROM raw.ads_report_file WHERE lot = '2026-12-21T080000Z' AND content_sha256 LIKE 'fd%') THEN
        RAISE EXCEPTION 'ÉCHEC : des lignes de test ont été conservées';
    END IF;
    RAISE NOTICE 'OK : aucune ligne de test conservée';
END;
$$;
