-- Tests de la migration 011 : rapports Amazon Ads dans RAW (décision 018, lot A)
--
-- À exécuter EN TANT QUE PROPRIÉTAIRE de la base, depuis le dossier du dépôt (bash), toutes les migrations appliquées :
--   docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_011_rapports_ads.sql
-- Même principe que test_008 : le propriétaire relève le catalogue, puis endosse books_collector, books_transformer et
-- books_reader (SET LOCAL ROLE). Les lignes de test ont la version « test » et le lot 2026-12-05T201500Z, et des
-- empreintes en « fe… » ; les lignes déjà présentes dans la base ne gênent pas.
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
    IF NOT EXISTS (SELECT 1 FROM public.schema_migration WHERE version = 11) THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : migration 11 absente de schema_migration';
    END IF;
    RAISE NOTICE 'OK test 0 : propriétaire, migration 11 présente';
END;
$$;

-- ============================================================================================================
-- Test 1 : droits relevés dans le catalogue
-- ============================================================================================================
DO $$
DECLARE
    got text;
BEGIN
    -- Privilèges de table accordés à d'autres que le propriétaire : ceux de books_collector, et la lecture des
    -- fichiers par books_transformer (accordée par la migration 012, lot B)
    SELECT string_agg(g, ', ' ORDER BY g) INTO got FROM (
        SELECT c.relname || ':' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END
               || ':' || a.privilege_type AS g
          FROM pg_class c, aclexplode(c.relacl) a
         WHERE c.oid IN ('raw.ads_ingest_run'::regclass, 'raw.ads_report_file'::regclass)
           AND a.grantee <> c.relowner) x;
    IF got IS DISTINCT FROM 'ads_ingest_run:books_collector:INSERT, ads_ingest_run:books_collector:SELECT, '
                            'ads_report_file:books_collector:INSERT, ads_report_file:books_collector:SELECT, '
                            'ads_report_file:books_transformer:SELECT' THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : droits de table : %', got;
    END IF;
    -- Privilèges de colonne : UPDATE sur les seules colonnes de clôture de ads_ingest_run
    SELECT string_agg(g, ', ' ORDER BY g) INTO got FROM (
        SELECT c.relname || '.' || at.attname || ':' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END
               || ':' || a.privilege_type AS g
          FROM pg_class c
          JOIN pg_attribute at ON at.attrelid = c.oid AND at.attnum > 0
          CROSS JOIN LATERAL aclexplode(at.attacl) a
         WHERE c.oid IN ('raw.ads_ingest_run'::regclass, 'raw.ads_report_file'::regclass)) x;
    IF got IS DISTINCT FROM 'ads_ingest_run.files_invalid:books_collector:UPDATE, '
                            'ads_ingest_run.files_ok:books_collector:UPDATE, '
                            'ads_ingest_run.finished_at:books_collector:UPDATE, '
                            'ads_ingest_run.notes:books_collector:UPDATE, '
                            'ads_ingest_run.status:books_collector:UPDATE' THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : droits de colonne : %', got;
    END IF;
    -- Déclencheurs d'ajout seul
    IF (SELECT count(*) FROM pg_trigger
         WHERE tgrelid = 'raw.ads_report_file'::regclass AND tgfoid = 'raw.forbid_change()'::regprocedure
           AND NOT tgisinternal AND tgenabled = 'O') <> 2 THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : déclencheurs d''ajout seul absents ou désactivés sur raw.ads_report_file';
    END IF;
    RAISE NOTICE 'OK test 1 : lecture et ajout pour books_collector seul, clôture limitée à 5 colonnes, 2 déclencheurs d''ajout seul';
END;
$$;

-- ============================================================================================================
-- Tests 2 et 3 : sous books_collector, une ingestion conforme puis les contraintes
-- ============================================================================================================
SET LOCAL ROLE books_collector;

-- Une exécution, un fichier ok et un fichier invalid conformes
INSERT INTO raw.ads_ingest_run (collector_version) VALUES ('test');
INSERT INTO raw.ads_report_file (run_id, lot, original_name, content_sha256, content_bytes, storage_path,
                                 report_type, export_date, export_time, status, reason)
SELECT id, '2026-12-05T201500Z', 'Search_term_-_12_05_2026T20_05_45.csv', 'fe' || repeat('1', 62), 10,
       'test/ok.csv.gz', 'search_term', '2026-12-05', '20:05:45', 'ok', NULL
  FROM raw.ads_ingest_run WHERE collector_version = 'test';
INSERT INTO raw.ads_report_file (run_id, lot, original_name, content_sha256, content_bytes, storage_path,
                                 report_type, export_date, export_time, status, reason)
SELECT id, '2026-12-05T201500Z', 'vide.csv', 'fe' || repeat('2', 62), 0, 'test/vide.csv.gz',
       NULL, NULL, NULL, 'invalid', 'fichier vide'
  FROM raw.ads_ingest_run WHERE collector_version = 'test';
UPDATE raw.ads_ingest_run SET finished_at = now(), status = 'partial', files_ok = 1, files_invalid = 1, notes = 'bilan'
 WHERE collector_version = 'test';

DO $$
DECLARE
    run bigint := (SELECT id FROM raw.ads_ingest_run WHERE collector_version = 'test');
    base text;
BEGIN
    IF (SELECT count(*) FROM raw.ads_report_file WHERE run_id = run) <> 2 THEN
        RAISE EXCEPTION 'ÉCHEC test 2 : les deux fichiers conformes n''ont pas été déposés';
    END IF;
    RAISE NOTICE 'OK test 2 : books_collector ouvre une exécution, dépose un fichier ok et un invalid, clôt l''exécution';

    base := format('INSERT INTO raw.ads_report_file (run_id, lot, original_name, content_sha256, content_bytes, '
                   'storage_path, report_type, export_date, export_time, status, reason) VALUES (%s, ', run);
    -- Chaque contre-épreuve ne diffère du fichier ok conforme que par le défaut testé
    PERFORM pg_temp.expect_refusal(3, 'ok avec un motif',
        base || $q$'2026-12-05T201500Z', 'a.csv', 'fe' || repeat('3', 62), 1, 'test/a', 'search_term', '2026-12-05', '20:05:45', 'ok', 'motif')$q$,
        '23514', 'ads_report_file_verdict_ck');
    PERFORM pg_temp.expect_refusal(3, 'ok sans type',
        base || $q$'2026-12-05T201500Z', 'a.csv', 'fe' || repeat('3', 62), 1, 'test/a', NULL, '2026-12-05', '20:05:45', 'ok', NULL)$q$,
        '23514', 'ads_report_file_verdict_ck');
    PERFORM pg_temp.expect_refusal(3, 'ok sans date d''export',
        base || $q$'2026-12-05T201500Z', 'a.csv', 'fe' || repeat('3', 62), 1, 'test/a', 'search_term', NULL, NULL, 'ok', NULL)$q$,
        '23514', 'ads_report_file_verdict_ck');
    PERFORM pg_temp.expect_refusal(3, 'invalid sans motif',
        base || $q$'2026-12-05T201500Z', 'a.csv', 'fe' || repeat('3', 62), 1, 'test/a', NULL, NULL, NULL, 'invalid', NULL)$q$,
        '23514', 'ads_report_file_verdict_ck');
    PERFORM pg_temp.expect_refusal(3, 'invalid au motif vide',
        base || $q$'2026-12-05T201500Z', 'a.csv', 'fe' || repeat('3', 62), 1, 'test/a', NULL, NULL, NULL, 'invalid', '')$q$,
        '23514', 'ads_report_file_verdict_ck');
    PERFORM pg_temp.expect_refusal(3, 'date d''export sans heure',
        base || $q$'2026-12-05T201500Z', 'a.csv', 'fe' || repeat('3', 62), 1, 'test/a', 'search_term', '2026-12-05', NULL, 'ok', NULL)$q$,
        '23514', 'ads_report_file_export_ck');
    PERFORM pg_temp.expect_refusal(3, 'statut inconnu',
        base || $q$'2026-12-05T201500Z', 'a.csv', 'fe' || repeat('3', 62), 1, 'test/a', 'search_term', '2026-12-05', '20:05:45', 'blocked', NULL)$q$,
        '23514', 'ads_report_file_status_ck');
    PERFORM pg_temp.expect_refusal(3, 'type inconnu',
        base || $q$'2026-12-05T201500Z', 'a.csv', 'fe' || repeat('3', 62), 1, 'test/a', 'targeting', '2026-12-05', '20:05:45', 'ok', NULL)$q$,
        '23514', 'ads_report_file_type_ck');
    PERFORM pg_temp.expect_refusal(3, 'empreinte mal formée',
        base || $q$'2026-12-05T201500Z', 'a.csv', 'FE' || repeat('3', 62), 1, 'test/a', 'search_term', '2026-12-05', '20:05:45', 'ok', NULL)$q$,
        '23514', 'ads_report_file_sha256_ck');
    PERFORM pg_temp.expect_refusal(3, 'empreinte déjà déposée (dédoublonnage)',
        base || $q$'2026-12-05T201500Z', 'a.csv', 'fe' || repeat('1', 62), 1, 'test/a', 'search_term', '2026-12-05', '20:05:45', 'ok', NULL)$q$,
        '23505', 'ads_report_file_sha256_uq');
    PERFORM pg_temp.expect_refusal(3, 'emplacement déjà utilisé',
        base || $q$'2026-12-05T201500Z', 'a.csv', 'fe' || repeat('3', 62), 1, 'test/ok.csv.gz', 'search_term', '2026-12-05', '20:05:45', 'ok', NULL)$q$,
        '23505', 'ads_report_file_storage_uq');
    PERFORM pg_temp.expect_refusal(3, 'lot mal formé',
        base || $q$'2026-12-05', 'a.csv', 'fe' || repeat('3', 62), 1, 'test/a', 'search_term', '2026-12-05', '20:05:45', 'ok', NULL)$q$,
        '23514', 'ads_report_file_lot_ck');
    PERFORM pg_temp.expect_refusal(3, 'nom vide',
        base || $q$'2026-12-05T201500Z', '', 'fe' || repeat('3', 62), 1, 'test/a', 'search_term', '2026-12-05', '20:05:45', 'ok', NULL)$q$,
        '23514', 'ads_report_file_name_ck');
    PERFORM pg_temp.expect_refusal(3, 'taille négative',
        base || $q$'2026-12-05T201500Z', 'a.csv', 'fe' || repeat('3', 62), -1, 'test/a', 'search_term', '2026-12-05', '20:05:45', 'ok', NULL)$q$,
        '23514', 'ads_report_file_bytes_ck');
    PERFORM pg_temp.expect_refusal(3, 'exécution inconnue',
        $q$INSERT INTO raw.ads_report_file (run_id, lot, original_name, content_sha256, content_bytes, storage_path,
           report_type, export_date, export_time, status, reason) VALUES (-1, '2026-12-05T201500Z', 'a.csv',
           'fe' || repeat('3', 62), 1, 'test/a', 'search_term', '2026-12-05', '20:05:45', 'ok', NULL)$q$,
        '23503', 'ads_report_file_run_id_fkey');
    -- Le contrôle de contenu n'est pas dans RAW : une date d'export antérieure aux données y est admise (lot B)
    EXECUTE base || $q$'2026-12-05T201500Z', 'ancien_01_01_2020T00_00_00.csv', 'fe' || repeat('4', 62), 1, 'test/b',
                       'search_term', '2020-01-01', '00:00:00', 'ok', NULL)$q$;
    RAISE NOTICE 'OK test 3 : aucune contrainte de contenu dans RAW (date d''export ancienne admise)';

    -- Test 4 : books_collector ne modifie ni ne supprime un fichier ; il ne modifie que la clôture d'une exécution
    PERFORM pg_temp.expect_refusal(4, 'UPDATE d''un fichier par books_collector',
        $q$UPDATE raw.ads_report_file SET reason = 'x' WHERE content_sha256 = 'fe' || repeat('2', 62)$q$, '42501', NULL);
    PERFORM pg_temp.expect_refusal(4, 'DELETE d''un fichier par books_collector',
        $q$DELETE FROM raw.ads_report_file WHERE content_sha256 = 'fe' || repeat('2', 62)$q$, '42501', NULL);
    PERFORM pg_temp.expect_refusal(4, 'modification de la version d''une exécution par books_collector',
        $q$UPDATE raw.ads_ingest_run SET collector_version = 'x' WHERE collector_version = 'test'$q$, '42501', NULL);
    PERFORM pg_temp.expect_refusal(4, 'DELETE d''une exécution par books_collector',
        $q$DELETE FROM raw.ads_ingest_run WHERE collector_version = 'test'$q$, '42501', NULL);
END;
$$;
RESET ROLE;

-- ============================================================================================================
-- Test 5 : ajout seul, même pour le propriétaire
-- ============================================================================================================
DO $$
BEGIN
    PERFORM pg_temp.expect_refusal(5, 'UPDATE d''un fichier par le propriétaire',
        $q$UPDATE raw.ads_report_file SET reason = 'x' WHERE content_sha256 = 'fe' || repeat('2', 62)$q$, 'P0001', NULL);
    PERFORM pg_temp.expect_refusal(5, 'DELETE d''un fichier par le propriétaire',
        $q$DELETE FROM raw.ads_report_file WHERE content_sha256 = 'fe' || repeat('2', 62)$q$, 'P0001', NULL);
    -- CASCADE : depuis la migration 012, STAGING référence ces fichiers ; le déclencheur refuse quand même tout
    PERFORM pg_temp.expect_refusal(5, 'TRUNCATE par le propriétaire', 'TRUNCATE raw.ads_report_file CASCADE', 'P0001', NULL);
END;
$$;

-- ============================================================================================================
-- Test 6 : books_transformer lit les fichiers (migration 012) sans jamais les écrire ; books_reader n'a aucun droit
-- ============================================================================================================
SET LOCAL ROLE books_transformer;
DO $$
BEGIN
    PERFORM count(*) FROM raw.ads_report_file;
    RAISE NOTICE 'OK test 6 : books_transformer lit raw.ads_report_file (migration 012)';
    PERFORM pg_temp.expect_refusal(6, 'ajout d''un fichier par books_transformer',
        $q$INSERT INTO raw.ads_report_file (run_id, lot, original_name, content_sha256, content_bytes, storage_path,
           status, reason) SELECT run_id, lot, 'x', 'fe' || repeat('9', 62), 0, 'test/x', 'invalid', 'x'
           FROM raw.ads_report_file LIMIT 1$q$, '42501', NULL);
    PERFORM pg_temp.expect_refusal(6, 'lecture des exécutions par books_transformer', 'SELECT 1 FROM raw.ads_ingest_run', '42501', NULL);
END;
$$;
RESET ROLE;

SET LOCAL ROLE books_reader;
DO $$
BEGIN
    PERFORM pg_temp.expect_refusal(6, 'lecture des fichiers par books_reader', 'SELECT 1 FROM raw.ads_report_file', '42501', NULL);
    PERFORM pg_temp.expect_refusal(6, 'lecture des exécutions par books_reader', 'SELECT 1 FROM raw.ads_ingest_run', '42501', NULL);
END;
$$;
RESET ROLE;

ROLLBACK;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM raw.ads_ingest_run WHERE collector_version = 'test')
       OR EXISTS (SELECT 1 FROM raw.ads_report_file WHERE lot = '2026-12-05T201500Z' AND content_sha256 LIKE 'fe%') THEN
        RAISE EXCEPTION 'ÉCHEC : des lignes de test ont été conservées';
    END IF;
    RAISE NOTICE 'OK : aucune ligne de test conservée';
END;
$$;
