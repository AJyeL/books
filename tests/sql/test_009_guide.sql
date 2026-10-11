-- Tests de la migration 009 : guide de veille, schéma guide (décision 017, sections 3, 4 et 9)
--
-- À exécuter EN TANT QUE PROPRIÉTAIRE de la base, depuis le dossier du dépôt (bash), toutes les migrations appliquées :
--   docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_009_guide.sql
-- Même principe que test_008 : le propriétaire prépare raw et staging (catégories et ASIN inventés), puis endosse
-- books_reader, books_collector et books_transformer (SET LOCAL ROLE). Les lignes déjà présentes dans la base ne
-- gênent pas : chaque contrôle se limite aux catégories et aux ASIN de test.
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

-- Préparation, en tant que propriétaire. Catégorie A (10000000091), Top payant :
--   p1 du 1er octobre : B0TESTA001 (1), B0TESTA002 (2), B0TESTA003 (3)
--   p1 du 2 octobre   : B0TESTA002 (1), B0TESTA001 (2), B0TESTP002 (3)   <- référence de la page 1
--   p1 du 3 octobre   : extraction en échec                              <- ignorée
--   p2 du 1er octobre : B0TESTP001 (51), B0TESTP002 (52)                 <- référence de la page 2
-- Catégorie A, Top gratuit, p1 du 1er octobre : B0TESTF901 (1). Catégorie B (10000000092), Top payant, p1 du 2 : B0TESTB001.
-- Fiches : B0TESTK001 Kindle extraite le 1er et le 2 ; B0TESTS001 papier (skipped) ; B0TESTE001 en échec ;
-- B0TESTI001 refusée à l'ingestion (invalid, jamais extraite).
DO $$
DECLARE
    run bigint;
    ext bigint;
    p record;
    n int := 0;
BEGIN
    IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : connecté en tant que %, le propriétaire (superutilisateur) est attendu', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.schema_migration WHERE version = 9) THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : migration 9 absente de schema_migration';
    END IF;
    INSERT INTO raw.collect_run (collector_version) VALUES ('test') RETURNING id INTO run;
    INSERT INTO staging.extract_run (extractor_version) VALUES ('test') RETURNING id INTO ext;

    FOR p IN SELECT * FROM (VALUES
        ('bestseller_list', '10000000091', 'paid', 1, NULL, 'ok', '2026-10-01 10:00:00+00', 'ok',
         ARRAY['B0TESTA001', 'B0TESTA002', 'B0TESTA003'], ARRAY[1, 2, 3]),
        ('bestseller_list', '10000000091', 'paid', 1, NULL, 'ok', '2026-10-02 10:00:00+00', 'ok',
         ARRAY['B0TESTA002', 'B0TESTA001', 'B0TESTP002'], ARRAY[1, 2, 3]),
        ('bestseller_list', '10000000091', 'paid', 1, NULL, 'ok', '2026-10-03 10:00:00+00', 'parse_failed',
         NULL, NULL),
        ('bestseller_list', '10000000091', 'paid', 2, NULL, 'ok', '2026-10-01 10:05:00+00', 'ok',
         ARRAY['B0TESTP001', 'B0TESTP002'], ARRAY[51, 52]),
        ('bestseller_list', '10000000091', 'free', 1, NULL, 'ok', '2026-10-01 10:10:00+00', 'ok',
         ARRAY['B0TESTF901'], ARRAY[1]),
        ('bestseller_list', '10000000092', 'paid', 1, NULL, 'ok', '2026-10-02 11:00:00+00', 'ok',
         ARRAY['B0TESTB001'], ARRAY[1]),
        ('product', NULL, NULL, NULL, 'B0TESTK001', 'ok', '2026-10-01 12:00:00+00', 'ok', NULL, NULL),
        ('product', NULL, NULL, NULL, 'B0TESTK001', 'ok', '2026-10-02 12:00:00+00', 'ok', NULL, NULL),
        ('product', NULL, NULL, NULL, 'B0TESTS001', 'ok', '2026-10-02 12:05:00+00', 'skipped', NULL, NULL),
        ('product', NULL, NULL, NULL, 'B0TESTE001', 'ok', '2026-10-02 12:10:00+00', 'parse_failed', NULL, NULL),
        ('product', NULL, NULL, NULL, 'B0TESTI001', 'invalid', '2026-10-02 12:15:00+00', NULL, NULL, NULL)
    ) AS v(page_type, node, list_kind, page, asin, fstatus, seen, extraction, asins, ranks)
    LOOP
        n := n + 1;
        INSERT INTO raw.raw_page (run_id, page_type, category_node, list_type, page_number, asin, requested_url,
                                  fetch_status, error_message, content_sha256, content_bytes, storage_path,
                                  capture_method, metadata_path, metadata_sha256, fetched_at)
        VALUES (run, p.page_type, p.node, p.list_kind, p.page, p.asin, 'https://test', p.fstatus,
                CASE WHEN p.fstatus = 'invalid' THEN 'test' END,
                encode(sha256(convert_to('test-guide-' || n, 'UTF8')), 'hex'), 1, 'test', 'extension-dom', 'test.json',
                encode(sha256(convert_to('test-guide-json-' || n, 'UTF8')), 'hex'), p.seen::timestamptz);
        IF p.extraction IS NOT NULL THEN
            INSERT INTO staging.page_extraction (raw_page_id, extract_run_id, status, error_message, entry_count)
            SELECT currval(pg_get_serial_sequence('raw.raw_page', 'id')), ext, p.extraction,
                   CASE WHEN p.extraction = 'ok' THEN NULL ELSE 'test' END,
                   CASE WHEN p.extraction = 'ok' THEN coalesce(cardinality(p.asins), 1) ELSE 0 END;
        END IF;
        IF p.asins IS NOT NULL THEN
            INSERT INTO staging.ranking_entry (raw_page_id, extract_run_id, rank, asin, has_card)
            SELECT currval(pg_get_serial_sequence('raw.raw_page', 'id')), ext, r, a, false
              FROM unnest(p.asins, p.ranks) AS u(a, r);
        END IF;
    END LOOP;
    RAISE NOTICE 'OK test 0 : propriétaire, migration 9 présente, % pages de test créées', n;
END;
$$;

-- Test 1 : les trois vues sont en security_invoker (elles lisent avec les droits de celui qui les interroge)
DO $$
DECLARE
    missing text;
BEGIN
    SELECT string_agg(v, ', ') INTO missing
      FROM unnest(ARRAY['guide.reference_entry', 'guide.kindle_product', 'guide.export_document']) AS v
     WHERE NOT EXISTS (SELECT 1 FROM pg_class c
                        WHERE c.oid = v::regclass AND c.relkind = 'v'
                          AND 'security_invoker=true' = ANY (coalesce(c.reloptions, '{}')));
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : vues sans security_invoker : %', missing;
    END IF;
    RAISE NOTICE 'OK test 1 : les trois vues du schéma guide sont en security_invoker';
END;
$$;

-- ============================================================================================================
-- books_reader
-- ============================================================================================================
SET LOCAL ROLE books_reader;

DO $$
DECLARE
    got text;
    doc json;
    lists json;
    list_a json;
BEGIN
    IF current_user <> 'books_reader' THEN
        RAISE EXCEPTION 'ÉCHEC test 2 : rôle courant %, books_reader attendu', current_user;
    END IF;

    -- Test 2 : référence de la liste A payante (dernière page 1 extraite ok, page 2, ASIN commun, échec ignoré)
    SELECT string_agg(format('%s %s %s', asin, rank, to_char(observed_at AT TIME ZONE 'UTC', 'MM-DD HH24:MI')),
                      ' ; ' ORDER BY rank) INTO got
      FROM guide.reference_entry WHERE category_node = '10000000091' AND list_type = 'paid';
    IF got IS DISTINCT FROM
       'B0TESTA002 1 10-02 10:00 ; B0TESTA001 2 10-02 10:00 ; B0TESTP002 3 10-02 10:00 ; B0TESTP001 51 10-01 10:05' THEN
        RAISE EXCEPTION 'ÉCHEC test 2 : référence de la liste A payante : %', got;
    END IF;
    RAISE NOTICE 'OK test 2 : dernière page 1 extraite ok, page 2 plus ancienne, ASIN commun gardé une fois (ligne la plus récente), page en échec ignorée';

    -- Test 3 : listes séparées (payant et gratuit ; autre catégorie)
    SELECT string_agg(format('%s %s %s %s', category_node, list_type, asin, rank), ' ; '
                      ORDER BY category_node, list_type, rank) INTO got
      FROM guide.reference_entry WHERE category_node IN ('10000000091', '10000000092') AND rank = 1;
    IF got IS DISTINCT FROM
       '10000000091 free B0TESTF901 1 ; 10000000091 paid B0TESTA002 1 ; 10000000092 paid B0TESTB001 1' THEN
        RAISE EXCEPTION 'ÉCHEC test 3 : listes séparées : %', got;
    END IF;
    RAISE NOTICE 'OK test 3 : listes payante et gratuite, et catégories, séparées';

    -- Test 4 : fiches Kindle en base (papier, échec et refusée exclues ; dernière date)
    SELECT string_agg(format('%s %s', asin, to_char(last_observed_at AT TIME ZONE 'UTC', 'MM-DD HH24:MI')), ' ; '
                      ORDER BY asin) INTO got
      FROM guide.kindle_product WHERE asin LIKE 'B0TEST%';
    IF got IS DISTINCT FROM 'B0TESTK001 10-02 12:00' THEN
        RAISE EXCEPTION 'ÉCHEC test 4 : fiches Kindle en base : %', got;
    END IF;
    RAISE NOTICE 'OK test 4 : seule la fiche Kindle extraite est retenue (papier, échec et refusée exclues), à sa dernière date';

    -- Test 5 : document exporté (format version 1, décision 017, section 4)
    SELECT document INTO doc FROM guide.export_document;
    IF (SELECT count(*) FROM guide.export_document) <> 1 THEN
        RAISE EXCEPTION 'ÉCHEC test 5 : guide.export_document doit rendre une seule ligne';
    END IF;
    IF (SELECT array_agg(k) FROM json_object_keys(doc) AS k)
       IS DISTINCT FROM ARRAY['schema_version', 'generated_at', 'lists', 'kindle_asins'] THEN
        RAISE EXCEPTION 'ÉCHEC test 5 : clés du document : %', (SELECT array_agg(k) FROM json_object_keys(doc) AS k);
    END IF;
    IF doc->>'schema_version' <> '1' OR json_typeof(doc->'schema_version') <> 'number'
       OR doc->>'generated_at' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' THEN
        RAISE EXCEPTION 'ÉCHEC test 5 : version ou date du document : % / %', doc->'schema_version', doc->'generated_at';
    END IF;
    lists := doc->'lists';
    -- Listes triées par catégorie puis type, une seule par couple, chacune avec exactement trois clés
    IF EXISTS (SELECT 1 FROM (
                 SELECT l->>'category_node' || ' ' || (l->>'list_type') AS k, i,
                        lag(l->>'category_node' || ' ' || (l->>'list_type')) OVER (ORDER BY i) AS prev
                   FROM json_array_elements(lists) WITH ORDINALITY AS t(l, i)) s
                WHERE prev IS NOT NULL AND prev COLLATE "C" >= k COLLATE "C")
       OR EXISTS (SELECT 1 FROM json_array_elements(lists) AS l
                   WHERE (SELECT array_agg(k) FROM json_object_keys(l) AS k)
                         IS DISTINCT FROM ARRAY['category_node', 'list_type', 'entries']) THEN
        RAISE EXCEPTION 'ÉCHEC test 5 : listes mal triées, en double, ou de clés inattendues';
    END IF;
    SELECT l INTO list_a FROM json_array_elements(lists) AS l
     WHERE l->>'category_node' = '10000000091' AND l->>'list_type' = 'paid';
    IF (list_a->'entries')::text IS DISTINCT FROM
       '[{"asin" : "B0TESTA002", "rank" : 1, "observed_at" : "2026-10-02T10:00:00Z"}, '
       '{"asin" : "B0TESTA001", "rank" : 2, "observed_at" : "2026-10-02T10:00:00Z"}, '
       '{"asin" : "B0TESTP002", "rank" : 3, "observed_at" : "2026-10-02T10:00:00Z"}, '
       '{"asin" : "B0TESTP001", "rank" : 51, "observed_at" : "2026-10-01T10:05:00Z"}]' THEN
        RAISE EXCEPTION 'ÉCHEC test 5 : entrées de la liste A payante : %', list_a->'entries';
    END IF;
    -- kindle_asins : triés, uniques ; la fiche Kindle de test y est, les autres fiches de test non
    IF EXISTS (SELECT 1 FROM (
                 SELECT a, lag(a) OVER (ORDER BY i) AS prev
                   FROM json_array_elements_text(doc->'kindle_asins') WITH ORDINALITY AS t(a, i)) s
                WHERE prev IS NOT NULL AND prev COLLATE "C" >= a COLLATE "C") THEN
        RAISE EXCEPTION 'ÉCHEC test 5 : kindle_asins non triés ou en double';
    END IF;
    SELECT string_agg(a, ' ; ' ORDER BY a) INTO got
      FROM json_array_elements_text(doc->'kindle_asins') AS a WHERE a LIKE 'B0TEST%';
    IF got IS DISTINCT FROM 'B0TESTK001' THEN
        RAISE EXCEPTION 'ÉCHEC test 5 : fiches Kindle de test dans le document : %', got;
    END IF;
    RAISE NOTICE 'OK test 5 : document conforme (clés, version, date UTC, listes triées, entrées par rang, kindle_asins triés)';
END;
$$;

RESET ROLE;

-- Test 6 : les autres rôles n'ont aucun accès au schéma guide
SET LOCAL ROLE books_collector;
DO $$
DECLARE
    v text;
BEGIN
    FOREACH v IN ARRAY ARRAY['guide.reference_entry', 'guide.kindle_product', 'guide.export_document'] LOOP
        PERFORM pg_temp.expect_refusal(6, 'lecture de ' || v || ' par books_collector',
            format('SELECT count(*) FROM %s', v), '42501', NULL);
    END LOOP;
END;
$$;
RESET ROLE;

SET LOCAL ROLE books_transformer;
DO $$
DECLARE
    v text;
BEGIN
    FOREACH v IN ARRAY ARRAY['guide.reference_entry', 'guide.kindle_product', 'guide.export_document'] LOOP
        PERFORM pg_temp.expect_refusal(6, 'lecture de ' || v || ' par books_transformer',
            format('SELECT count(*) FROM %s', v), '42501', NULL);
    END LOOP;
END;
$$;
RESET ROLE;

-- Test 7 : droits du schéma guide : USAGE et SELECT pour books_reader seulement ; aucun droit de PUBLIC
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.role_table_grants
                WHERE table_schema = 'guide' AND (grantee <> 'books_reader' OR privilege_type <> 'SELECT')
                  AND grantee NOT IN (SELECT rolname FROM pg_roles WHERE rolsuper)) THEN
        RAISE EXCEPTION 'ÉCHEC test 7 : droit inattendu sur une vue du schéma guide : %',
            (SELECT string_agg(grantee || ' ' || privilege_type || ' ' || table_name, ', ')
               FROM information_schema.role_table_grants
              WHERE table_schema = 'guide' AND (grantee <> 'books_reader' OR privilege_type <> 'SELECT')
                AND grantee NOT IN (SELECT rolname FROM pg_roles WHERE rolsuper));
    END IF;
    IF has_schema_privilege('public', 'guide', 'USAGE') OR has_schema_privilege('books_collector', 'guide', 'USAGE')
       OR has_schema_privilege('books_transformer', 'guide', 'USAGE')
       OR NOT has_schema_privilege('books_reader', 'guide', 'USAGE')
       OR has_schema_privilege('books_reader', 'guide', 'CREATE') THEN
        RAISE EXCEPTION 'ÉCHEC test 7 : droits inattendus sur le schéma guide';
    END IF;
    RAISE NOTICE 'OK test 7 : schéma guide visible de books_reader seulement, en lecture seule';
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
