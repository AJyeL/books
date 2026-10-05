-- Tests de la migration 003 : statut « invalid »
--
-- À exécuter EN TANT QUE books_collector, depuis le dossier du dépôt (bash) :
--   docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U books_collector -d "$POSTGRES_DB"' < tests/sql/test_003_statut_invalid.sql
--
-- Les tests se vérifient eux-mêmes : chaque vérification réussie affiche « NOTICE:  OK … »,
-- et psql s'arrête au premier « ÉCHEC » (code de sortie 0 = tout est conforme).
-- Tout se déroule dans une transaction annulée par ROLLBACK : aucune donnée n'est conservée.

BEGIN;

DO $$
DECLARE
    run_id bigint;
BEGIN
    -- Test 0 : les tests sont faits avec les droits réels du collecteur
    IF current_user <> 'books_collector' THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : connecté en tant que %, books_collector attendu', current_user;
    END IF;
    RAISE NOTICE 'OK test 0 : connecté en tant que books_collector';

    INSERT INTO raw.collect_run (collector_version) VALUES ('test') RETURNING id INTO run_id;

    -- Test 1 : une page invalide, avec son fichier conservé pour diagnostic, est acceptée
    INSERT INTO raw.raw_page (run_id, page_type, category_node, list_type, page_number, requested_url,
                              fetch_status, error_message, content_sha256, content_bytes, storage_path)
        VALUES (run_id, 'bestseller_list', '10000000001', 'paid', 1, 'https://test',
                'invalid', 'test', repeat('0', 64), 1, 'test');
    RAISE NOTICE 'OK test 1 : statut invalid accepté avec fichier';

    -- Test 2 : une page invalide sans fichier est acceptée aussi (seul « ok » exige un fichier)
    INSERT INTO raw.raw_page (run_id, page_type, category_node, list_type, page_number, requested_url,
                              fetch_status)
        VALUES (run_id, 'bestseller_list', '10000000001', 'paid', 1, 'https://test', 'invalid');
    RAISE NOTICE 'OK test 2 : statut invalid accepté sans fichier';

    -- Test 3 : un statut inconnu reste refusé par la contrainte
    BEGIN
        INSERT INTO raw.raw_page (run_id, page_type, category_node, list_type, page_number, requested_url,
                                  fetch_status)
            VALUES (run_id, 'bestseller_list', '10000000001', 'paid', 1, 'https://test', 'inconnu');
        RAISE EXCEPTION 'ÉCHEC test 3 : statut inconnu accepté';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK test 3 : statut inconnu refusé (%)', SQLERRM;
    END;
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
