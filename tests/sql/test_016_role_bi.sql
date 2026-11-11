-- Tests de la migration 016 : rôle books_bi, lecture de CORE seulement pour Power BI (décision 022, section 7)
--
-- À exécuter EN TANT QUE PROPRIÉTAIRE de la base, depuis le dossier du dépôt (bash), toutes les migrations appliquées :
--   docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_016_role_bi.sql
-- Même principe que test_008 : le propriétaire relève le catalogue, puis endosse books_bi (SET LOCAL ROLE). Les réglages
-- du rôle ne s'appliquent qu'à une vraie connexion : ils sont vérifiés dans le catalogue (test 1) et par la recette.
-- Le mot de passe n'est pas contrôlé : défini à la main sur atlas, il n'existe pas en développement.
-- Tout se déroule dans une transaction annulée par ROLLBACK.
--
-- Liste blanche (test 2) : les colonnes lisibles par books_bi sont exactement toutes celles de core ; leur nombre est
-- écrit en dur et mis à jour par toute migration qui touche core (décision 022, section 3).

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
    IF NOT EXISTS (SELECT 1 FROM public.schema_migration WHERE version = 16) THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : migration 16 absente de schema_migration';
    END IF;
    RAISE NOTICE 'OK test 0 : propriétaire, migration 16 présente';
END;
$$;

-- ============================================================================================================
-- Test 1 : attributs et réglages du rôle
-- ============================================================================================================
DO $$
DECLARE
    r pg_roles;
    settings text[];
BEGIN
    SELECT * INTO r FROM pg_roles WHERE rolname = 'books_bi';
    IF NOT FOUND OR NOT r.rolcanlogin OR r.rolsuper OR r.rolcreatedb OR r.rolcreaterole OR r.rolreplication
       OR r.rolbypassrls OR r.rolconnlimit <> 2 THEN
        RAISE EXCEPTION 'ÉCHEC test 1a : attributs de books_bi inattendus (connexion seule, limite de 2 connexions)';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_auth_members WHERE member = 'books_bi'::regrole) THEN
        RAISE EXCEPTION 'ÉCHEC test 1b : books_bi est membre d''un rôle : %',
            (SELECT string_agg(roleid::regrole::text, ', ') FROM pg_auth_members WHERE member = 'books_bi'::regrole);
    END IF;
    SELECT setconfig INTO settings FROM pg_db_role_setting
     WHERE setrole = 'books_bi'::regrole AND setdatabase = 0;
    IF settings IS NULL
       OR NOT settings @> ARRAY['default_transaction_read_only=on', 'statement_timeout=5min',
                                'idle_in_transaction_session_timeout=5min'] THEN
        RAISE EXCEPTION 'ÉCHEC test 1c : réglages de books_bi : %', coalesce(array_to_string(settings, ', '), 'aucun');
    END IF;
    RAISE NOTICE 'OK test 1 : connexion seule, membre d''aucun rôle, 2 connexions, lecture seule par défaut, délais 5 min';
END;
$$;

-- ============================================================================================================
-- Test 2 : liste blanche, relevée dans le catalogue : exactement toutes les colonnes de core, rien d'autre
-- ============================================================================================================
DO $$
DECLARE
    readable text[];
    core_columns text[];
    extra text;
    missing text;
BEGIN
    SELECT array_agg(n.nspname || '.' || c.relname || '.' || a.attname ORDER BY 1) INTO readable
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
     WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
       AND n.nspname NOT IN ('pg_catalog', 'information_schema')
       AND n.nspname NOT LIKE 'pg\_toast%' AND n.nspname NOT LIKE 'pg\_temp\_%'
       AND has_column_privilege('books_bi', c.oid, a.attnum, 'SELECT');
    SELECT array_agg('core.' || c.relname || '.' || a.attname ORDER BY 1) INTO core_columns
      FROM pg_class c
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
     WHERE c.relnamespace = 'core'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm', 'f');
    SELECT string_agg(x, ', ') INTO extra FROM unnest(readable) AS x WHERE x <> ALL (core_columns);
    SELECT string_agg(x, ', ') INTO missing FROM unnest(core_columns) AS x WHERE x <> ALL (coalesce(readable, '{}'));
    IF extra IS NOT NULL OR missing IS NOT NULL THEN
        RAISE EXCEPTION 'ÉCHEC test 2 : colonnes lisibles hors de core : % ; colonnes de core non lisibles : %',
            coalesce(extra, 'aucune'), coalesce(missing, 'aucune');
    END IF;
    IF cardinality(readable) <> 236 THEN
        RAISE EXCEPTION 'ÉCHEC test 2 : % colonnes lisibles, 236 attendues', cardinality(readable);
    END IF;
    RAISE NOTICE 'OK test 2 : 236 colonnes lisibles, exactement toutes celles de core (tables et vue)';
END;
$$;

-- ============================================================================================================
-- Tests 3 et 4 : schémas visibles, création, fonctions, séquences
-- ============================================================================================================
DO $$
DECLARE
    found text;
BEGIN
    SELECT string_agg(nspname, ', ' ORDER BY nspname) INTO found
      FROM pg_namespace
     WHERE nspname NOT IN ('pg_catalog', 'information_schema') AND nspname NOT LIKE 'pg\_toast%'
       AND nspname NOT LIKE 'pg\_temp\_%'
       AND has_schema_privilege('books_bi', oid, 'USAGE');
    IF found IS DISTINCT FROM 'core, public' THEN
        RAISE EXCEPTION 'ÉCHEC test 3 : schémas visibles par books_bi : % (attendu : core, public)', found;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname NOT LIKE 'pg\_temp\_%'
                AND has_schema_privilege('books_bi', oid, 'CREATE'))
       OR has_database_privilege('books_bi', current_database(), 'CREATE')
       OR has_database_privilege('books_bi', current_database(), 'TEMPORARY') THEN
        RAISE EXCEPTION 'ÉCHEC test 3 : books_bi peut créer un objet (schéma, table ou table temporaire)';
    END IF;
    RAISE NOTICE 'OK test 3 : schémas visibles core et public ; aucun droit de création';

    SELECT string_agg(n.nspname || '.' || p.proname, ', ') INTO found
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\_temp\_%'
       AND has_function_privilege('books_bi', p.oid, 'EXECUTE');
    IF found IS NOT NULL THEN
        RAISE EXCEPTION 'ÉCHEC test 4 : fonctions exécutables par books_bi : %', found;
    END IF;
    SELECT string_agg(n.nspname || '.' || c.relname, ', ') INTO found
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind = 'S' AND n.nspname NOT LIKE 'pg\_temp\_%'
       -- CASE : l'ordre d'évaluation d'un WHERE n'est pas garanti ; has_sequence_privilege échoue sur une non-séquence
       AND CASE WHEN c.relkind = 'S' THEN has_sequence_privilege('books_bi', c.oid, 'USAGE, SELECT, UPDATE') END;
    IF found IS NOT NULL THEN
        RAISE EXCEPTION 'ÉCHEC test 4 : séquences utilisables par books_bi : %', found;
    END IF;
    RAISE NOTICE 'OK test 4 : aucune fonction exécutable ni séquence utilisable hors du catalogue système';
END;
$$;

-- ============================================================================================================
-- Test 5 : aucune écriture sur core (catalogue, puis essais réels sous books_bi, lecture seule désactivée)
-- ============================================================================================================
DO $$
DECLARE
    found text;
BEGIN
    SELECT string_agg(c.relname, ', ') INTO found
      FROM pg_class c
     WHERE c.relnamespace = 'core'::regnamespace AND c.relkind IN ('r', 'v')
       AND has_table_privilege('books_bi', c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN');
    IF found IS NOT NULL THEN
        RAISE EXCEPTION 'ÉCHEC test 5 : droit autre que SELECT sur core : %', found;
    END IF;
    RAISE NOTICE 'OK test 5a : aucun droit autre que SELECT sur les tables et la vue de core';
END;
$$;

-- Sous SET ROLE, les réglages du rôle (lecture seule par défaut) ne s'appliquent pas : la transaction reste en
-- lecture-écriture, et les refus ci-dessous viennent donc des seuls droits (comme le test 8 du test 008)
SET LOCAL ROLE books_bi;
SELECT pg_temp.expect_refusal(5, 'books_bi : INSERT', 'INSERT INTO core.category (source, category_node, first_list_day, last_list_day) VALUES (''amazon_fr'', ''1'', ''2026-12-01'', ''2026-12-01'')', '42501', NULL);
SELECT pg_temp.expect_refusal(5, 'books_bi : UPDATE', 'UPDATE core.build_run SET core_version = ''x''', '42501', NULL);
SELECT pg_temp.expect_refusal(5, 'books_bi : DELETE', 'DELETE FROM core.ranking_day', '42501', NULL);
SELECT pg_temp.expect_refusal(5, 'books_bi : TRUNCATE', 'TRUNCATE core.book CASCADE', '42501', NULL);
SELECT pg_temp.expect_refusal(5, 'books_bi : CREATE TEMP TABLE', 'CREATE TEMP TABLE t (x int)', '42501', NULL);

-- ============================================================================================================
-- Test 6 : lectures refusées hors de core, lectures permises dans core
-- ============================================================================================================
SELECT pg_temp.expect_refusal(6, 'books_bi : raw.raw_page', 'SELECT count(id) FROM raw.raw_page', '42501', NULL);
SELECT pg_temp.expect_refusal(6, 'books_bi : raw.ads_report_file', 'SELECT count(*) FROM raw.ads_report_file', '42501', NULL);
SELECT pg_temp.expect_refusal(6, 'books_bi : staging.ranking_entry', 'SELECT count(*) FROM staging.ranking_entry', '42501', NULL);
SELECT pg_temp.expect_refusal(6, 'books_bi : staging.ads_product_day', 'SELECT count(*) FROM staging.ads_product_day', '42501', NULL);
SELECT pg_temp.expect_refusal(6, 'books_bi : guide.reference_entry', 'SELECT count(*) FROM guide.reference_entry', '42501', NULL);
SELECT pg_temp.expect_refusal(6, 'books_bi : mapping.text_code', 'SELECT count(*) FROM mapping.text_code', '42501', NULL);
SELECT pg_temp.expect_refusal(6, 'books_bi : public.schema_migration', 'SELECT count(*) FROM public.schema_migration', '42501', NULL);
SELECT pg_temp.expect_refusal(6, 'books_bi : core.rebuild', 'SELECT core.rebuild(''test'')', '42501', NULL);
DO $$
BEGIN
    PERFORM count(*) FROM core.book;
    PERFORM count(*) FROM core.ranking_day;
    PERFORM count(*) FROM core.build_run;
    PERFORM count(*) FROM core.product_day;
    PERFORM count(*) FROM core.book_current;
    RAISE NOTICE 'OK test 6 : books_bi lit les tables de core, le journal et la vue core.book_current';
END;
$$;
RESET ROLE;

-- ============================================================================================================
-- Test 7 : avertissement sur les trois portées du rang général (décision 021, note du 11 novembre 2026)
-- ============================================================================================================
DO $$
DECLARE
    note text := col_description('core.product_day'::regclass,
                                 (SELECT attnum FROM pg_attribute WHERE attrelid = 'core.product_day'::regclass
                                     AND attname = 'general_rank'));
BEGIN
    IF note IS NULL OR note NOT LIKE '%Trois portées%' OR note NOT LIKE '%qu''à portée égale%'
       OR note NOT LIKE '%general_rank_category_node est NULL%' THEN
        RAISE EXCEPTION 'ÉCHEC test 7 : commentaire de core.product_day.general_rank sans l''avertissement des portées : %',
            coalesce(note, 'aucun');
    END IF;
    RAISE NOTICE 'OK test 7 : commentaire du rang général : trois portées, comparaison à portée égale, nœud NULL';
END;
$$;

ROLLBACK;
