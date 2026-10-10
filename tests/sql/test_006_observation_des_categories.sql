-- Tests de la migration 006 : observation du nom des catégories (décision 014)
--
-- À exécuter EN TANT QUE PROPRIÉTAIRE de la base, depuis le dossier du dépôt (bash), migrations 001 à 006 appliquées :
--   docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_006_observation_des_categories.sql
-- Même principe que test_005_couche_staging.sql : le propriétaire prépare raw, puis endosse books_transformer et
-- books_collector (SET LOCAL ROLE). Chaque refus attendu doit venir de la contrainte nommée (ou du droit) attendu.
-- Tout se déroule dans une transaction annulée par ROLLBACK : aucune donnée n'est conservée.
-- Noms de catégorie inventés ; empreintes de test commençant par « fe ».

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

-- Préparation, en tant que propriétaire : deux pages RAW de test
DO $$
BEGIN
    IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : connecté en tant que %, le propriétaire (superutilisateur) est attendu', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.schema_migration WHERE version = 6) THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : migration 6 absente de schema_migration';
    END IF;
    INSERT INTO raw.collect_run (collector_version) VALUES ('test');
    INSERT INTO raw.raw_page (run_id, page_type, category_node, list_type, page_number, requested_url,
                              fetch_status, content_sha256, content_bytes, storage_path,
                              capture_method, metadata_path, metadata_sha256)
        SELECT id, 'bestseller_list', '10000000001', 'paid', v.page, 'https://test', 'ok',
               'fe' || repeat(v.page::text, 62), 1, 'test', 'extension-dom', 'test.json', 'fe' || repeat('c', 62)
          FROM raw.collect_run, (VALUES (1), (2)) AS v(page)
         WHERE collector_version = 'test';
    RAISE NOTICE 'OK test 0 : propriétaire, migration 6 présente, lignes RAW de test créées';
END;
$$;

CREATE TEMP TABLE test_ids ON COMMIT DROP AS
    SELECT (SELECT id FROM raw.raw_page WHERE requested_url = 'https://test' AND page_number = 1) AS page1,
           (SELECT id FROM raw.raw_page WHERE requested_url = 'https://test' AND page_number = 2) AS page2;
GRANT SELECT ON test_ids TO books_transformer;

-- ============================================================================================================
-- books_transformer
-- ============================================================================================================
SET LOCAL ROLE books_transformer;

DO $$
DECLARE
    page1 bigint := (SELECT page1 FROM test_ids);
    page2 bigint := (SELECT page2 FROM test_ids);
    run1  bigint;
    run   bigint;
    t     record;
BEGIN
    IF current_user <> 'books_transformer' THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : rôle courant %, books_transformer attendu', current_user;
    END IF;

    -- Test 1 : observation avec les deux noms, et observation sans aucun nom lu (deux NULL), acceptées
    INSERT INTO staging.extract_run (extractor_version) VALUES ('test') RETURNING id INTO run1;
    INSERT INTO staging.page_extraction (raw_page_id, extract_run_id, status, entry_count)
        VALUES (page1, run1, 'ok', 1), (page2, run1, 'ok', 1);
    INSERT INTO staging.category_observation (raw_page_id, extract_run_id, display_name, short_name)
        VALUES (page1, run1, 'Catégorie d''exemple - ebooks', 'Catégorie d''exemple'),
               (page2, run1, NULL, NULL);
    RAISE NOTICE 'OK test 1 : observations acceptées (deux noms ; aucun nom lu)';

    -- Test 2 : nouvelle exécution enregistrée avant la suppression de l'observation : refusée par la clé composée
    INSERT INTO staging.extract_run (extractor_version) VALUES ('test-2') RETURNING id INTO run;
    PERFORM pg_temp.expect_refusal(2, 'nouvelle exécution enregistrée avant la suppression de l''observation',
        format('UPDATE staging.page_extraction SET extract_run_id = %s WHERE raw_page_id = %s', run, page1),
        '23503', 'category_observation_page_extraction_fk');

    -- Test 3 : réextraction dans l'ordre : suppression, mise à jour de page_extraction, insertion
    DELETE FROM staging.category_observation WHERE raw_page_id = page1;
    UPDATE staging.page_extraction SET extract_run_id = run, extracted_at = now() WHERE raw_page_id = page1;
    INSERT INTO staging.category_observation (raw_page_id, extract_run_id, display_name, short_name)
        VALUES (page1, run, 'Nom changé d''exemple', 'Nom changé');
    IF (SELECT extract_run_id FROM staging.category_observation WHERE raw_page_id = page1) <> run THEN
        RAISE EXCEPTION 'ÉCHEC test 3 : réextraction incomplète';
    END IF;
    RAISE NOTICE 'OK test 3 : réextraction acceptée (DELETE, UPDATE de page_extraction, INSERT)';

    -- Tests 10 à 15 : refus, chacun par la contrainte attendue. La page 2 perd d'abord son observation : sans cela,
    -- le test 13 serait refusé par l'unicité de la page, et ne prouverait rien sur la clé composée.
    DELETE FROM staging.category_observation WHERE raw_page_id = page2;
    FOR t IN
        SELECT * FROM (VALUES
            -- INSERT, et non UPDATE (non accordé) : la contrainte est vérifiée avant l'unicité de la page
            (10, 'nom d''affichage vide',
                 format('INSERT INTO staging.category_observation (raw_page_id, extract_run_id, display_name) '
                        'VALUES (%s, %s, %L)', page2, run1, ''),
                 '23514', 'category_observation_display_name_ck'),
            (11, 'nom d''affichage fait d''espaces',
                 format('INSERT INTO staging.category_observation (raw_page_id, extract_run_id, display_name) '
                        'VALUES (%s, %s, %L)', page2, run1, '   '),
                 '23514', 'category_observation_display_name_ck'),
            (12, 'nom court fait d''espaces',
                 format('INSERT INTO staging.category_observation (raw_page_id, extract_run_id, short_name) '
                        'VALUES (%s, %s, %L)', page2, run1, '  '),
                 '23514', 'category_observation_short_name_ck'),
            (13, 'observation d''une autre exécution',
                 format('INSERT INTO staging.category_observation (raw_page_id, extract_run_id) VALUES (%s, %s)',
                        page2, run),
                 '23503', 'category_observation_page_extraction_fk'),
            (14, 'observation d''une page sans page_extraction',
                 format('INSERT INTO staging.category_observation (raw_page_id, extract_run_id) VALUES (%s, %s)',
                        -1, run),
                 '23503', 'category_observation_page_extraction_fk'),
            (15, 'deux observations pour une page',
                 format('INSERT INTO staging.category_observation (raw_page_id, extract_run_id) VALUES (%s, %s)',
                        page1, run),
                 '23505', 'category_observation_pkey')
        ) AS v(num, label, sql, state, expected)
        ORDER BY num
    LOOP
        PERFORM pg_temp.expect_refusal(t.num, t.label, t.sql, t.state, t.expected);
    END LOOP;

    -- Tests 20 à 22 : droits refusés à books_transformer
    PERFORM pg_temp.expect_refusal(20, 'UPDATE de category_observation (seuls DELETE et INSERT sont permis)',
        format('UPDATE staging.category_observation SET short_name = %L WHERE raw_page_id = %s', 'x', page1),
        '42501', NULL);
    PERFORM pg_temp.expect_refusal(21, 'TRUNCATE de category_observation',
        'TRUNCATE staging.category_observation', '42501', NULL);
    PERFORM pg_temp.expect_refusal(22, 'ALTER TABLE de category_observation',
        'ALTER TABLE staging.category_observation DROP CONSTRAINT category_observation_display_name_ck', '42501', NULL);
END;
$$;

-- ============================================================================================================
-- books_collector : aucun accès
-- ============================================================================================================
RESET ROLE;
SET LOCAL ROLE books_collector;

DO $$
BEGIN
    PERFORM pg_temp.expect_refusal(30, 'lecture de category_observation par books_collector',
        'SELECT count(*) FROM staging.category_observation', '42501', NULL);
END;
$$;

RESET ROLE;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.role_table_grants
                WHERE table_schema = 'staging' AND table_name = 'category_observation'
                  AND grantee IN ('PUBLIC', 'books_collector')) THEN
        RAISE EXCEPTION 'ÉCHEC test 40 : PUBLIC ou books_collector a un droit sur category_observation';
    END IF;
    RAISE NOTICE 'OK test 40 : aucun droit de PUBLIC ni de books_collector sur category_observation';
END;
$$;

ROLLBACK;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM raw.collect_run WHERE collector_version = 'test')
       OR EXISTS (SELECT 1 FROM raw.raw_page WHERE requested_url = 'https://test')
       OR EXISTS (SELECT 1 FROM staging.extract_run WHERE extractor_version LIKE 'test%') THEN
        RAISE EXCEPTION 'ÉCHEC : des lignes de test ont été conservées';
    END IF;
    RAISE NOTICE 'OK : aucune ligne de test conservée';
END;
$$;
