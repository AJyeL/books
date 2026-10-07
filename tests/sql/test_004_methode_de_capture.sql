-- Tests de la migration 004 : méthode de capture et métadonnées des captures
--
-- À exécuter EN TANT QUE books_collector, depuis le dossier du dépôt (bash) :
--   docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U books_collector -d "$POSTGRES_DB"' < tests/sql/test_004_methode_de_capture.sql
--
-- Les tests se vérifient eux-mêmes : chaque vérification réussie affiche « NOTICE:  OK … »,
-- et psql s'arrête au premier « ÉCHEC » (code de sortie 0 = tout est conforme).
-- Tout se déroule dans une transaction annulée par ROLLBACK : aucune donnée n'est conservée.
-- Les empreintes de test commencent par « fe » et ne correspondent à aucun vrai fichier.

BEGIN;

DO $$
DECLARE
    run_id bigint;
    sha_a  text := 'fe' || repeat('a', 62);
    sha_b  text := 'fe' || repeat('b', 62);
    sha_j  text := 'fe' || repeat('c', 62);
    t      record;
BEGIN
    -- Test 0 : les tests sont faits avec les droits réels du collecteur
    IF current_user <> 'books_collector' THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : connecté en tant que %, books_collector attendu', current_user;
    END IF;
    RAISE NOTICE 'OK test 0 : connecté en tant que books_collector';

    INSERT INTO raw.collect_run (collector_version) VALUES ('test') RETURNING id INTO run_id;

    -- Tests 1 à 4 : insertions acceptées (droit INSERT de table, valable pour les nouvelles colonnes)
    INSERT INTO raw.raw_page (run_id, page_type, category_node, list_type, page_number, requested_url,
                              fetch_status, content_sha256, content_bytes, storage_path,
                              capture_method, metadata_path, metadata_sha256)
        VALUES (run_id, 'bestseller_list', '10000000001', 'paid', 1, 'https://test',
                'ok', sha_a, 1, 'test', 'extension-dom', 'test.json', sha_j);
    RAISE NOTICE 'OK test 1 : capture extension-dom complète acceptée';

    INSERT INTO raw.raw_page (run_id, page_type, category_node, list_type, page_number, requested_url,
                              fetch_status, content_sha256, content_bytes, storage_path, capture_method)
        VALUES (run_id, 'bestseller_list', '10000000001', 'paid', 1, 'https://test',
                'ok', sha_b, 1, 'test', 'manual-html');
    RAISE NOTICE 'OK test 2 : page manual-html sans JSON acceptée';

    INSERT INTO raw.raw_page (run_id, page_type, category_node, list_type, page_number, requested_url,
                              fetch_status, content_sha256, content_bytes, storage_path, capture_method)
        VALUES (run_id, 'bestseller_list', '10000000001', 'paid', 1, 'https://test',
                'ok', sha_b, 1, 'test', 'manual-html');
    RAISE NOTICE 'OK test 3 : deux pages manual-html de même empreinte acceptées (réingestion en développement)';

    INSERT INTO raw.raw_page (run_id, page_type, category_node, list_type, page_number, requested_url,
                              fetch_status, content_sha256, content_bytes, storage_path, capture_method)
        VALUES (run_id, 'bestseller_list', '10000000001', 'paid', 1, 'https://test',
                'ok', sha_a, 1, 'test', 'manual-html');
    RAISE NOTICE 'OK test 4 : page manual-html de même empreinte qu''une capture extension-dom acceptée';

    -- Tests 5 à 10 : insertions refusées, chacune par la contrainte attendue (et pas par une autre)
    FOR t IN
        SELECT * FROM (VALUES
            (5,  'méthode absente (contrainte NOT VALID, appliquée aux nouvelles lignes)',
                 'raw_page_capture_method_nn', NULL::text, NULL::text, NULL::text),
            (6,  'méthode inconnue',
                 'raw_page_capture_method_check', 'autre', NULL, NULL),
            (7,  'extension-dom sans JSON',
                 'raw_page_capture_metadata_ck', 'extension-dom', NULL, sha_j),
            (8,  'extension-dom sans empreinte du JSON',
                 'raw_page_capture_metadata_ck', 'extension-dom', 'test.json', NULL),
            (9,  'manual-html avec un JSON',
                 'raw_page_capture_metadata_ck', 'manual-html', 'test.json', sha_j),
            (10, 'empreinte du JSON mal formée',
                 'raw_page_metadata_sha256_check', 'extension-dom', 'test.json', 'ABC')
        ) AS v(num, label, expected, method, path, json_sha)
        ORDER BY num
    LOOP
        DECLARE
            violated text;
        BEGIN
            INSERT INTO raw.raw_page (run_id, page_type, category_node, list_type, page_number, requested_url,
                                      fetch_status, content_sha256, content_bytes, storage_path,
                                      capture_method, metadata_path, metadata_sha256)
                VALUES (run_id, 'bestseller_list', '10000000001', 'paid', 1, 'https://test',
                        'ok', 'fe' || repeat('d', 62), 1, 'test', t.method, t.path, t.json_sha);
            RAISE EXCEPTION 'ÉCHEC test % : % accepté alors qu''il devait être refusé', t.num, t.label;
        EXCEPTION WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated = CONSTRAINT_NAME;
            IF violated IS DISTINCT FROM t.expected THEN
                RAISE EXCEPTION 'ÉCHEC test % : % refusé par % au lieu de %', t.num, t.label, violated, t.expected;
            END IF;
            RAISE NOTICE 'OK test % : % refusé par %', t.num, t.label, violated;
        END;
    END LOOP;

    -- Test 11 : une capture extension-dom déjà déposée (même empreinte) est refusée par l'index unique partiel
    BEGIN
        INSERT INTO raw.raw_page (run_id, page_type, category_node, list_type, page_number, requested_url,
                                  fetch_status, content_sha256, content_bytes, storage_path,
                                  capture_method, metadata_path, metadata_sha256)
            VALUES (run_id, 'bestseller_list', '10000000001', 'paid', 1, 'https://test',
                    'invalid', sha_a, 1, 'test', 'extension-dom', 'test2.json', sha_j);
        RAISE EXCEPTION 'ÉCHEC test 11 : deux captures extension-dom de même empreinte acceptées';
    EXCEPTION WHEN unique_violation THEN
        DECLARE
            violated text;
        BEGIN
            GET STACKED DIAGNOSTICS violated = CONSTRAINT_NAME;
            IF violated IS DISTINCT FROM 'raw_page_capture_sha256_uq' THEN
                RAISE EXCEPTION 'ÉCHEC test 11 : refusé par % au lieu de raw_page_capture_sha256_uq', violated;
            END IF;
        END;
        RAISE NOTICE 'OK test 11 : deux captures extension-dom de même empreinte refusées par l''index unique partiel';
    END;

    -- Test 12 : les nouvelles colonnes ne sont pas modifiables par le collecteur
    BEGIN
        EXECUTE format('UPDATE raw.raw_page SET capture_method = %L WHERE run_id = %s', 'manual-html', run_id);
        RAISE EXCEPTION 'ÉCHEC test 12 : UPDATE de capture_method accepté';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'OK test 12 : UPDATE de capture_method refusé (%)', SQLERRM;
    END;

    -- Tests 13 et 14 : catalogue
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'raw_page_capture_method_nn' AND conrelid = 'raw.raw_page'::regclass
                      AND NOT convalidated) THEN
        RAISE EXCEPTION 'ÉCHEC test 13 : contrainte raw_page_capture_method_nn absente ou validée';
    END IF;
    RAISE NOTICE 'OK test 13 : méthode obligatoire en NOT VALID (lignes anciennes non vérifiées)';

    IF NOT EXISTS (SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
                    WHERE c.relname = 'raw_page_capture_sha256_uq' AND i.indisunique
                      AND pg_get_expr(i.indpred, i.indrelid) LIKE '%extension-dom%') THEN
        RAISE EXCEPTION 'ÉCHEC test 14 : index raw_page_capture_sha256_uq absent, non unique ou non partiel';
    END IF;
    RAISE NOTICE 'OK test 14 : index unique partiel sur content_sha256, limité aux captures extension-dom';
END;
$$;

ROLLBACK;

-- Vérification finale : aucune ligne de test conservée
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM raw.collect_run WHERE collector_version = 'test')
       OR EXISTS (SELECT 1 FROM raw.raw_page WHERE requested_url = 'https://test') THEN
        RAISE EXCEPTION 'ÉCHEC : des lignes de test ont été conservées';
    END IF;
    RAISE NOTICE 'OK : aucune ligne de test conservée';
END;
$$;
