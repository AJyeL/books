-- Tests de la migration 002 : droits du rôle books_collector
--
-- À exécuter EN TANT QUE books_collector, depuis le dossier du dépôt :
--   docker exec -i books-postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U books_collector -d "$POSTGRES_DB"' < tests/sql/test_002_role_collecteur.sql
-- (connexion locale au conteneur : aucun mot de passe demandé)
--
-- Les tests se vérifient eux-mêmes :
--   - chaque vérification réussie affiche « NOTICE:  OK … » ;
--   - un refus attendu doit être une erreur de droit (SQLSTATE 42501, insufficient_privilege) :
--     une opération acceptée à tort, ou refusée pour une autre raison, provoque « ÉCHEC » ;
--   - grâce à ON_ERROR_STOP=1, psql s'arrête au premier échec : code de sortie 0 = tout est conforme.
-- Tout se déroule dans une transaction annulée par ROLLBACK : aucune donnée n'est conservée.

BEGIN;

DO $$
DECLARE
    run_id  bigint;
    page_id bigint;
    t       record;
BEGIN
    -- Test 0 : les tests n'ont de sens qu'avec le bon rôle
    IF current_user <> 'books_collector' THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : connecté en tant que %, books_collector attendu', current_user;
    END IF;
    RAISE NOTICE 'OK test 0 : connecté en tant que books_collector';

    -- Test 1 : INSERT accepté dans les deux tables (identifiants générés, sans droit sur les séquences)
    INSERT INTO raw.collect_run (collector_version) VALUES ('test') RETURNING id INTO run_id;
    -- capture_method : obligatoire pour toute nouvelle ligne depuis la migration 004
    INSERT INTO raw.raw_page (run_id, page_type, asin, requested_url, fetch_status, capture_method)
        VALUES (run_id, 'product', 'B0F8VVKM5S', 'https://test', 'network_error', 'manual-html')
        RETURNING id INTO page_id;
    RAISE NOTICE 'OK test 1 : INSERT accepté (collect_run %, raw_page %)', run_id, page_id;

    -- Test 2 : UPDATE des colonnes de clôture accepté
    UPDATE raw.collect_run
       SET finished_at = now(), status = 'success', pages_ok = 1, pages_failed = 0, notes = 'test'
     WHERE id = run_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ÉCHEC test 2 : aucune ligne mise à jour';
    END IF;
    RAISE NOTICE 'OK test 2 : UPDATE des colonnes de clôture accepté';

    -- Tests 3 à 15 : chaque instruction doit être refusée pour droit insuffisant.
    -- id = DEFAULT : sinon PostgreSQL refuserait pour une autre raison (colonne GENERATED ALWAYS),
    -- et le test ne prouverait rien sur les droits.
    FOR t IN
        SELECT * FROM (VALUES
            (3,  'UPDATE de collect_run.id',
                 format('UPDATE raw.collect_run SET id = DEFAULT WHERE id = %s', run_id)),
            (4,  'UPDATE de collect_run.started_at',
                 format('UPDATE raw.collect_run SET started_at = now() WHERE id = %s', run_id)),
            (5,  'UPDATE de collect_run.collector_version',
                 format('UPDATE raw.collect_run SET collector_version = %L WHERE id = %s', 'test', run_id)),
            (6,  'DELETE sur collect_run',
                 format('DELETE FROM raw.collect_run WHERE id = %s', run_id)),
            (7,  'TRUNCATE sur collect_run',
                 'TRUNCATE raw.collect_run CASCADE'),
            (8,  'UPDATE sur raw_page',
                 format('UPDATE raw.raw_page SET error_message = %L WHERE id = %s', 'test', page_id)),
            (9,  'DELETE sur raw_page',
                 format('DELETE FROM raw.raw_page WHERE id = %s', page_id)),
            (10, 'TRUNCATE sur raw_page',
                 'TRUNCATE raw.raw_page'),
            (11, 'CREATE TABLE dans raw',
                 'CREATE TABLE raw.test_interdit (x int)'),
            (12, 'CREATE TABLE dans public',
                 'CREATE TABLE public.test_interdit (x int)'),
            (13, 'CREATE TEMP TABLE',
                 'CREATE TEMP TABLE test_interdit (x int)'),
            (14, 'ALTER TABLE raw_page DISABLE TRIGGER',
                 'ALTER TABLE raw.raw_page DISABLE TRIGGER raw_page_append_only'),
            (15, 'nextval() direct sur une séquence',
                 'SELECT nextval(''raw.collect_run_id_seq'')')
        ) AS v(num, label, sql)
        ORDER BY num
    LOOP
        BEGIN
            EXECUTE t.sql;
            RAISE EXCEPTION 'ÉCHEC test % : % accepté alors qu''il devait être refusé', t.num, t.label;
        EXCEPTION WHEN insufficient_privilege THEN
            RAISE NOTICE 'OK test % : % refusé (%)', t.num, t.label, SQLERRM;
        END;
    END LOOP;
END;
$$;

ROLLBACK;

-- Vérification finale : aucune ligne de test n'a été conservée
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM raw.collect_run WHERE collector_version = 'test')
       OR EXISTS (SELECT 1 FROM raw.raw_page WHERE requested_url = 'https://test') THEN
        RAISE EXCEPTION 'ÉCHEC : des lignes de test ont été conservées';
    END IF;
    RAISE NOTICE 'OK : aucune ligne de test conservée';
END;
$$;
