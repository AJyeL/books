-- Tests de la migration 014 : couche CORE, lot 1 : classements (décision 020), adaptés à la migration 015
-- (CORE_VERSION 2, jours par source dans core.book : décision 021)
--
-- À exécuter EN TANT QUE PROPRIÉTAIRE de la base, depuis le dossier du dépôt (bash), toutes les migrations appliquées :
--   docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_014_core_classements.sql
-- Le propriétaire prépare RAW et STAGING (catégories 900000000n, ASIN « B0T… », versions d'extracteur « test » et
-- « test-autre », toutes inventées), construit CORE avec la version « test » (seules les pages de test sont alors
-- éligibles), puis endosse books_transformer, books_reader et books_collector.
-- Tout se déroule dans une transaction annulée par ROLLBACK : CORE retrouve ensuite son contenu d'avant (vérifié).

-- Empreinte du contenu reconstructible de CORE (journal exclu), indépendante du fuseau de la session. Créée avant la
-- transaction : elle sert aussi au contrôle final, après le ROLLBACK.
CREATE FUNCTION pg_temp.core_fingerprint() RETURNS text LANGUAGE sql SET timezone = 'UTC' SET datestyle = 'ISO, YMD' AS $$
    SELECT md5(concat_ws('|',
        (SELECT string_agg(t::text, ';' ORDER BY t.asin) FROM core.book t),
        (SELECT string_agg(t::text, ';' ORDER BY t.source, t.category_node) FROM core.category t),
        (SELECT string_agg(t::text, ';' ORDER BY t.source, t.category_node, t.name_kind, t.first_raw_page_id)
           FROM core.category_name t),
        (SELECT string_agg(t::text, ';' ORDER BY t.source, t.category_node, t.list_type, t.day) FROM core.list_day t),
        (SELECT string_agg(t::text, ';' ORDER BY t.asin, t.source, t.category_node, t.list_type, t.day)
           FROM core.ranking_day t)))
$$;
SELECT set_config('test.core_avant', pg_temp.core_fingerprint(), false) AS empreinte_avant \gset
SELECT set_config('test.journal_avant', (SELECT count(*) FROM core.build_run)::text, false) AS journal_avant \gset

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

CREATE FUNCTION pg_temp.check(num text, label text, got text, expected text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF got IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'ÉCHEC test % : % : obtenu « % », attendu « % »', num, label, got, expected;
    END IF;
    RAISE NOTICE 'OK test % : %', num, label;
END;
$$;

DO $$
BEGIN
    IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : connecté en tant que %, le propriétaire (superutilisateur) est attendu', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.schema_migration WHERE version = 14) THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : migration 14 absente de schema_migration';
    END IF;
    RAISE NOTICE 'OK test 0 : propriétaire, migration 14 présente';
END;
$$;

-- ============================================================================================================
-- Préparation : pages de classement inventées
-- ============================================================================================================
INSERT INTO raw.collect_run (collector_version) VALUES ('test');
INSERT INTO staging.extract_run (extractor_version) VALUES ('test'), ('test-autre');
CREATE TEMP TABLE test_page (label text PRIMARY KEY, id bigint NOT NULL UNIQUE) ON COMMIT DROP;

-- ASIN inventés : « B0T » + préfixe de trois lettres + numéro sur quatre chiffres
CREATE FUNCTION pg_temp.asins(prefix text, first_n int, last_n int) RETURNS text[] LANGUAGE sql AS $$
    SELECT array_agg('B0T' || prefix || lpad(n::text, 4, '0') ORDER BY n) FROM generate_series(first_n, last_n) AS n
$$;

-- Une page de classement : RAW, puis (si extraction n'est pas NULL) STAGING. Rangs : (page - 1) × 50 + position.
CREATE FUNCTION pg_temp.page(label text, node text, list text, page_no int, at text, asins text[],
                             extraction text DEFAULT 'ok', version text DEFAULT 'test',
                             display_name text DEFAULT NULL, short_name text DEFAULT NULL,
                             fstatus text DEFAULT 'ok') RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    pid bigint;
    run bigint;
BEGIN
    INSERT INTO raw.raw_page (run_id, page_type, category_node, list_type, page_number, requested_url, fetch_status,
                              error_message, content_sha256, content_bytes, storage_path, capture_method,
                              metadata_path, metadata_sha256, fetched_at)
    VALUES ((SELECT max(id) FROM raw.collect_run WHERE collector_version = 'test'), 'bestseller_list', node, list,
            page_no, 'https://test', fstatus, CASE WHEN fstatus <> 'ok' THEN 'test' END,
            encode(sha256(convert_to('test-core-' || label, 'UTF8')), 'hex'), 1, 'test', 'extension-dom', 'test.json',
            encode(sha256(convert_to('test-core-json-' || label, 'UTF8')), 'hex'), at::timestamptz)
    RETURNING id INTO pid;
    INSERT INTO test_page VALUES (label, pid);
    IF extraction IS NULL THEN
        RETURN pid;
    END IF;
    SELECT max(id) INTO run FROM staging.extract_run WHERE extractor_version = version;
    INSERT INTO staging.page_extraction (raw_page_id, extract_run_id, status, error_message, entry_count)
    VALUES (pid, run, extraction, CASE WHEN extraction <> 'ok' THEN 'test' END,
            CASE WHEN extraction = 'ok' THEN cardinality(asins) ELSE 0 END);
    IF extraction = 'ok' THEN
        INSERT INTO staging.ranking_entry (raw_page_id, extract_run_id, rank, asin, has_card, price_amount, currency,
                                           rating, review_count, ku_sticker_hint)
        SELECT pid, run, (page_no - 1) * 50 + a.n, a.asin, true, 4.99, 'EUR', 4.5, 10 + a.n, a.n % 2 = 0
          FROM unnest(asins) WITH ORDINALITY AS a (asin, n);
        INSERT INTO staging.category_observation (raw_page_id, extract_run_id, display_name, short_name)
        VALUES (pid, run, display_name, short_name);
    END IF;
    RETURN pid;
END;
$$;

CREATE FUNCTION pg_temp.label(page_id bigint) RETURNS text LANGUAGE sql AS $$
    SELECT label FROM test_page WHERE id = page_id
$$;

DO $$
BEGIN
    -- N1, Top payant p1 (test 3) : trois captures ok le 15 décembre, puis une en échec d'analyse, une bloquée, une
    -- extraite par une autre version ; le lendemain, une capture
    PERFORM pg_temp.page('n1-08h', '9000000001', 'paid', 1, '2026-12-15T08:00:00Z', pg_temp.asins('AAA', 1, 3));
    PERFORM pg_temp.page('n1-12h', '9000000001', 'paid', 1, '2026-12-15T12:00:00Z', pg_temp.asins('AAB', 1, 3));
    PERFORM pg_temp.page('n1-18h', '9000000001', 'paid', 1, '2026-12-15T18:00:00Z', pg_temp.asins('AAC', 1, 3));
    PERFORM pg_temp.page('n1-19h-echec', '9000000001', 'paid', 1, '2026-12-15T19:00:00Z', '{}', 'parse_failed');
    PERFORM pg_temp.page('n1-20h-bloquee', '9000000001', 'paid', 1, '2026-12-15T20:00:00Z', '{}', NULL,
                         fstatus => 'blocked');
    PERFORM pg_temp.page('n1-21h-autre', '9000000001', 'paid', 1, '2026-12-15T21:00:00Z', pg_temp.asins('AAD', 1, 3),
                         version => 'test-autre');
    PERFORM pg_temp.page('n1-lendemain', '9000000001', 'paid', 1, '2026-12-16T09:00:00Z', pg_temp.asins('AAA', 1, 3));
    -- N2 : deux captures à la même seconde (la seconde déposée l'emporte)
    PERFORM pg_temp.page('n2-a', '9000000002', 'paid', 1, '2026-12-16T10:00:00Z', pg_temp.asins('ABA', 1, 2));
    PERFORM pg_temp.page('n2-b', '9000000002', 'paid', 1, '2026-12-16T10:00:00Z', pg_temp.asins('ABB', 1, 2));
    -- N3, Top gratuit p1 (test 2) : passages de minuit, hiver, été et jours de changement d'heure
    PERFORM pg_temp.page('n3-hiver-avant', '9000000003', 'free', 1, '2026-12-15T22:59:59Z', pg_temp.asins('ACA', 1, 1));
    PERFORM pg_temp.page('n3-hiver-apres', '9000000003', 'free', 1, '2026-12-15T23:00:00Z', pg_temp.asins('ACA', 1, 1));
    PERFORM pg_temp.page('n3-ete-avant', '9000000003', 'free', 1, '2026-07-15T21:59:59Z', pg_temp.asins('ACA', 1, 1));
    PERFORM pg_temp.page('n3-ete-apres', '9000000003', 'free', 1, '2026-07-15T22:00:00Z', pg_temp.asins('ACA', 1, 1));
    PERFORM pg_temp.page('n3-oct-1', '9000000003', 'free', 1, '2026-10-24T21:59:59Z', pg_temp.asins('ACA', 1, 1));
    PERFORM pg_temp.page('n3-oct-2', '9000000003', 'free', 1, '2026-10-24T22:00:00Z', pg_temp.asins('ACA', 1, 1));
    PERFORM pg_temp.page('n3-oct-3', '9000000003', 'free', 1, '2026-10-25T22:59:59Z', pg_temp.asins('ACA', 1, 1));
    PERFORM pg_temp.page('n3-oct-4', '9000000003', 'free', 1, '2026-10-25T23:00:00Z', pg_temp.asins('ACA', 1, 1));
    PERFORM pg_temp.page('n3-mars-1', '9000000003', 'free', 1, '2027-03-27T22:59:59Z', pg_temp.asins('ACA', 1, 1));
    PERFORM pg_temp.page('n3-mars-2', '9000000003', 'free', 1, '2027-03-27T23:00:00Z', pg_temp.asins('ACA', 1, 1));
    PERFORM pg_temp.page('n3-mars-3', '9000000003', 'free', 1, '2027-03-28T21:59:59Z', pg_temp.asins('ACA', 1, 1));
    PERFORM pg_temp.page('n3-mars-4', '9000000003', 'free', 1, '2027-03-28T22:00:00Z', pg_temp.asins('ACA', 1, 1));
    -- N4 (test 4) : p1 de 50 rangs, puis p2 une heure plus tard où le livre du rang 10 est passé au rang 100
    PERFORM pg_temp.page('n4-p1', '9000000004', 'paid', 1, '2026-12-17T09:00:00Z', pg_temp.asins('ADA', 1, 50));
    PERFORM pg_temp.page('n4-p2', '9000000004', 'paid', 2, '2026-12-17T10:00:00Z',
                         pg_temp.asins('ADA', 51, 99) || pg_temp.asins('ADA', 10, 10));
    -- N5 : Top gratuit p1 de 50 rangs sans p2 ; Top payant p2 sans p1 (deux listes du jour incomplètes)
    PERFORM pg_temp.page('n5-gratuit-p1', '9000000005', 'free', 1, '2026-12-17T09:00:00Z', pg_temp.asins('AEA', 1, 50));
    PERFORM pg_temp.page('n5-payant-p2', '9000000005', 'paid', 2, '2026-12-17T09:30:00Z', pg_temp.asins('AEB', 51, 53));
    -- N6 (test 5) : noms observés
    PERFORM pg_temp.page('n6-1', '9000000006', 'paid', 1, '2026-12-01T10:00:00Z', pg_temp.asins('AFA', 1, 1),
                         display_name => 'Nom A', short_name => 'A');
    PERFORM pg_temp.page('n6-2', '9000000006', 'paid', 1, '2026-12-02T10:00:00Z', pg_temp.asins('AFA', 1, 1),
                         display_name => 'Nom A');
    PERFORM pg_temp.page('n6-3', '9000000006', 'paid', 1, '2026-12-03T10:00:00Z', pg_temp.asins('AFA', 1, 1),
                         short_name => 'A');
    PERFORM pg_temp.page('n6-4', '9000000006', 'paid', 1, '2026-12-04T10:00:00Z', pg_temp.asins('AFA', 1, 1),
                         display_name => 'Nom B', short_name => 'A');
    PERFORM pg_temp.page('n6-5', '9000000006', 'paid', 1, '2026-12-05T08:00:00Z', pg_temp.asins('AFA', 1, 1),
                         display_name => 'Nom A', short_name => 'A');
    PERFORM pg_temp.page('n6-6', '9000000006', 'paid', 1, '2026-12-05T15:00:00Z', pg_temp.asins('AFA', 1, 1),
                         display_name => 'Nom C', short_name => 'A');
    -- N7 (test 6) : captures le 10 et le 12 décembre, aucune le 11 ; un livre sans carte détaillée le 10
    PERFORM pg_temp.page('n7-10', '9000000007', 'paid', 1, '2026-12-10T10:00:00Z', pg_temp.asins('AGA', 1, 2));
    PERFORM pg_temp.page('n7-12', '9000000007', 'paid', 1, '2026-12-12T10:00:00Z', pg_temp.asins('AGA', 1, 1));
    UPDATE staging.ranking_entry
       SET has_card = false, price_amount = NULL, currency = NULL, rating = NULL, review_count = NULL,
           ku_sticker_hint = NULL
     WHERE raw_page_id = (SELECT id FROM test_page WHERE label = 'n7-10') AND asin = 'B0TAGA0002';
END;
$$;

-- ============================================================================================================
-- Test 1 : construction et déterminisme
-- ============================================================================================================
SELECT pg_temp.expect_refusal(1, 'construction sans version d''extracteur', 'SELECT core.rebuild('''')', 'P0001', NULL);

DO $$
DECLARE
    r core.build_run;
    first_print text;
BEGIN
    SELECT * INTO r FROM core.rebuild('test');
    PERFORM pg_temp.check('1a', 'journal : version de CORE et de l''extracteur', r.core_version || ' / ' || r.extractor_version,
                          '2 / test');  -- CORE_VERSION 2 depuis la migration 015 (décision 021)
    first_print := pg_temp.core_fingerprint();
    PERFORM core.rebuild('test');
    PERFORM pg_temp.check('1c', 'deux constructions successives : même contenu', pg_temp.core_fingerprint(), first_print);
    -- Autre ordre physique des lignes de STAGING (même contenu) : même CORE
    CREATE TEMP TABLE saved_rows ON COMMIT DROP AS
        SELECT * FROM staging.ranking_entry WHERE raw_page_id = (SELECT id FROM test_page WHERE label = 'n4-p1');
    DELETE FROM staging.ranking_entry WHERE raw_page_id = (SELECT id FROM test_page WHERE label = 'n4-p1');
    INSERT INTO staging.ranking_entry SELECT * FROM saved_rows ORDER BY rank DESC;
    PERFORM core.rebuild('test');
    PERFORM pg_temp.check('1d', 'lignes de STAGING réécrites dans un autre ordre : même contenu',
                          pg_temp.core_fingerprint(), first_print);
END;
$$;

-- ============================================================================================================
-- Test 2 : jour de Paris au passage de minuit, indépendant du fuseau de la session
-- ============================================================================================================
DO $$
DECLARE
    expected CONSTANT text :=
        '2026-07-15=n3-ete-avant(1), 2026-07-16=n3-ete-apres(1), 2026-10-24=n3-oct-1(1), 2026-10-25=n3-oct-3(2), '
        '2026-10-26=n3-oct-4(1), 2026-12-15=n3-hiver-avant(1), 2026-12-16=n3-hiver-apres(1), '
        '2027-03-27=n3-mars-1(1), 2027-03-28=n3-mars-3(2), 2027-03-29=n3-mars-4(1)';
    reference text;
    zone text;
BEGIN
    reference := pg_temp.core_fingerprint();
    FOREACH zone IN ARRAY ARRAY['UTC', 'America/New_York', 'Asia/Tokyo'] LOOP
        PERFORM set_config('TimeZone', zone, true);
        PERFORM core.rebuild('test');
        PERFORM pg_temp.check('2a', 'jours de Paris (hiver, été, 25 et 23 heures), session en ' || zone,
            (SELECT string_agg(to_char(ld.day, 'YYYY-MM-DD') || '=' || pg_temp.label(ld.p1_raw_page_id)
                               || '(' || ld.p1_observations || ')', ', ' ORDER BY ld.day)
               FROM core.list_day ld WHERE ld.category_node = '9000000003'),
            expected);
        PERFORM pg_temp.check('2b', 'contenu identique, session en ' || zone, pg_temp.core_fingerprint(), reference);
    END LOOP;
    PERFORM set_config('TimeZone', 'UTC', true);
END;
$$;

-- ============================================================================================================
-- Test 3 : plusieurs observations par jour
-- ============================================================================================================
DO $$
BEGIN
    PERFORM pg_temp.check('3a', 'dernière capture ok du jour retenue ; échec, page bloquée et autre version ignorés',
        (SELECT string_agg(to_char(ld.day, 'YYYY-MM-DD') || '=' || pg_temp.label(ld.p1_raw_page_id)
                           || '(' || ld.p1_observations || ')', ', ' ORDER BY ld.day)
           FROM core.list_day ld WHERE ld.category_node = '9000000001'),
        '2026-12-15=n1-18h(3), 2026-12-16=n1-lendemain(1)');
    PERFORM pg_temp.check('3b', 'lignes du 15 décembre : celles de la capture retenue, 3 observations',
        (SELECT string_agg(rd.asin || '#' || rd.rank || '@' || pg_temp.label(rd.raw_page_id) || '×' || rd.day_observations,
                           ', ' ORDER BY rd.rank)
           FROM core.ranking_day rd WHERE rd.category_node = '9000000001' AND rd.day = '2026-12-15'),
        'B0TAAC0001#1@n1-18h×3, B0TAAC0002#2@n1-18h×3, B0TAAC0003#3@n1-18h×3');
    PERFORM pg_temp.check('3c', 'même seconde : la page déposée en dernier (id le plus grand)',
        (SELECT pg_temp.label(ld.p1_raw_page_id) || '(' || ld.p1_observations || ')'
           FROM core.list_day ld WHERE ld.category_node = '9000000002'),
        'n2-b(2)');
    PERFORM pg_temp.check('3d', 'livre vu seulement dans une capture non retenue : pas de ligne ce jour-là',
        (SELECT first_ranking_day || '..' || last_ranking_day FROM core.book WHERE asin = 'B0TAAA0001'),
        '2026-12-16..2026-12-16');
    PERFORM pg_temp.check('3e', 'horodatage de la capture retenue conservé (UTC)',
        (SELECT to_char(rd.observed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
           FROM core.ranking_day rd WHERE rd.asin = 'B0TAAC0001'),
        '2026-12-15T18:00:00Z');
END;
$$;

-- ============================================================================================================
-- Test 4 : listes sur deux pages
-- ============================================================================================================
DO $$
BEGIN
    PERFORM pg_temp.check('4a', 'p1 et p2 : liste complète, deux heures et rangs de chaque page',
        (SELECT concat_ws(' ', pg_temp.label(p1_raw_page_id), to_char(p1_observed_at AT TIME ZONE 'UTC', 'HH24:MI'),
                          p1_ranks, pg_temp.label(p2_raw_page_id), to_char(p2_observed_at AT TIME ZONE 'UTC', 'HH24:MI'),
                          p2_ranks, complete::text)
           FROM core.list_day WHERE category_node = '9000000004'),
        'n4-p1 09:00 50 n4-p2 10:00 50 true');
    PERFORM pg_temp.check('4b', 'livre sur p1 et p2 : une ligne, celle de la capture la plus récente ; rang 10 libre',
        (SELECT count(*) || ' lignes ; ' || max(rd.rank) FILTER (WHERE rd.asin = 'B0TADA0010') || '@'
                || pg_temp.label(max(rd.raw_page_id) FILTER (WHERE rd.asin = 'B0TADA0010'))
                || ' ; rang 10 : ' || count(*) FILTER (WHERE rd.rank = 10)
           FROM core.ranking_day rd WHERE rd.category_node = '9000000004'),
        '99 lignes ; 100@n4-p2 ; rang 10 : 0');
    PERFORM pg_temp.check('4c', 'complétude : p1 courte complète ; p1 de 50 rangs sans p2 et p2 seule incomplètes',
        (SELECT string_agg(category_node || ' ' || list_type || ' ' || complete::text, ', ' ORDER BY category_node, list_type)
           FROM core.list_day
          WHERE (category_node = '9000000005') OR (category_node = '9000000001' AND day = '2026-12-15')),
        '9000000001 paid true, 9000000005 free false, 9000000005 paid false');
    PERFORM pg_temp.check('4d', 'p2 seule : aucune p1 retenue, ses rangs 51 à 53',
        (SELECT coalesce(p1_raw_page_id::text, 'aucune') || ' ' || p1_ranks || ' '
                || (SELECT string_agg(rank::text, ',' ORDER BY rank) FROM core.ranking_day
                     WHERE category_node = '9000000005' AND list_type = 'paid')
           FROM core.list_day WHERE category_node = '9000000005' AND list_type = 'paid'),
        'aucune 0 51,52,53');
END;
$$;

-- ============================================================================================================
-- Test 5 : versions du nom d'une catégorie
-- ============================================================================================================
DO $$
BEGIN
    PERFORM pg_temp.check('5a', 'noms d''affichage : A, B, A (nouvelle version), C le même jour ; NULL ignoré',
        (SELECT string_agg(name || ' ' || valid_from || '..' || valid_to || ' (' || observations || ') '
                           || pg_temp.label(first_raw_page_id) || '>' || pg_temp.label(last_raw_page_id),
                           ' | ' ORDER BY first_observed_at)
           FROM core.category_name WHERE category_node = '9000000006' AND name_kind = 'display'),
        'Nom A 2026-12-01..2026-12-02 (2) n6-1>n6-2 | Nom B 2026-12-04..2026-12-04 (1) n6-4>n6-4 | '
        'Nom A 2026-12-05..2026-12-05 (1) n6-5>n6-5 | Nom C 2026-12-05..2026-12-05 (1) n6-6>n6-6');
    PERFORM pg_temp.check('5b', 'nom court : une seule version, un NULL ne la coupe pas',
        (SELECT string_agg(name || ' ' || valid_from || '..' || valid_to || ' (' || observations || ')', ' | ')
           FROM core.category_name WHERE category_node = '9000000006' AND name_kind = 'short'),
        'A 2026-12-01..2026-12-05 (5)');
    PERFORM pg_temp.check('5c', 'catégorie sans nom lu : aucune version ; identité (source, nœud)',
        (SELECT count(*) FILTER (WHERE category_node = '9000000001') || ' ; '
                || (SELECT source || '/' || category_node FROM core.category WHERE category_node = '9000000006')
           FROM core.category_name),
        '0 ; amazon_fr/9000000006');
END;
$$;

-- ============================================================================================================
-- Test 6 : aucune observation, aucune ligne
-- ============================================================================================================
DO $$
BEGIN
    PERFORM pg_temp.check('6a', 'jour sans capture : aucune liste du jour',
        (SELECT string_agg(to_char(day, 'YYYY-MM-DD'), ',' ORDER BY day) FROM core.list_day WHERE category_node = '9000000007'),
        '2026-12-10,2026-12-12');
    PERFORM pg_temp.check('6b', 'aucune ligne le 11 ; livre absent le 12 : aucune ligne ce jour-là',
        (SELECT string_agg(asin || '@' || to_char(day, 'MM-DD'), ',' ORDER BY asin, day)
           FROM core.ranking_day WHERE category_node = '9000000007'),
        'B0TAGA0001@12-10,B0TAGA0001@12-12,B0TAGA0002@12-10');
    PERFORM pg_temp.check('6c', 'extraction d''une autre version seule (catégorie N1 mise à part) : rien dans CORE',
        (SELECT count(*)::text FROM core.ranking_day WHERE asin LIKE 'B0TAAD%'), '0');
END;
$$;

-- ============================================================================================================
-- Test 7 : atomicité ; pages d'une autre version exclues et comptées
-- ============================================================================================================
CREATE FUNCTION pg_temp.fail_insert() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.asin = 'B0TAGA0001' THEN
        RAISE EXCEPTION 'échec simulé';
    END IF;
    RETURN NEW;
END;
$$;

DO $$
DECLARE
    before_print text := pg_temp.core_fingerprint();
    before_runs bigint := (SELECT count(*) FROM core.build_run);
    before_other integer;
    failed boolean := false;
    r core.build_run;
BEGIN
    -- Une autre catégorie apparaît dans STAGING, puis la construction échoue en cours : rien ne change
    PERFORM pg_temp.page('n9-nouvelle', '9000000009', 'paid', 1, '2026-12-18T10:00:00Z', pg_temp.asins('AIA', 1, 1));
    CREATE TRIGGER test_fail BEFORE INSERT ON core.ranking_day FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_insert();
    BEGIN
        PERFORM core.rebuild('test');
    EXCEPTION WHEN OTHERS THEN
        failed := true;
    END;
    DROP TRIGGER test_fail ON core.ranking_day;
    PERFORM pg_temp.check('7a', 'construction en échec : erreur levée', failed::text, 'true');
    PERFORM pg_temp.check('7b', 'construction en échec : contenu précédent intact (nouvelle catégorie absente)',
                          pg_temp.core_fingerprint(), before_print);
    PERFORM pg_temp.check('7c', 'construction en échec : journal inchangé',
                          (SELECT count(*) FROM core.build_run)::text, before_runs::text);
    DELETE FROM staging.ranking_entry WHERE raw_page_id = (SELECT id FROM test_page WHERE label = 'n9-nouvelle');
    DELETE FROM staging.category_observation WHERE raw_page_id = (SELECT id FROM test_page WHERE label = 'n9-nouvelle');
    DELETE FROM staging.page_extraction WHERE raw_page_id = (SELECT id FROM test_page WHERE label = 'n9-nouvelle');

    -- Une page extraite par une autre version : exclue (contenu inchangé), comptée
    SELECT pages_other_version INTO before_other FROM core.rebuild('test');
    PERFORM pg_temp.page('n8-autre', '9000000008', 'paid', 1, '2026-12-18T10:00:00Z', pg_temp.asins('AHA', 1, 1),
                         version => 'test-autre');
    SELECT * INTO r FROM core.rebuild('test');
    PERFORM pg_temp.check('7d', 'page d''une autre version : comptée', (r.pages_other_version - before_other)::text, '1');
    PERFORM pg_temp.check('7e', 'page d''une autre version : exclue, contenu inchangé', pg_temp.core_fingerprint(),
                          before_print);
END;
$$;

-- ============================================================================================================
-- Test 8 : droits
-- ============================================================================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc p CROSS JOIN LATERAL aclexplode(p.proacl) a
                WHERE p.pronamespace = 'core'::regnamespace AND a.grantee = 0)
       OR EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'core'::regnamespace AND (proacl IS NULL OR prosecdef)) THEN
        RAISE EXCEPTION 'ÉCHEC test 8a : une fonction de core est ouverte à PUBLIC ou en SECURITY DEFINER';
    END IF;
    RAISE NOTICE 'OK test 8a : fonctions de core fermées à PUBLIC, SECURITY INVOKER';
END;
$$;

SET LOCAL ROLE books_transformer;
DO $$
DECLARE
    r core.build_run;
BEGIN
    SELECT * INTO r FROM core.rebuild('test');
    PERFORM pg_temp.check('8b', 'books_transformer construit CORE', r.ranking_rows::text, '178');
END;
$$;
SELECT pg_temp.expect_refusal(8, 'books_transformer : modifier le journal', 'UPDATE core.build_run SET core_version = ''x''', '42501', NULL);

RESET ROLE;
SET LOCAL ROLE books_reader;
DO $$
BEGIN
    PERFORM count(*) FROM core.build_run;
    PERFORM count(*) FROM core.book;
    PERFORM count(*) FROM core.category;
    PERFORM count(*) FROM core.category_name;
    PERFORM count(*) FROM core.list_day;
    PERFORM count(*) FROM core.ranking_day;
    RAISE NOTICE 'OK test 8c : books_reader lit les six tables de CORE';
END;
$$;
SELECT pg_temp.expect_refusal(8, 'books_reader : core.rebuild', 'SELECT core.rebuild(''test'')', '42501', NULL);
SELECT pg_temp.expect_refusal(8, 'books_reader : core.eligible_page', 'SELECT * FROM core.eligible_page(''test'')', '42501', NULL);
SELECT pg_temp.expect_refusal(8, 'books_reader : DELETE', 'DELETE FROM core.ranking_day', '42501', NULL);
SELECT pg_temp.expect_refusal(8, 'books_reader : INSERT', 'INSERT INTO core.category VALUES (''amazon_fr'', ''1'', ''2026-12-01'', ''2026-12-01'')', '42501', NULL);
SELECT pg_temp.expect_refusal(8, 'books_reader : TRUNCATE', 'TRUNCATE core.book CASCADE', '42501', NULL);

RESET ROLE;
SET LOCAL ROLE books_collector;
SELECT pg_temp.expect_refusal(8, 'books_collector : lecture', 'SELECT count(*) FROM core.ranking_day', '42501', NULL);
SELECT pg_temp.expect_refusal(8, 'books_collector : core.rebuild', 'SELECT core.rebuild(''test'')', '42501', NULL);
RESET ROLE;

-- ============================================================================================================
-- Test 9 : lignage et valeurs reprises de la ligne retenue
-- ============================================================================================================
DO $$
BEGIN
    PERFORM pg_temp.check('9a', 'chaque ligne retrouve sa ligne de STAGING (page, rang) avec les mêmes valeurs',
        (SELECT count(*) FILTER (WHERE re.raw_page_id IS NULL OR re.asin <> rd.asin
                                    OR re.has_card IS DISTINCT FROM rd.has_card
                                    OR re.price_amount IS DISTINCT FROM rd.price_amount
                                    OR re.currency IS DISTINCT FROM rd.currency
                                    OR re.rating IS DISTINCT FROM rd.rating
                                    OR re.review_count IS DISTINCT FROM rd.review_count
                                    OR re.ku_sticker_hint IS DISTINCT FROM rd.ku_sticker_hint) || ' écart(s) sur '
                || count(*)
           FROM core.ranking_day rd
           LEFT JOIN staging.ranking_entry re ON re.raw_page_id = rd.raw_page_id AND re.rank = rd.rank),
        '0 écart(s) sur 178');
    PERFORM pg_temp.check('9b', 'chaque ligne vient d''une page retenue de sa liste du jour',
        (SELECT count(*)::text FROM core.ranking_day rd
           JOIN core.list_day ld USING (source, category_node, list_type, day)
          WHERE rd.raw_page_id NOT IN (coalesce(ld.p1_raw_page_id, 0), coalesce(ld.p2_raw_page_id, 0))),
        '0');
    PERFORM pg_temp.check('9c', 'livre sans carte : valeurs inconnues (NULL)',
        (SELECT has_card::text || ' ' || coalesce(price_amount::text, 'NULL') || ' ' || coalesce(rating::text, 'NULL')
           FROM core.ranking_day WHERE asin = 'B0TAGA0002'),
        'false NULL NULL');
    PERFORM pg_temp.check('9d', 'livre avec carte : prix, devise, note, évaluations, indice',
        (SELECT concat_ws(' ', price_amount, currency, rating, review_count, ku_sticker_hint::text)
           FROM core.ranking_day WHERE asin = 'B0TAGA0001' AND day = '2026-12-10'),
        '4.99 EUR 4.5 11 false');
END;
$$;

-- ============================================================================================================
-- Test 10 : journal de la dernière construction (placé en dernier : les tests 2 à 9 désignent d'abord la règle
-- enfreinte ; la page d'une autre version du test 7 n'est comptée que dans pages_other_version)
-- ============================================================================================================
DO $$
DECLARE
    r core.build_run;
BEGIN
    SELECT * INTO r FROM core.build_run ORDER BY id DESC LIMIT 1;
    PERFORM pg_temp.check('10', 'journal : pages éligibles, retenues, listes du jour (incomplètes), lignes, livres, '
                                'catégories, versions de nom, doublons p1/p2',
                          concat_ws(' ', r.pages_eligible, r.pages_used, r.list_days, r.list_days_incomplete,
                                    r.ranking_rows, r.books, r.categories, r.category_name_versions,
                                    r.cross_page_duplicates),
                          '30 24 23 2 178 164 7 5 1');
END;
$$;

ROLLBACK;

-- Contrôle final : CORE et son journal retrouvent leur état d'avant le test ; aucune page de test n'est restée
DO $$
BEGIN
    IF pg_temp.core_fingerprint() IS DISTINCT FROM current_setting('test.core_avant')
       OR (SELECT count(*) FROM core.build_run)::text <> current_setting('test.journal_avant')
       OR EXISTS (SELECT 1 FROM raw.raw_page WHERE requested_url = 'https://test'
                     AND content_sha256 = encode(sha256(convert_to('test-core-n1-08h', 'UTF8')), 'hex')) THEN
        RAISE EXCEPTION 'ÉCHEC test final : CORE, son journal ou RAW diffèrent de l''état d''avant le test';
    END IF;
    RAISE NOTICE 'OK test final : CORE et journal inchangés, aucune page de test conservée';
END;
$$;
