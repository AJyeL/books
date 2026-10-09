-- Tests de la migration 005 : couche STAGING et rôle books_transformer (décision 011)
--
-- À exécuter EN TANT QUE PROPRIÉTAIRE de la base (superutilisateur du conteneur), depuis le dossier du dépôt (bash) :
--   docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_005_couche_staging.sql
-- Le propriétaire prépare des lignes de test dans raw (books_transformer ne peut pas y écrire), puis endosse
-- tour à tour books_transformer et books_collector (SET LOCAL ROLE) : chaque vérification est faite avec les
-- droits réels du rôle concerné.
--
-- Les tests se vérifient eux-mêmes : chaque vérification réussie affiche « NOTICE:  OK … », et psql s'arrête au
-- premier « ÉCHEC » (code de sortie 0 = tout est conforme). Un refus attendu doit venir de la contrainte nommée
-- (ou du droit) attendu, et non d'une autre : sinon, le test échoue aussi.
-- Tout se déroule dans une transaction annulée par ROLLBACK : aucune donnée n'est conservée.
-- Les empreintes de test commencent par « fe » et ne correspondent à aucun vrai fichier.

BEGIN;

-- Fonction temporaire de test : exécute une instruction qui DOIT être refusée, avec ce SQLSTATE et cette contrainte.
-- Créée dans pg_temp (schéma temporaire de la session) par le propriétaire, et supprimée avec la transaction.
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

-- Préparation, en tant que propriétaire : une tournée et trois pages RAW de test
-- (pages 1 et 2 de la catégorie 10000000001, page 1 de la catégorie 10000000002)
DO $$
BEGIN
    IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : connecté en tant que %, le propriétaire (superutilisateur) est attendu', current_user;
    END IF;
    INSERT INTO raw.collect_run (collector_version) VALUES ('test');
    INSERT INTO raw.raw_page (run_id, page_type, category_node, list_type, page_number, requested_url,
                              fetch_status, content_sha256, content_bytes, storage_path,
                              capture_method, metadata_path, metadata_sha256)
        SELECT id, 'bestseller_list', v.node, 'paid', v.page, 'https://test', 'ok',
               'fe' || repeat(v.n::text, 62), 1, 'test', 'extension-dom', 'test.json', 'fe' || repeat('c', 62)
          FROM raw.collect_run,
               (VALUES (1, '10000000001', 1), (2, '10000000001', 2), (3, '10000000002', 1)) AS v(n, node, page)
         WHERE collector_version = 'test';
    RAISE NOTICE 'OK test 0 : connecté en tant que propriétaire ; lignes RAW de test créées';
END;
$$;

-- Identifiants des lignes de test, pour les instructions construites plus bas
CREATE TEMP TABLE test_ids ON COMMIT DROP AS
    SELECT (SELECT id FROM raw.raw_page WHERE requested_url = 'https://test'
                                          AND category_node = '10000000001' AND page_number = 1) AS page1,
           (SELECT id FROM raw.raw_page WHERE requested_url = 'https://test'
                                          AND category_node = '10000000001' AND page_number = 2) AS page2,
           (SELECT id FROM raw.raw_page WHERE requested_url = 'https://test'
                                          AND category_node = '10000000002') AS page3;
GRANT SELECT ON test_ids TO books_transformer;

-- ============================================================================================================
-- books_transformer : ce qu'il peut faire, les contraintes, ce qu'il ne peut pas faire
-- ============================================================================================================
SET LOCAL ROLE books_transformer;

DO $$
DECLARE
    page1 bigint := (SELECT page1 FROM test_ids);
    page2 bigint := (SELECT page2 FROM test_ids);
    page3 bigint := (SELECT page3 FROM test_ids);
    run1  bigint;  -- première exécution
    run   bigint;  -- seconde exécution, qui réextrait la page 1
    -- Colonnes de ranking_entry ; chaque cas refusé ne diffère d'une ligne valide que par un point
    cols  text := 'raw_page_id, extract_run_id, rank, asin, has_card, title, price_amount, currency, rating, '
                  'review_count, cover_url, ku_sticker_hint';
    t     record;
BEGIN
    IF current_user <> 'books_transformer' THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : rôle courant %, books_transformer attendu', current_user;
    END IF;

    -- Test 1 : lecture de raw
    IF (SELECT count(*) FROM raw.raw_page WHERE requested_url = 'https://test') <> 3
       OR NOT EXISTS (SELECT 1 FROM raw.collect_run WHERE collector_version = 'test') THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : lignes RAW de test non lues';
    END IF;
    RAISE NOTICE 'OK test 1 : books_transformer lit raw.collect_run et raw.raw_page';

    -- Test 2 : une extraction complète est acceptée (exécution, page, trois lignes)
    INSERT INTO staging.extract_run (extractor_version) VALUES ('test') RETURNING id INTO run1;
    INSERT INTO staging.page_extraction (raw_page_id, extract_run_id, status, entry_count)
        VALUES (page1, run1, 'ok', 3);
    EXECUTE format('INSERT INTO staging.ranking_entry (%s) VALUES '
        '(%s, %s, 1, %L, true, %L, 4.99, %L, 4.5, 1234, %L, true), '      -- carte complète
        '(%s, %s, 2, %L, true, %L, 0.00, %L, NULL, NULL, %L, false), '    -- carte sans évaluation, prix nul
        '(%s, %s, 31, %L, false, NULL, NULL, NULL, NULL, NULL, NULL, NULL)', -- sans carte : tout inconnu
        cols, page1, run1, 'B0FAUX0001', 'Titre inventé', 'EUR', 'https://test/couverture.jpg',
              page1, run1, 'B0FAUX0002', 'Autre titre', 'EUR', 'https://test/couverture2.jpg',
              page1, run1, 'B0FAUX0031');
    RAISE NOTICE 'OK test 2 : extraction acceptée (avec carte, carte sans évaluation, sans carte)';

    -- Test 3 : changer l'exécution d'une page est refusé tant que des lignes de l'ancienne exécution existent
    INSERT INTO staging.extract_run (extractor_version) VALUES ('test-2') RETURNING id INTO run;
    PERFORM pg_temp.expect_refusal(3, 'nouvelle exécution enregistrée avant la suppression des anciennes lignes',
        format('UPDATE staging.page_extraction SET extract_run_id = %s WHERE raw_page_id = %s', run, page1),
        '23503', 'ranking_entry_page_extraction_fk');

    -- Test 4 : réextraction complète, dans l'ordre de la décision 011 : DELETE, UPDATE, INSERT
    DELETE FROM staging.ranking_entry WHERE raw_page_id = page1;
    UPDATE staging.page_extraction
       SET extract_run_id = run, status = 'ok', error_message = NULL, entry_count = 1, extracted_at = now()
     WHERE raw_page_id = page1;
    EXECUTE format('INSERT INTO staging.ranking_entry (%s) VALUES '
        '(%s, %s, 1, %L, false, NULL, NULL, NULL, NULL, NULL, NULL, NULL)', cols, page1, run, 'B0FAUX0001');
    IF (SELECT extract_run_id FROM staging.page_extraction WHERE raw_page_id = page1) <> run
       OR (SELECT count(*) FROM staging.ranking_entry WHERE raw_page_id = page1) <> 1
       OR EXISTS (SELECT 1 FROM staging.ranking_entry WHERE raw_page_id = page1 AND extract_run_id <> run) THEN
        RAISE EXCEPTION 'ÉCHEC test 4 : réextraction incomplète';
    END IF;
    RAISE NOTICE 'OK test 4 : réextraction acceptée (DELETE, UPDATE de page_extraction, INSERT)';

    -- Tests 5 et 6 : la clé composée refuse une ligne d'une autre exécution, et une ligne sans page_extraction
    PERFORM pg_temp.expect_refusal(5, 'ligne de l''ancienne exécution pour une page réextraite',
        format('INSERT INTO staging.ranking_entry (%s) VALUES '
               '(%s, %s, 2, %L, false, NULL, NULL, NULL, NULL, NULL, NULL, NULL)', cols, page1, run1, 'B0FAUX0002'),
        '23503', 'ranking_entry_page_extraction_fk');
    PERFORM pg_temp.expect_refusal(6, 'ligne d''une page sans page_extraction',
        format('INSERT INTO staging.ranking_entry (%s) VALUES '
               '(%s, %s, 1, %L, false, NULL, NULL, NULL, NULL, NULL, NULL, NULL)', cols, page3, run, 'B0FAUX0001'),
        '23503', 'ranking_entry_page_extraction_fk');

    -- Test 7 : page en échec, avec motif et sans ligne ; clôture de l'exécution
    INSERT INTO staging.page_extraction (raw_page_id, extract_run_id, status, error_message, entry_count)
        VALUES (page2, run, 'parse_failed', 'prix illisible au rang 7', 0);
    UPDATE staging.extract_run
       SET finished_at = now(), status = 'partial', pages_extracted = 1, pages_failed = 1, notes = 'test'
     WHERE id = run;
    RAISE NOTICE 'OK test 7 : page en échec enregistrée, exécution close';

    -- Tests 10 à 29 : lignes refusées, chacune par la contrainte attendue
    FOR t IN
        SELECT * FROM (VALUES
            (10, 'sans carte mais avec un prix',
                 format('(%s, %s, 40, %L, false, NULL, 4.99, %L, NULL, NULL, NULL, NULL)', page1, run, 'B0FAUX0040', 'EUR'),
                 '23514', 'ranking_entry_no_card_ck'),
            (11, 'sans carte mais avec un titre',
                 format('(%s, %s, 41, %L, false, %L, NULL, NULL, NULL, NULL, NULL, NULL)', page1, run, 'B0FAUX0041', 'Titre'),
                 '23514', 'ranking_entry_no_card_ck'),
            (12, 'sans carte mais avec une couverture',
                 format('(%s, %s, 42, %L, false, NULL, NULL, NULL, NULL, NULL, %L, NULL)', page1, run, 'B0FAUX0042', 'https://test/c.jpg'),
                 '23514', 'ranking_entry_no_card_ck'),
            (13, 'sans carte mais avec l''indice ku-sticker',
                 format('(%s, %s, 43, %L, false, NULL, NULL, NULL, NULL, NULL, NULL, false)', page1, run, 'B0FAUX0043'),
                 '23514', 'ranking_entry_no_card_ck'),
            (14, 'note sans nombre d''évaluations',
                 format('(%s, %s, 44, %L, true, NULL, NULL, NULL, 4.5, NULL, NULL, NULL)', page1, run, 'B0FAUX0044'),
                 '23514', 'ranking_entry_rating_reviews_ck'),
            (15, 'nombre d''évaluations sans note',
                 format('(%s, %s, 45, %L, true, NULL, NULL, NULL, NULL, 12, NULL, NULL)', page1, run, 'B0FAUX0045'),
                 '23514', 'ranking_entry_rating_reviews_ck'),
            (16, 'prix sans devise',
                 format('(%s, %s, 46, %L, true, NULL, 4.99, NULL, NULL, NULL, NULL, NULL)', page1, run, 'B0FAUX0046'),
                 '23514', 'ranking_entry_price_currency_ck'),
            (17, 'devise sans prix',
                 format('(%s, %s, 47, %L, true, NULL, NULL, %L, NULL, NULL, NULL, NULL)', page1, run, 'B0FAUX0047', 'EUR'),
                 '23514', 'ranking_entry_price_currency_ck'),
            (18, 'prix négatif',
                 format('(%s, %s, 48, %L, true, NULL, -0.01, %L, NULL, NULL, NULL, NULL)', page1, run, 'B0FAUX0048', 'EUR'),
                 '23514', 'ranking_entry_price_ck'),
            (19, 'devise mal formée',
                 format('(%s, %s, 49, %L, true, NULL, 4.99, %L, NULL, NULL, NULL, NULL)', page1, run, 'B0FAUX0049', '€'),
                 '23514', 'ranking_entry_currency_ck'),
            (20, 'note supérieure à 5',
                 format('(%s, %s, 50, %L, true, NULL, NULL, NULL, 5.5, 3, NULL, NULL)', page1, run, 'B0FAUX0050'),
                 '23514', 'ranking_entry_rating_ck'),
            (21, 'note négative',
                 format('(%s, %s, 51, %L, true, NULL, NULL, NULL, -0.5, 3, NULL, NULL)', page1, run, 'B0FAUX0051'),
                 '23514', 'ranking_entry_rating_ck'),
            (22, 'nombre d''évaluations négatif',
                 format('(%s, %s, 52, %L, true, NULL, NULL, NULL, 4.0, -1, NULL, NULL)', page1, run, 'B0FAUX0052'),
                 '23514', 'ranking_entry_review_count_ck'),
            (23, 'rang 0',
                 format('(%s, %s, 0, %L, false, NULL, NULL, NULL, NULL, NULL, NULL, NULL)', page1, run, 'B0FAUX0053'),
                 '23514', 'ranking_entry_rank_ck'),
            (24, 'rang 101',
                 format('(%s, %s, 101, %L, false, NULL, NULL, NULL, NULL, NULL, NULL, NULL)', page1, run, 'B0FAUX0054'),
                 '23514', 'ranking_entry_rank_ck'),
            (25, 'ASIN mal formé',
                 format('(%s, %s, 55, %L, false, NULL, NULL, NULL, NULL, NULL, NULL, NULL)', page1, run, 'b0faux0055'),
                 '23514', 'ranking_entry_asin_ck'),
            (26, 'doublon de rang dans une page',
                 format('(%s, %s, 1, %L, false, NULL, NULL, NULL, NULL, NULL, NULL, NULL)', page1, run, 'B0FAUX0056'),
                 '23505', 'ranking_entry_pk'),
            (27, 'doublon d''ASIN dans une page',
                 format('(%s, %s, 57, %L, false, NULL, NULL, NULL, NULL, NULL, NULL, NULL)', page1, run, 'B0FAUX0001'),
                 '23505', 'ranking_entry_asin_uq'),
            (28, 'page RAW inexistante',
                 format('(%s, %s, 58, %L, false, NULL, NULL, NULL, NULL, NULL, NULL, NULL)', -1, run, 'B0FAUX0058'),
                 '23503', 'ranking_entry_page_extraction_fk'),
            (29, 'exécution inexistante',
                 format('(%s, %s, 59, %L, false, NULL, NULL, NULL, NULL, NULL, NULL, NULL)', page1, -1, 'B0FAUX0059'),
                 '23503', 'ranking_entry_page_extraction_fk')
        ) AS v(num, label, row_sql, state, expected)
        ORDER BY num
    LOOP
        PERFORM pg_temp.expect_refusal(t.num, t.label,
            format('INSERT INTO staging.ranking_entry (%s) VALUES %s', cols, t.row_sql), t.state, t.expected);
    END LOOP;

    -- Test 30 : le même ASIN dans une autre page reste permis (une ligne par page et par rang)
    INSERT INTO staging.page_extraction (raw_page_id, extract_run_id, status, entry_count) VALUES (page3, run, 'ok', 1);
    EXECUTE format('INSERT INTO staging.ranking_entry (%s) VALUES '
        '(%s, %s, 1, %L, false, NULL, NULL, NULL, NULL, NULL, NULL, NULL)', cols, page3, run, 'B0FAUX0001');
    RAISE NOTICE 'OK test 30 : même ASIN dans une autre page accepté';

    -- Tests 31 à 36 : page_extraction et extract_run
    PERFORM pg_temp.expect_refusal(31, 'page en statut inconnu',
        -- Motif présent et aucune ligne : seul le statut est en faute (page_extraction_result_ck respectée)
        format('UPDATE staging.page_extraction SET status = %L WHERE raw_page_id = %s', 'aborted', page2),
        '23514', 'page_extraction_status_ck');
    PERFORM pg_temp.expect_refusal(32, 'page ok avec un motif d''échec',
        format('UPDATE staging.page_extraction SET error_message = %L WHERE raw_page_id = %s', 'motif', page1),
        '23514', 'page_extraction_result_ck');
    PERFORM pg_temp.expect_refusal(33, 'page ok sans aucune ligne',
        format('UPDATE staging.page_extraction SET entry_count = 0 WHERE raw_page_id = %s', page1),
        '23514', 'page_extraction_result_ck');
    PERFORM pg_temp.expect_refusal(34, 'page en échec sans motif',
        format('UPDATE staging.page_extraction SET error_message = NULL WHERE raw_page_id = %s', page2),
        '23514', 'page_extraction_result_ck');
    PERFORM pg_temp.expect_refusal(35, 'page en échec avec des lignes',
        format('UPDATE staging.page_extraction SET entry_count = 3 WHERE raw_page_id = %s', page2),
        '23514', 'page_extraction_result_ck');
    PERFORM pg_temp.expect_refusal(36, 'exécution au statut « aborted »',
        format('UPDATE staging.extract_run SET status = %L WHERE id = %s', 'aborted', run),
        '23514', 'extract_run_status_ck');

    -- Tests 40 à 58 : droits refusés à books_transformer
    FOR t IN
        SELECT * FROM (VALUES
            (40, 'INSERT dans raw.collect_run',
                 'INSERT INTO raw.collect_run (collector_version) VALUES (''test'')'),
            (41, 'UPDATE de raw.collect_run',
                 'UPDATE raw.collect_run SET notes = ''x'' WHERE collector_version = ''test'''),
            (42, 'DELETE dans raw.collect_run',
                 'DELETE FROM raw.collect_run WHERE collector_version = ''test'''),
            (43, 'INSERT dans raw.raw_page',
                 format('INSERT INTO raw.raw_page (run_id, page_type, asin, requested_url, fetch_status, capture_method) '
                        'SELECT run_id, %L, %L, %L, %L, %L FROM raw.raw_page WHERE id = %s',
                        'product', 'B0FAUX0001', 'https://test', 'network_error', 'manual-html', page1)),
            (44, 'UPDATE de raw.raw_page',
                 format('UPDATE raw.raw_page SET error_message = %L WHERE id = %s', 'x', page1)),
            (45, 'DELETE dans raw.raw_page',
                 format('DELETE FROM raw.raw_page WHERE id = %s', page1)),
            (46, 'TRUNCATE de raw.raw_page',
                 'TRUNCATE raw.raw_page'),
            (47, 'UPDATE de staging.ranking_entry (seuls DELETE et INSERT sont permis)',
                 format('UPDATE staging.ranking_entry SET title = %L WHERE raw_page_id = %s', 'x', page1)),
            (48, 'TRUNCATE de staging.ranking_entry',
                 'TRUNCATE staging.ranking_entry'),
            (49, 'DELETE dans staging.page_extraction',
                 format('DELETE FROM staging.page_extraction WHERE raw_page_id = %s', page2)),
            (50, 'UPDATE de page_extraction.raw_page_id',
                 format('UPDATE staging.page_extraction SET raw_page_id = %s WHERE raw_page_id = %s', page2, page1)),
            (51, 'DELETE dans staging.extract_run',
                 format('DELETE FROM staging.extract_run WHERE id = %s', run)),
            (52, 'UPDATE de extract_run.extractor_version',
                 format('UPDATE staging.extract_run SET extractor_version = %L WHERE id = %s', 'x', run)),
            (53, 'UPDATE de extract_run.started_at',
                 format('UPDATE staging.extract_run SET started_at = now() WHERE id = %s', run)),
            (54, 'CREATE TABLE dans staging',
                 'CREATE TABLE staging.test_interdit (x int)'),
            (55, 'CREATE TABLE dans raw',
                 'CREATE TABLE raw.test_interdit (x int)'),
            (56, 'CREATE TABLE dans public',
                 'CREATE TABLE public.test_interdit (x int)'),
            (57, 'CREATE TEMP TABLE',
                 'CREATE TEMP TABLE test_interdit (x int)'),
            (58, 'ALTER TABLE de staging.ranking_entry',
                 'ALTER TABLE staging.ranking_entry DROP CONSTRAINT ranking_entry_no_card_ck')
        ) AS v(num, label, sql)
        ORDER BY num
    LOOP
        PERFORM pg_temp.expect_refusal(t.num, t.label, t.sql, '42501', NULL);
    END LOOP;
END;
$$;

-- ============================================================================================================
-- books_collector : aucun accès à staging
-- ============================================================================================================
RESET ROLE;
SET LOCAL ROLE books_collector;

DO $$
DECLARE
    t record;
BEGIN
    IF current_user <> 'books_collector' THEN
        RAISE EXCEPTION 'ÉCHEC test 60 : rôle courant %, books_collector attendu', current_user;
    END IF;
    FOR t IN
        SELECT * FROM (VALUES
            (60, 'lecture de staging.ranking_entry par books_collector',
                 'SELECT count(*) FROM staging.ranking_entry'),
            (61, 'lecture de staging.page_extraction par books_collector',
                 'SELECT count(*) FROM staging.page_extraction'),
            (62, 'lecture de staging.extract_run par books_collector',
                 'SELECT count(*) FROM staging.extract_run'),
            (63, 'INSERT dans staging.extract_run par books_collector',
                 'INSERT INTO staging.extract_run (extractor_version) VALUES (''test'')')
        ) AS v(num, label, sql)
        ORDER BY num
    LOOP
        PERFORM pg_temp.expect_refusal(t.num, t.label, t.sql, '42501', NULL);
    END LOOP;
END;
$$;

-- ============================================================================================================
-- Catalogue, en tant que propriétaire
-- ============================================================================================================
RESET ROLE;

DO $$
BEGIN
    IF col_description('staging.ranking_entry'::regclass,
                       (SELECT attnum FROM pg_attribute
                         WHERE attrelid = 'staging.ranking_entry'::regclass AND attname = 'ku_sticker_hint'))
       NOT LIKE 'Indice NON VÉRIFIÉ%' THEN
        RAISE EXCEPTION 'ÉCHEC test 70 : commentaire de ku_sticker_hint absent ou différent';
    END IF;
    RAISE NOTICE 'OK test 70 : commentaire de ku_sticker_hint présent';

    IF NOT EXISTS (SELECT 1 FROM public.schema_migration WHERE version = 5) THEN
        RAISE EXCEPTION 'ÉCHEC test 71 : migration 5 absente de schema_migration';
    END IF;
    RAISE NOTICE 'OK test 71 : migration 5 inscrite dans schema_migration';

    -- Aucun droit de PUBLIC sur le schéma staging ni sur ses tables
    IF has_schema_privilege('public', 'staging', 'USAGE')
       OR EXISTS (SELECT 1 FROM information_schema.role_table_grants
                   WHERE table_schema = 'staging' AND grantee IN ('PUBLIC', 'books_collector')) THEN
        RAISE EXCEPTION 'ÉCHEC test 72 : PUBLIC ou books_collector a un droit sur staging';
    END IF;
    RAISE NOTICE 'OK test 72 : aucun droit de PUBLIC ni de books_collector sur staging';

    -- La version de l'extracteur d'une page s'obtient par jointure avec extract_run : pas de copie redondante
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'staging' AND table_name = 'page_extraction'
                  AND column_name = 'extractor_version') THEN
        RAISE EXCEPTION 'ÉCHEC test 73 : page_extraction.extractor_version existe encore';
    END IF;
    RAISE NOTICE 'OK test 73 : version de l''extracteur obtenue par jointure avec extract_run seulement';
END;
$$;

ROLLBACK;

-- Vérification finale : aucune ligne de test conservée
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
