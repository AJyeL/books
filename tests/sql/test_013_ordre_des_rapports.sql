-- Tests de la migration 013 : ordre des rapports Amazon Ads par leurs données, nom non jugé (décision 018, note du
-- 9 novembre 2026)
--
-- À exécuter EN TANT QUE PROPRIÉTAIRE de la base, depuis le dossier du dépôt (bash), toutes les migrations appliquées :
--   docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_013_ordre_des_rapports.sql
-- Même principe que test_012 : le propriétaire prépare RAW (lot 2026-12-22T080000Z, empreintes en « fc… », heures
-- d'ingestion fixées explicitement), puis endosse books_collector, books_transformer et books_reader.
-- Les lignes déjà présentes dans la base ne gênent pas : chaque contrôle se limite aux fichiers de test.
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
    IF NOT EXISTS (SELECT 1 FROM public.schema_migration WHERE version = 13) THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : migration 13 absente de schema_migration';
    END IF;
    RAISE NOTICE 'OK test 0 : propriétaire, migration 13 présente';
END;
$$;

INSERT INTO raw.ads_ingest_run (collector_version) VALUES ('test');
CREATE TEMP TABLE test_files (name text PRIMARY KEY, id bigint) ON COMMIT DROP;
GRANT SELECT ON test_files TO books_transformer, books_reader, books_collector;

-- Meilleure estimation des fichiers de test, sous la forme « jour=impressions » triée par jour
CREATE FUNCTION pg_temp.best(kind text) RETURNS text LANGUAGE sql AS $$
    SELECT string_agg(b.day::text || '=' || b.impressions, ', ' ORDER BY b.day)
      FROM (SELECT ads_report_file_id, day, impressions FROM staging.ads_product_day_best WHERE kind = 'advertised_product'
            UNION ALL
            SELECT ads_report_file_id, day, impressions FROM staging.ads_search_term_day_best WHERE kind = 'search_term') b
     WHERE b.ads_report_file_id IN (SELECT id FROM test_files)
$$;

CREATE FUNCTION pg_temp.extracted(n text, status text, first_day date, last_day date, row_count int) RETURNS void
LANGUAGE sql AS $$
    INSERT INTO staging.ads_file_extraction (ads_report_file_id, extract_run_id, status, row_count, first_day, last_day)
    SELECT t.id, (SELECT id FROM staging.ads_extract_run WHERE extractor_version = 'test'), status, row_count,
           first_day, last_day
      FROM test_files t WHERE t.name = n;
$$;
CREATE FUNCTION pg_temp.st_row(n text, day date, impressions int) RETURNS void LANGUAGE sql AS $$
    INSERT INTO staging.ads_search_term_day (ads_report_file_id, extract_run_id, day, campaign_id, ad_group_id,
                                             target_id, match_type, search_term_code, impressions)
    SELECT t.id, e.extract_run_id, day, '1', '2', '3', 'TARGETING_EXPRESSION', 1, impressions
      FROM test_files t JOIN staging.ads_file_extraction e ON e.ads_report_file_id = t.id WHERE t.name = n;
$$;
CREATE FUNCTION pg_temp.ap_row(n text, day date, impressions int) RETURNS void LANGUAGE sql AS $$
    INSERT INTO staging.ads_product_day (ads_report_file_id, extract_run_id, day, campaign_id, ad_group_id,
                                         advertised_product_id, impressions)
    SELECT t.id, e.extract_run_id, day, '1', '2', 'B0FAUX0001', impressions
      FROM test_files t JOIN staging.ads_file_extraction e ON e.ads_report_file_id = t.id WHERE t.name = n;
$$;

-- ============================================================================================================
-- Test 1 : RAW, nom non jugé ; commentaires ; vues et droits
-- ============================================================================================================
SET LOCAL ROLE books_collector;
-- Un fichier nommé librement, sans horodatage : ok dans RAW, date et heure du nom NULL
INSERT INTO raw.ads_report_file (run_id, lot, original_name, content_sha256, content_bytes, storage_path,
                                 report_type, export_date, export_time, status)
SELECT id, '2026-12-22T080000Z', 'Termes_hebdo.csv', 'fc' || repeat('0', 62), 1, 'test/libre', 'search_term', NULL, NULL, 'ok'
  FROM raw.ads_ingest_run WHERE collector_version = 'test';
RESET ROLE;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM raw.ads_report_file WHERE original_name = 'Termes_hebdo.csv' AND status = 'ok'
                    AND export_date IS NULL AND content_sha256 = 'fc' || repeat('0', 62)) THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : le fichier nommé librement n''est pas inscrit ok';
    END IF;
    RAISE NOTICE 'OK test 1 : « Termes_hebdo.csv » inscrit ok dans RAW, sans date ni heure de nom';

    -- Contre-épreuve : la contrainte d'avant la migration 013 refuse cette inscription
    ALTER TABLE raw.ads_report_file ADD CONSTRAINT test_verdict_avant_013_ck CHECK (
        (status = 'invalid' AND reason IS NOT NULL AND reason <> '')
     OR (status = 'ok' AND reason IS NULL AND report_type IS NOT NULL AND export_date IS NOT NULL)) NOT VALID;
    PERFORM pg_temp.expect_refusal(1, 'fichier nommé librement, sous la contrainte d''avant la migration 013',
        $q$INSERT INTO raw.ads_report_file (run_id, lot, original_name, content_sha256, content_bytes, storage_path,
           report_type, status) SELECT id, '2026-12-22T080000Z', 'Termes_hebdo2.csv', 'fc' || repeat('1', 62), 1,
           'test/libre2', 'search_term', 'ok' FROM raw.ads_ingest_run WHERE collector_version = 'test'$q$,
        '23514', 'test_verdict_avant_013_ck');
    ALTER TABLE raw.ads_report_file DROP CONSTRAINT test_verdict_avant_013_ck;

    IF col_description('raw.ads_report_file'::regclass,
                       (SELECT attnum FROM pg_attribute WHERE attrelid = 'raw.ads_report_file'::regclass
                         AND attname = 'export_date')) NOT LIKE '%PAS une date d''export%'
       OR col_description('raw.ads_report_file'::regclass,
                          (SELECT attnum FROM pg_attribute WHERE attrelid = 'raw.ads_report_file'::regclass
                            AND attname = 'export_time')) IS NULL THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : commentaires de export_date et export_time absents ou faux';
    END IF;
    RAISE NOTICE 'OK test 1 : commentaires de RAW sur le vrai sens de l''horodatage du nom';

    IF (SELECT count(*) FROM pg_class WHERE relnamespace = 'staging'::regnamespace AND relkind = 'v'
          AND relname IN ('ads_day_source', 'ads_product_day_best', 'ads_search_term_day_best')
          AND 'security_invoker=true' = ANY (reloptions)) <> 3 THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : les trois vues ne sont pas toutes en security_invoker';
    END IF;
    IF (SELECT string_agg(g, ', ' ORDER BY g) FROM (
            SELECT c.relname || ':' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END
                   || ':' || a.privilege_type AS g
              FROM pg_class c, aclexplode(c.relacl) a
             WHERE c.relnamespace = 'staging'::regnamespace AND c.relkind = 'v' AND c.relname LIKE 'ads\_%'
               AND a.grantee <> c.relowner) x)
       IS DISTINCT FROM 'ads_day_source:books_transformer:SELECT, ads_product_day_best:books_transformer:SELECT, '
                        'ads_search_term_day_best:books_transformer:SELECT' THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : droits sur les vues : lecture par books_transformer seulement attendue';
    END IF;
    RAISE NOTICE 'OK test 1 : trois vues en security_invoker, lues par books_transformer seulement';
END;
$$;

-- ============================================================================================================
-- Préparation, en tant que propriétaire : fichiers RAW ok, heures d'ingestion explicites
--   st_a : nom N, données du 15 oct. au 4 nov., ingéré EN DERNIER (10 h)       → fenêtre ancienne
--   st_b : même nom N, données du 4 nov. au 1er déc., ingéré avant (9 h)        → fenêtre récente
--   (st_a est inscrit après st_b : un ordre par le nom, ou par l'identifiant, choisirait st_a)
-- ============================================================================================================
CREATE FUNCTION pg_temp.add_file(n text, digit text, kind text, ingested timestamptz) RETURNS void LANGUAGE sql AS $$
    INSERT INTO raw.ads_report_file (run_id, lot, original_name, content_sha256, content_bytes, storage_path,
                                     report_type, export_date, export_time, status, ingested_at)
    SELECT r.id, '2026-12-22T080000Z', CASE WHEN n LIKE 'st_%' THEN 'Search_term_-_11_04_2026T21_16_00.csv'
                                            ELSE n || '.csv' END,
           'fc' || repeat(digit, 62), 1, 'test/' || n, kind, date '2026-11-04', time '21:16:00', 'ok', ingested
      FROM raw.ads_ingest_run r WHERE r.collector_version = 'test';
    INSERT INTO test_files SELECT n, id FROM raw.ads_report_file WHERE content_sha256 = 'fc' || repeat(digit, 62);
$$;
DO $$ BEGIN PERFORM pg_temp.add_file('st_b', '2', 'search_term', timestamptz '2026-12-22 09:00:00+00'); END $$;
DO $$ BEGIN PERFORM pg_temp.add_file('st_a', '3', 'search_term', timestamptz '2026-12-22 10:00:00+00'); END $$;

-- Extraction et lignes, sous books_transformer
SET LOCAL ROLE books_transformer;
INSERT INTO staging.ads_extract_run (extractor_version) VALUES ('test');
DO $$ BEGIN PERFORM pg_temp.extracted('st_b', 'ok', '2026-11-04', '2026-12-01', 2); END $$;
DO $$ BEGIN PERFORM pg_temp.st_row('st_b', '2026-11-04', 190), pg_temp.st_row('st_b', '2026-12-01', 200); END $$;
DO $$ BEGIN PERFORM pg_temp.extracted('st_a', 'ok', '2026-10-15', '2026-11-04', 2); END $$;
DO $$ BEGIN PERFORM pg_temp.st_row('st_a', '2026-10-15', 100), pg_temp.st_row('st_a', '2026-11-04', 110); END $$;
RESET ROLE;

-- ============================================================================================================
-- Test 2 : rapports programmés de même nom, fenêtres différentes : le plus récent par fin de fenêtre l'emporte
-- ============================================================================================================
DO $$
BEGIN
    IF pg_temp.best('search_term') IS DISTINCT FROM '2026-10-15=100, 2026-11-04=190, 2026-12-01=200' THEN
        RAISE EXCEPTION 'ÉCHEC test 2 : même nom, fenêtres différentes : obtenu %, attendu la fenêtre finissant le '
                        '1er décembre sur la partie commune (4 novembre = 190)', pg_temp.best('search_term');
    END IF;
    RAISE NOTICE 'OK test 2 : même nom, deux fenêtres : la fin de fenêtre la plus récente l''emporte (4 novembre = 190), quel que soit l''ordre d''ingestion';
END;
$$;

-- ============================================================================================================
-- Test 3 : export récent avec Advertised product seul ; puis Search term récent sans activité (jamais retenu)
-- ============================================================================================================
DO $$ BEGIN PERFORM pg_temp.add_file('ap_recent', '4', 'advertised_product', timestamptz '2026-12-22 11:00:00+00'); END $$;
DO $$ BEGIN PERFORM pg_temp.add_file('st_noact', '5', 'search_term', timestamptz '2026-12-22 12:00:00+00'); END $$;
SET LOCAL ROLE books_transformer;
DO $$ BEGIN PERFORM pg_temp.extracted('ap_recent', 'ok', '2026-10-15', '2026-12-15', 2); END $$;
DO $$ BEGIN PERFORM pg_temp.ap_row('ap_recent', '2026-10-15', 310), pg_temp.ap_row('ap_recent', '2026-12-15', 320); END $$;
DO $$ BEGIN PERFORM pg_temp.extracted('st_noact', 'no_activity', NULL, NULL, 0); END $$;
RESET ROLE;

DO $$
BEGIN
    IF pg_temp.best('search_term') IS DISTINCT FROM '2026-10-15=100, 2026-11-04=190, 2026-12-01=200' THEN
        RAISE EXCEPTION 'ÉCHEC test 3 : un export sans Search term, ou un Search term sans activité, change les termes : %',
            pg_temp.best('search_term');
    END IF;
    IF pg_temp.best('advertised_product') IS DISTINCT FROM '2026-10-15=310, 2026-12-15=320' THEN
        RAISE EXCEPTION 'ÉCHEC test 3 : Advertised product : %', pg_temp.best('advertised_product');
    END IF;
    IF EXISTS (SELECT 1 FROM staging.ads_day_source WHERE file_id = (SELECT id FROM test_files WHERE name = 'st_noact')) THEN
        RAISE EXCEPTION 'ÉCHEC test 3 : un fichier sans activité est retenu comme source';
    END IF;
    RAISE NOTICE 'OK test 3 : export récent sans Search term : les termes restent à l''export précédent ; un fichier sans activité n''est jamais retenu';
END;
$$;

-- ============================================================================================================
-- Test 4 : deux fichiers du même type et de même dernière date : le dernier ingéré l'emporte
-- ============================================================================================================
DO $$ BEGIN PERFORM pg_temp.add_file('ap_recent2', '6', 'advertised_product', timestamptz '2026-12-22 13:00:00+00'); END $$;
SET LOCAL ROLE books_transformer;
DO $$ BEGIN PERFORM pg_temp.extracted('ap_recent2', 'ok', '2026-12-15', '2026-12-15', 1); END $$;
DO $$ BEGIN PERFORM pg_temp.ap_row('ap_recent2', '2026-12-15', 330); END $$;
RESET ROLE;

DO $$
BEGIN
    -- La couverture de l'export (15 oct. au 15 déc.) est la réunion des bornes de ses deux fichiers ; le fichier retenu
    -- est le dernier ingéré, qui n'a pas de ligne le 15 octobre : l'absence est la meilleure estimation ce jour-là
    IF pg_temp.best('advertised_product') IS DISTINCT FROM '2026-12-15=330' THEN
        RAISE EXCEPTION 'ÉCHEC test 4 : le dernier ingéré n''est pas retenu : %', pg_temp.best('advertised_product');
    END IF;
    IF (SELECT count(*) FROM staging.ads_day_source WHERE file_id = (SELECT id FROM test_files WHERE name = 'ap_recent2')) <> 62 THEN
        RAISE EXCEPTION 'ÉCHEC test 4 : la couverture de l''export n''est pas la réunion des bornes de ses fichiers';
    END IF;
    RAISE NOTICE 'OK test 4 : même dernière date : le dernier ingéré l''emporte sur les 62 jours couverts par l''export';
END;
$$;

-- ============================================================================================================
-- Test 5 : books_reader et books_collector ne lisent pas les vues
-- ============================================================================================================
SET LOCAL ROLE books_reader;
DO $$
BEGIN
    PERFORM pg_temp.expect_refusal(5, 'lecture de staging.ads_day_source par books_reader',
        'SELECT 1 FROM staging.ads_day_source', '42501', NULL);
    PERFORM pg_temp.expect_refusal(5, 'lecture de staging.ads_product_day_best par books_reader',
        'SELECT 1 FROM staging.ads_product_day_best', '42501', NULL);
END;
$$;
RESET ROLE;
SET LOCAL ROLE books_collector;
DO $$
BEGIN
    PERFORM pg_temp.expect_refusal(5, 'lecture de staging.ads_search_term_day_best par books_collector',
        'SELECT 1 FROM staging.ads_search_term_day_best', '42501', NULL);
END;
$$;
RESET ROLE;

ROLLBACK;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM raw.ads_ingest_run WHERE collector_version = 'test')
       OR EXISTS (SELECT 1 FROM raw.ads_report_file WHERE lot = '2026-12-22T080000Z' AND content_sha256 LIKE 'fc%')
       OR EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'test_verdict_avant_013_ck') THEN
        RAISE EXCEPTION 'ÉCHEC : des lignes ou des objets de test ont été conservés';
    END IF;
    RAISE NOTICE 'OK : aucune ligne ni aucun objet de test conservé';
END;
$$;
