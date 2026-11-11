-- Tests de la migration 015 : couche CORE, lot 2 : fiches produit (décision 021)
--
-- À exécuter EN TANT QUE PROPRIÉTAIRE de la base, depuis le dossier du dépôt (bash), toutes les migrations appliquées :
--   docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_015_core_fiches.sql
-- Même principe que test_014 : le propriétaire prépare RAW et STAGING (fiches Kindle inventées, ASIN « B0TFIA… »,
-- nœuds 910000000n, versions d'extracteur « test » et « test-autre »), construit CORE avec la version « test » (seules
-- les pages de test sont alors éligibles), puis endosse books_reader et books_collector.
-- Tout se déroule dans une transaction annulée par ROLLBACK : CORE retrouve ensuite son contenu d'avant (vérifié).

-- Empreinte de toutes les tables de CORE (journal exclu), indépendante du fuseau de la session ; créée avant la
-- transaction pour servir au contrôle final
CREATE FUNCTION pg_temp.core_fingerprint() RETURNS text LANGUAGE plpgsql
SET timezone = 'UTC' SET datestyle = 'ISO, YMD' AS $$
DECLARE
    tbl text;
    part text;
    acc text := '';
BEGIN
    FOR tbl IN SELECT c.relname FROM pg_class c
                WHERE c.relnamespace = 'core'::regnamespace AND c.relkind = 'r' AND c.relname <> 'build_run'
                ORDER BY 1 LOOP
        EXECUTE format('SELECT coalesce(string_agg(t::text, %L ORDER BY t::text), %L) FROM core.%I t', ';', '', tbl)
            INTO part;
        acc := acc || '|' || tbl || ':' || part;
    END LOOP;
    RETURN md5(acc);
END;
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
    IF NOT EXISTS (SELECT 1 FROM public.schema_migration WHERE version = 15) THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : migration 15 absente de schema_migration';
    END IF;
    RAISE NOTICE 'OK test 0 : propriétaire, migration 15 présente';
END;
$$;

-- ============================================================================================================
-- Préparation : fiches Kindle inventées et une page de Top
-- ============================================================================================================
INSERT INTO raw.collect_run (collector_version) VALUES ('test');
INSERT INTO staging.extract_run (extractor_version) VALUES ('test'), ('test-autre');
CREATE TEMP TABLE test_page (label text PRIMARY KEY, id bigint NOT NULL UNIQUE) ON COMMIT DROP;

CREATE FUNCTION pg_temp.raw_page(label text, page_type text, at text, asin text DEFAULT NULL, node text DEFAULT NULL,
                                 list text DEFAULT NULL, page_no int DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    pid bigint;
BEGIN
    INSERT INTO raw.raw_page (run_id, page_type, category_node, list_type, page_number, asin, requested_url,
                              fetch_status, content_sha256, content_bytes, storage_path, capture_method, metadata_path,
                              metadata_sha256, fetched_at)
    VALUES ((SELECT max(id) FROM raw.collect_run WHERE collector_version = 'test'), page_type, node, list, page_no,
            asin, 'https://test', 'ok', encode(sha256(convert_to('test-core2-' || label, 'UTF8')), 'hex'), 1, 'test',
            'extension-dom', 'test.json', encode(sha256(convert_to('test-core2-json-' || label, 'UTF8')), 'hex'),
            at::timestamptz)
    RETURNING id INTO pid;
    INSERT INTO test_page VALUES (label, pid);
    RETURN pid;
END;
$$;

-- Une fiche Kindle : RAW, page_extraction, puis (si ok) observation, onglets (le sélectionné et un broché lié),
-- rangs (« nœud:rang:boutique:liste ») et répartition des étoiles
CREATE FUNCTION pg_temp.fiche(label text, asin text, at text,
        title text DEFAULT 'Titre test', cover text DEFAULT NULL, description text DEFAULT NULL,
        markup text DEFAULT NULL, series_form text DEFAULT NULL, series_name text DEFAULT NULL,
        series_position int DEFAULT NULL, series_total int DEFAULT NULL, print_pages int DEFAULT NULL,
        has_aplus boolean DEFAULT NULL, publication_date date DEFAULT NULL, language text DEFAULT NULL,
        file_size numeric DEFAULT NULL, file_unit text DEFAULT NULL, rating numeric DEFAULT NULL,
        reviews int DEFAULT 0, price numeric DEFAULT 4.99, ku boolean DEFAULT false,
        general_rank int DEFAULT NULL, general_list text DEFAULT 'paid', category_ranks text[] DEFAULT '{}',
        extraction text DEFAULT 'ok', version text DEFAULT 'test', stars int[] DEFAULT ARRAY[5, 5, 10, 20, 60])
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    pid bigint;
    run bigint;
    r text[];
BEGIN
    pid := pg_temp.raw_page(label, 'product', at, asin);
    SELECT max(id) INTO run FROM staging.extract_run WHERE extractor_version = version;
    INSERT INTO staging.page_extraction (raw_page_id, extract_run_id, status, error_message, entry_count)
    VALUES (pid, run, extraction,
            CASE extraction WHEN 'ok' THEN NULL WHEN 'skipped' THEN 'format papier' ELSE 'test' END,
            CASE WHEN extraction = 'ok' THEN 1 ELSE 0 END);
    IF extraction <> 'ok' THEN
        RETURN pid;
    END IF;
    INSERT INTO staging.product_observation (raw_page_id, extract_run_id, format_label, title, series_form, series_name,
        series_position, series_total, publication_date, language, print_pages, file_size_value, file_size_unit,
        rating, review_count, cover_url, description_text, description_text_sha256, description_markup,
        description_markup_sha256, has_aplus)
    VALUES (pid, run, 'Format Kindle', title, series_form, series_name, series_position, series_total,
            publication_date, language, print_pages, file_size, file_unit, rating, reviews, cover, description,
            encode(sha256(convert_to(description, 'UTF8')), 'hex'), markup,
            encode(sha256(convert_to(markup, 'UTF8')), 'hex'), has_aplus);
    INSERT INTO staging.product_format (raw_page_id, extract_run_id, position, swatch_kind, label, is_selected,
                                        linked_asin, price_amount, currency, price_qualifier, ku_borrow)
    VALUES (pid, run, 1, 'KINDLE', 'Format Kindle', true, NULL, price, 'EUR', 'exact', ku),
           (pid, run, 2, 'PAPERBACK', 'Broché', false, 'B0TPAPIER1', 12.00, 'EUR', 'exact', false);
    IF general_rank IS NOT NULL THEN
        INSERT INTO staging.product_sales_rank (raw_page_id, extract_run_id, position, is_general, rank, store,
                                                category_node, list_type)
        VALUES (pid, run, 1, true, general_rank, 'digital-text', NULL, general_list);
    END IF;
    FOR i IN 1 .. coalesce(cardinality(category_ranks), 0) LOOP
        r := string_to_array(category_ranks[i], ':');
        INSERT INTO staging.product_sales_rank (raw_page_id, extract_run_id, position, is_general, rank, store,
                                                category_node, list_type)
        VALUES (pid, run, i + 1, false, r[2]::int, r[3], r[1], r[4]);
    END LOOP;
    INSERT INTO staging.product_rating_share (raw_page_id, extract_run_id, stars, percent)
    SELECT pid, run, s.n, s.percent FROM unnest(stars) WITH ORDINALITY AS s (percent, n);
    RETURN pid;
END;
$$;

CREATE FUNCTION pg_temp.label(page_id bigint) RETURNS text LANGUAGE sql AS $$
    SELECT label FROM test_page WHERE id = page_id
$$;

DO $$
DECLARE
    pid bigint;
    run bigint := (SELECT max(id) FROM staging.extract_run WHERE extractor_version = 'test');
BEGIN
    -- F1 (tests 2, 3, 7, 9, 10) : trois fiches les 1er, 2 et 3 décembre
    PERFORM pg_temp.fiche('f1-1', 'B0TFIA0001', '2026-12-01T10:00:00Z', title => 'Titre A',
        cover => 'https://test/c1.jpg', description => 'Texte un', markup => '<p>Texte un</p>',
        series_form => 'livre_n_sur_n', series_name => 'Série test', series_position => 2, series_total => 3,
        print_pages => 300, has_aplus => true, publication_date => '2026-01-01', language => 'Français',
        file_size => 1.2, file_unit => 'MB', rating => 4.5, reviews => 10, price => 4.99, general_rank => 1000,
        category_ranks => ARRAY['9100000001:5:digital-text:paid', '9100000002:7:books:paid']);
    PERFORM pg_temp.fiche('f1-2', 'B0TFIA0001', '2026-12-02T10:00:00Z', title => 'Titre B',
        description => 'Texte un', markup => '<p><b>Texte</b> un</p>', print_pages => 300,
        publication_date => '2026-01-01', language => 'Français', file_size => 1.2, file_unit => 'MB',
        rating => 4.5, reviews => 12, price => 4.99, category_ranks => ARRAY['9100000001:6:digital-text:paid']);
    PERFORM pg_temp.fiche('f1-3', 'B0TFIA0001', '2026-12-03T10:00:00Z', title => 'Titre A',
        cover => 'https://test/c1.jpg', description => 'Texte deux', markup => '<p>Texte deux</p>',
        series_form => 'livre_n_sur_n', series_name => 'Série test', series_position => 2, series_total => 4,
        print_pages => 300, has_aplus => false, publication_date => '2026-01-01', language => 'Français',
        file_size => 1.2, file_unit => 'MB', rating => 4.4, reviews => 15, price => 3.99, general_rank => 900,
        category_ranks => ARRAY['9100000001:4:digital-text:paid']);
    -- F2 (tests 4 et 5) : passages de minuit, deux fiches le même jour, deux à la même seconde
    PERFORM pg_temp.fiche('f2-e', 'B0TFIA0002', '2026-07-15T21:59:59Z', title => 'Titre Y');
    PERFORM pg_temp.fiche('f2-f', 'B0TFIA0002', '2026-07-15T22:00:00Z', title => 'Titre Y');
    PERFORM pg_temp.fiche('f2-a', 'B0TFIA0002', '2026-12-05T08:00:00Z', title => 'Titre X', price => 3.99);
    PERFORM pg_temp.fiche('f2-b', 'B0TFIA0002', '2026-12-05T15:00:00Z', title => 'Titre Y', price => 2.99);
    PERFORM pg_temp.fiche('f2-c', 'B0TFIA0002', '2026-12-15T22:59:59Z', title => 'Titre Y');
    PERFORM pg_temp.fiche('f2-d', 'B0TFIA0002', '2026-12-15T23:00:00Z', title => 'Titre Y');
    PERFORM pg_temp.fiche('f2-g', 'B0TFIA0002', '2026-12-20T10:00:00Z', title => 'Titre Y', price => 1.00);
    PERFORM pg_temp.fiche('f2-h', 'B0TFIA0002', '2026-12-20T10:00:00Z', title => 'Titre Y', price => 2.00);
    -- F3 (tests 6 et 8) : connu seulement par une fiche ; description sentinelle ; catégorie vue seulement ici
    PERFORM pg_temp.fiche('f3', 'B0TFIA0003', '2026-12-10T10:00:00Z', title => 'Titre Z',
        description => 'SENTINELLE-DESCRIPTION-021 texte', markup => '<p>SENTINELLE-DESCRIPTION-021 texte</p>',
        category_ranks => ARRAY['9100000003:2:digital-text:free']);
    -- F8 (test 2) : seul le total de la série change, puis revient (2 sur 3, 2 sur 4, 2 sur 3)
    PERFORM pg_temp.fiche('f8-1', 'B0TFIA0008', '2026-12-06T10:00:00Z', series_form => 'livre_n_sur_n',
        series_name => 'Série huit', series_position => 2, series_total => 3);
    PERFORM pg_temp.fiche('f8-2', 'B0TFIA0008', '2026-12-07T10:00:00Z', series_form => 'livre_n_sur_n',
        series_name => 'Série huit', series_position => 2, series_total => 4);
    PERFORM pg_temp.fiche('f8-3', 'B0TFIA0008', '2026-12-08T10:00:00Z', series_form => 'livre_n_sur_n',
        series_name => 'Série huit', series_position => 2, series_total => 3);
    -- Exclusions (test 7) : fiche en échec, fiche papier mise à part, fiche d'une autre version
    PERFORM pg_temp.fiche('f4-echec', 'B0TFIA0004', '2026-12-04T10:00:00Z', extraction => 'parse_failed');
    PERFORM pg_temp.fiche('f5-papier', 'B0TFIA0005', '2026-12-04T10:00:00Z', extraction => 'skipped');
    PERFORM pg_temp.fiche('f6-autre', 'B0TFIA0006', '2026-12-04T10:00:00Z', version => 'test-autre');
    -- Une page de Top (lot 1) où figure F1, et un livre connu seulement par les Tops
    pid := pg_temp.raw_page('top', 'bestseller_list', '2026-12-02T09:00:00Z', node => '9100000001', list => 'paid',
                            page_no => 1);
    INSERT INTO staging.page_extraction (raw_page_id, extract_run_id, status, entry_count) VALUES (pid, run, 'ok', 2);
    INSERT INTO staging.ranking_entry (raw_page_id, extract_run_id, rank, asin, has_card)
    VALUES (pid, run, 1, 'B0TFIA0001', false), (pid, run, 2, 'B0TTOP0001', false);
    INSERT INTO staging.category_observation (raw_page_id, extract_run_id) VALUES (pid, run);
END;
$$;

-- ============================================================================================================
-- Test 1 : déterminisme
-- ============================================================================================================
DO $$
DECLARE
    first_print text;
BEGIN
    PERFORM core.rebuild('test');
    first_print := pg_temp.core_fingerprint();
    PERFORM core.rebuild('test');
    PERFORM pg_temp.check('1a', 'deux constructions successives : même contenu', pg_temp.core_fingerprint(), first_print);
    CREATE TEMP TABLE saved_ranks ON COMMIT DROP AS
        SELECT * FROM staging.product_sales_rank WHERE raw_page_id = (SELECT id FROM test_page WHERE label = 'f1-1');
    DELETE FROM staging.product_sales_rank WHERE raw_page_id = (SELECT id FROM test_page WHERE label = 'f1-1');
    INSERT INTO staging.product_sales_rank SELECT * FROM saved_ranks ORDER BY position DESC;
    PERFORM core.rebuild('test');
    PERFORM pg_temp.check('1b', 'lignes de STAGING réécrites dans un autre ordre : même contenu',
                          pg_temp.core_fingerprint(), first_print);
END;
$$;

-- ============================================================================================================
-- Test 2 : NULL n'est pas un changement
-- ============================================================================================================
DO $$
BEGIN
    PERFORM pg_temp.check('2a', 'couverture X, NULL, X : une version, 2 observations',
        (SELECT string_agg(cover_url || ' ' || valid_from || '..' || valid_to || ' (' || observations || ')', ' | ')
           FROM core.book_cover_version WHERE asin = 'B0TFIA0001'),
        'https://test/c1.jpg 2026-12-01..2026-12-03 (2)');
    PERFORM pg_temp.check('2b', 'série « 2 sur 3 », NULL, « 2 sur 4 » : deux versions (le total compte)',
        (SELECT string_agg(series_name || ' ' || series_form || ' ' || series_position || '/' || series_total || ' '
                           || valid_from || '..' || valid_to || ' (' || observations || ')', ' | '
                           ORDER BY first_observed_at)
           FROM core.book_series_version WHERE asin = 'B0TFIA0001'),
        'Série test livre_n_sur_n 2/3 2026-12-01..2026-12-01 (1) | Série test livre_n_sur_n 2/4 2026-12-03..2026-12-03 (1)');
    PERFORM pg_temp.check('2b2', 'série : seul le total change puis revient, trois versions (chaque champ compte)',
        (SELECT string_agg(series_position || '/' || series_total || ' ' || valid_from || '..' || valid_to, ' | '
                           ORDER BY first_observed_at)
           FROM core.book_series_version WHERE asin = 'B0TFIA0008'),
        '2/3 2026-12-06..2026-12-06 | 2/4 2026-12-07..2026-12-07 | 2/3 2026-12-08..2026-12-08');
    PERFORM pg_temp.check('2c', 'A+ : NULL ignoré, faux compté comme une valeur',
        (SELECT string_agg(has_aplus::text || ' ' || valid_from || '..' || valid_to, ' | ' ORDER BY first_observed_at)
           FROM core.book_aplus_version WHERE asin = 'B0TFIA0001'),
        'true 2026-12-01..2026-12-01 | false 2026-12-03..2026-12-03');
    PERFORM pg_temp.check('2d', 'valeur constante : une version, 3 observations',
        (SELECT print_pages || ' (' || observations || ')' FROM core.book_print_pages_version WHERE asin = 'B0TFIA0001'),
        '300 (3)');
    PERFORM pg_temp.check('2e', 'description : réécriture seule détectée par le texte ; mise en forme par le balisage',
        (SELECT string_agg(description_length || ' ' || valid_from || '..' || valid_to || ' (' || observations || ')',
                           ' | ' ORDER BY first_observed_at)
           FROM core.book_description_version WHERE asin = 'B0TFIA0001')
        || ' // ' ||
        (SELECT string_agg(description_markup_length::text, ' | ' ORDER BY first_observed_at)
           FROM core.book_description_markup_version WHERE asin = 'B0TFIA0001'),
        '8 2026-12-01..2026-12-02 (2) | 10 2026-12-03..2026-12-03 (1) // 15 | 22 | 17');
END;
$$;

-- ============================================================================================================
-- Test 3 : retour à une ancienne valeur
-- ============================================================================================================
DO $$
BEGIN
    PERFORM pg_temp.check('3', 'titre A, B, A : trois versions',
        (SELECT string_agg(title || ' ' || valid_from || '..' || valid_to || ' (' || observations || ') '
                           || pg_temp.label(first_raw_page_id) || '>' || pg_temp.label(last_raw_page_id),
                           ' | ' ORDER BY first_observed_at)
           FROM core.book_title_version WHERE asin = 'B0TFIA0001'),
        'Titre A 2026-12-01..2026-12-01 (1) f1-1>f1-1 | Titre B 2026-12-02..2026-12-02 (1) f1-2>f1-2 | '
        'Titre A 2026-12-03..2026-12-03 (1) f1-3>f1-3');
END;
$$;

-- ============================================================================================================
-- Tests 4 et 5 : deux observations le même jour ; minuit de Paris, indépendant du fuseau de la session
-- ============================================================================================================
DO $$
DECLARE
    expected CONSTANT text := '2026-07-15=f2-e(1) 4.99, 2026-07-16=f2-f(1) 4.99, 2026-12-05=f2-b(2) 2.99, '
                              '2026-12-15=f2-c(1) 4.99, 2026-12-16=f2-d(1) 4.99, 2026-12-20=f2-h(2) 2.00';
    reference text;
    zone text;
BEGIN
    PERFORM pg_temp.check('4a', 'attributs : changement en cours de journée, deux versions le même jour',
        (SELECT string_agg(title || ' ' || valid_from || '..' || valid_to || ' (' || observations || ')', ' | '
                           ORDER BY first_observed_at)
           FROM core.book_title_version WHERE asin = 'B0TFIA0002'),
        'Titre Y 2026-07-15..2026-07-16 (2) | Titre X 2026-12-05..2026-12-05 (1) | Titre Y 2026-12-05..2026-12-20 (5)');
    reference := pg_temp.core_fingerprint();
    FOREACH zone IN ARRAY ARRAY['UTC', 'America/New_York', 'Asia/Tokyo'] LOOP
        PERFORM set_config('TimeZone', zone, true);
        PERFORM core.rebuild('test');
        PERFORM pg_temp.check('4b/5', 'mesures : dernière fiche du jour, compte, même seconde, jours de Paris ; session en '
                                       || zone,
            (SELECT string_agg(to_char(day, 'YYYY-MM-DD') || '=' || pg_temp.label(raw_page_id) || '('
                               || day_observations || ') ' || price_amount, ', ' ORDER BY day)
               FROM core.product_day WHERE asin = 'B0TFIA0002'),
            expected);
        PERFORM pg_temp.check('5', 'contenu identique, session en ' || zone, pg_temp.core_fingerprint(), reference);
    END LOOP;
    PERFORM set_config('TimeZone', 'UTC', true);
END;
$$;

-- ============================================================================================================
-- Test 6 : livre connu seulement par une fiche ; catégorie vue seulement dans les rangs d'une fiche
-- ============================================================================================================
DO $$
BEGIN
    PERFORM pg_temp.check('6a', 'livres : jours de Top et jours de fiche, par source',
        (SELECT string_agg(asin || ' ' || coalesce(first_ranking_day || '..' || last_ranking_day, '-') || ' '
                           || coalesce(first_product_day || '..' || last_product_day, '-'), ' | ' ORDER BY asin)
           FROM core.book WHERE asin LIKE 'B0T%'),
        'B0TFIA0001 2026-12-02..2026-12-02 2026-12-01..2026-12-03 | B0TFIA0002 - 2026-07-15..2026-12-20 | '
        'B0TFIA0003 - 2026-12-10..2026-12-10 | B0TFIA0008 - 2026-12-06..2026-12-08 | '
        'B0TTOP0001 2026-12-02..2026-12-02 -');
    PERFORM pg_temp.check('6b', 'catégories : jours de liste et jours de rang de fiche ; (source, nœud)',
        (SELECT string_agg(source || '/' || category_node || ' ' || coalesce(first_list_day || '..' || last_list_day, '-')
                           || ' ' || coalesce(first_product_rank_day || '..' || last_product_rank_day, '-'), ' | '
                           ORDER BY category_node)
           FROM core.category),
        'amazon_fr/9100000001 2026-12-02..2026-12-02 2026-12-01..2026-12-03 | amazon_fr/9100000002 - '
        '2026-12-01..2026-12-01 | amazon_fr/9100000003 - 2026-12-10..2026-12-10');
    PERFORM pg_temp.check('6c', 'catégorie vue seulement dans une fiche : aucun nom ; rangs par catégorie repris',
        (SELECT count(*) FROM core.category_name WHERE category_node IN ('9100000002', '9100000003')) || ' ; '
        || (SELECT string_agg(category_node || '#' || rank || ' ' || store || ' ' || list_type, ', '
                              ORDER BY day, position)
              FROM core.product_day_category_rank WHERE asin IN ('B0TFIA0001', 'B0TFIA0003')),
        '0 ; 9100000001#5 digital-text paid, 9100000002#7 books paid, 9100000001#6 digital-text paid, '
        '9100000001#4 digital-text paid, 9100000003#2 digital-text free');
END;
$$;

-- ============================================================================================================
-- Test 7 : exclusions, fiche sans rang général, atomicité
-- ============================================================================================================
CREATE FUNCTION pg_temp.fail_insert() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'échec simulé';
END;
$$;

DO $$
DECLARE
    before_print text;
    before_runs bigint;
    before_other integer;
    failed boolean := false;
    r core.build_run;
BEGIN
    PERFORM pg_temp.check('7a', 'fiche en échec, fiche papier, fiche d''une autre version : absentes de CORE',
        (SELECT count(*)::text FROM core.book WHERE asin IN ('B0TFIA0004', 'B0TFIA0005', 'B0TFIA0006')), '0');
    PERFORM pg_temp.check('7b', 'fiche sans rang général : ligne du jour, rang NULL, rien de reporté ; prix du format sélectionné',
        (SELECT string_agg(to_char(day, 'MM-DD') || ' ' || coalesce(general_rank::text, 'NULL') || ' '
                           || coalesce(general_rank_list_type, '-') || ' ' || price_amount || ' ' || review_count,
                           ', ' ORDER BY day)
           FROM core.product_day WHERE asin = 'B0TFIA0001'),
        '12-01 1000 paid 4.99 10, 12-02 NULL - 4.99 12, 12-03 900 paid 3.99 15');
    -- Construction en échec : contenu et journal inchangés
    before_print := pg_temp.core_fingerprint();
    before_runs := (SELECT count(*) FROM core.build_run);
    CREATE TRIGGER test_fail BEFORE INSERT ON core.product_day FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_insert();
    BEGIN
        PERFORM core.rebuild('test');
    EXCEPTION WHEN OTHERS THEN
        failed := true;
    END;
    DROP TRIGGER test_fail ON core.product_day;
    PERFORM pg_temp.check('7c', 'construction en échec : erreur, contenu et journal inchangés',
        failed::text || ' ' || (pg_temp.core_fingerprint() = before_print)::text || ' '
        || ((SELECT count(*) FROM core.build_run) = before_runs)::text, 'true true true');
    -- Fiche d'une autre version : comptée, exclue
    SELECT product_pages_other_version INTO before_other FROM core.rebuild('test');
    PERFORM pg_temp.fiche('f7-autre', 'B0TFIA0007', '2026-12-04T11:00:00Z', version => 'test-autre');
    SELECT * INTO r FROM core.rebuild('test');
    PERFORM pg_temp.check('7d', 'fiche d''une autre version : comptée, contenu inchangé',
        (r.product_pages_other_version - before_other)::text || ' ' || (pg_temp.core_fingerprint() = before_print)::text,
        '1 true');
END;
$$;

-- ============================================================================================================
-- Test 8 : minimisation de la description
-- ============================================================================================================
DO $$
DECLARE
    tbl text;
    found bigint;
    total bigint := 0;
BEGIN
    PERFORM pg_temp.check('8a', 'aucune colonne de texte ou de balisage de description dans core',
        (SELECT count(*)::text FROM information_schema.columns
          WHERE table_schema = 'core' AND column_name IN ('description_text', 'description_markup')), '0');
    FOR tbl IN SELECT c.relname FROM pg_class c
                WHERE c.relnamespace = 'core'::regnamespace AND c.relkind IN ('r', 'v') LOOP
        EXECUTE format('SELECT count(*) FROM core.%I t WHERE t::text LIKE %L', tbl, '%SENTINELLE-DESCRIPTION-021%')
            INTO found;
        total := total + found;
    END LOOP;
    PERFORM pg_temp.check('8b', 'texte sentinelle de STAGING absent de toutes les tables et de la vue de core',
                          total::text, '0');
    PERFORM pg_temp.check('8c', 'empreintes et longueurs égales à celles de STAGING',
        (SELECT (d.description_sha256 = po.description_text_sha256
                 AND d.description_length = char_length(po.description_text)
                 AND m.description_markup_sha256 = po.description_markup_sha256
                 AND m.description_markup_length = char_length(po.description_markup))::text
           FROM core.book_description_version d
           JOIN core.book_description_markup_version m USING (asin)
           JOIN staging.product_observation po ON po.raw_page_id = d.first_raw_page_id
          WHERE d.asin = 'B0TFIA0003'),
        'true');
END;
$$;

-- ============================================================================================================
-- Test 9 : lignage
-- ============================================================================================================
DO $$
DECLARE
    tbl text;
    bad bigint;
    total bigint := 0;
BEGIN
    -- Chaque version désigne, au début et à la fin, des fiches éligibles de son livre
    FOR tbl IN SELECT c.relname FROM pg_class c
                WHERE c.relnamespace = 'core'::regnamespace AND c.relkind = 'r' AND c.relname LIKE 'book\_%\_version' LOOP
        EXECUTE format($q$SELECT count(*) FROM core.%I v
                          WHERE NOT EXISTS (SELECT 1 FROM core.eligible_product_page('test') e
                                             WHERE e.id = v.first_raw_page_id AND e.asin = v.asin)
                             OR NOT EXISTS (SELECT 1 FROM core.eligible_product_page('test') e
                                             WHERE e.id = v.last_raw_page_id AND e.asin = v.asin)$q$, tbl) INTO bad;
        total := total + bad;
    END LOOP;
    PERFORM pg_temp.check('9a', 'versions des dix tables : fiches de début et de fin éligibles et du bon livre',
                          total::text || ' sur ' || (SELECT count(*) FROM pg_class WHERE relnamespace = 'core'::regnamespace
                                                       AND relkind = 'r' AND relname LIKE 'book\_%\_version'),
                          '0 sur 10');
    PERFORM pg_temp.check('9b', 'valeurs des versions égales à celles de STAGING (première fiche de la version)',
        (SELECT count(*)::text FROM core.book_series_version v
           JOIN staging.product_observation po ON po.raw_page_id = v.first_raw_page_id
          WHERE (v.series_name, v.series_form, v.series_position, v.series_total)
                IS DISTINCT FROM (po.series_name, po.series_form, po.series_position, po.series_total))
        || ' ' ||
        (SELECT count(*)::text FROM core.book_title_version v
           JOIN staging.product_observation po ON po.raw_page_id = v.last_raw_page_id
          WHERE v.title <> po.title),
        '0 0');
    PERFORM pg_temp.check('9c', 'mesures : fiche du bon livre, prix de l''onglet sélectionné, note et avis de STAGING',
        (SELECT count(*) FILTER (WHERE rp.asin <> pd.asin OR f.price_amount IS DISTINCT FROM pd.price_amount
                                    OR po.rating IS DISTINCT FROM pd.rating
                                    OR po.review_count IS DISTINCT FROM pd.review_count) || ' écart(s) sur '
                || count(*)
           FROM core.product_day pd
           JOIN raw.raw_page rp ON rp.id = pd.raw_page_id
           JOIN staging.product_observation po ON po.raw_page_id = pd.raw_page_id
           JOIN staging.product_format f ON f.raw_page_id = pd.raw_page_id AND f.is_selected),
        '0 écart(s) sur 13');
    PERFORM pg_temp.check('9d', 'répartition des étoiles reprise',
        (SELECT concat_ws(' ', stars_1_percent, stars_2_percent, stars_3_percent, stars_4_percent, stars_5_percent)
           FROM core.product_day WHERE asin = 'B0TFIA0003'),
        '5 5 10 20 60');
END;
$$;

-- ============================================================================================================
-- Test 10 : vue des valeurs actuelles
-- ============================================================================================================
DO $$
BEGIN
    PERFORM pg_temp.check('10a', 'valeurs actuelles et jour de leur dernière observation',
        (SELECT concat_ws(' ', title, title_seen_on, cover_seen_on, series_position || '/' || series_total,
                          has_aplus::text, aplus_seen_on, measured_on, price_amount, review_count, general_rank)
           FROM core.book_current WHERE asin = 'B0TFIA0001'),
        'Titre A 2026-12-03 2026-12-03 2/4 false 2026-12-03 2026-12-03 3.99 15 900');
    PERFORM pg_temp.check('10b', 'livre connu seulement par les Tops : colonnes de fiche vides',
        (SELECT concat_ws(' ', coalesce(title, 'NULL'), coalesce(measured_on::text, 'NULL'), first_ranking_day)
           FROM core.book_current WHERE asin = 'B0TTOP0001'),
        'NULL NULL 2026-12-02');
    PERFORM pg_temp.check('10c', 'vue en security_invoker',
        (SELECT coalesce(array_to_string(reloptions, ','), '') FROM pg_class
          WHERE oid = 'core.book_current'::regclass),
        'security_invoker=true');
END;
$$;

-- ============================================================================================================
-- Test 11 : droits
-- ============================================================================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc p CROSS JOIN LATERAL aclexplode(p.proacl) a
                WHERE p.pronamespace = 'core'::regnamespace AND a.grantee = 0)
       OR EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'core'::regnamespace AND (proacl IS NULL OR prosecdef)) THEN
        RAISE EXCEPTION 'ÉCHEC test 11a : une fonction de core est ouverte à PUBLIC ou en SECURITY DEFINER';
    END IF;
    RAISE NOTICE 'OK test 11a : fonctions de core fermées à PUBLIC, SECURITY INVOKER';
END;
$$;

SET LOCAL ROLE books_reader;
DO $$
BEGIN
    PERFORM count(*) FROM core.book_title_version;
    PERFORM count(*) FROM core.book_cover_version;
    PERFORM count(*) FROM core.book_description_version;
    PERFORM count(*) FROM core.book_description_markup_version;
    PERFORM count(*) FROM core.book_series_version;
    PERFORM count(*) FROM core.book_print_pages_version;
    PERFORM count(*) FROM core.book_aplus_version;
    PERFORM count(*) FROM core.book_publication_date_version;
    PERFORM count(*) FROM core.book_language_version;
    PERFORM count(*) FROM core.book_file_size_version;
    PERFORM count(*) FROM core.product_day;
    PERFORM count(*) FROM core.product_day_category_rank;
    PERFORM count(*) FROM core.book_current;
    RAISE NOTICE 'OK test 11b : books_reader lit les douze nouvelles tables et la vue';
END;
$$;
SELECT pg_temp.expect_refusal(11, 'books_reader : core.eligible_product_page', 'SELECT * FROM core.eligible_product_page(''test'')', '42501', NULL);
SELECT pg_temp.expect_refusal(11, 'books_reader : core.retained_product_page', 'SELECT * FROM core.retained_product_page(''test'')', '42501', NULL);
SELECT pg_temp.expect_refusal(11, 'books_reader : DELETE', 'DELETE FROM core.product_day', '42501', NULL);
SELECT pg_temp.expect_refusal(11, 'books_reader : INSERT', 'INSERT INTO core.book_title_version (asin) VALUES (''B0TFIA0009'')', '42501', NULL);
RESET ROLE;
SET LOCAL ROLE books_collector;
SELECT pg_temp.expect_refusal(11, 'books_collector : lecture', 'SELECT count(*) FROM core.product_day', '42501', NULL);
RESET ROLE;
SET LOCAL ROLE books_transformer;
DO $$
DECLARE
    r core.build_run;
BEGIN
    SELECT * INTO r FROM core.rebuild('test');
    PERFORM pg_temp.check('11c', 'books_transformer construit les deux lots', r.core_version || ' ' || r.product_days, '2 13');
END;
$$;
RESET ROLE;

-- ============================================================================================================
-- Test 12 : journal de la dernière construction (en dernier : les tests 2 à 11 désignent d'abord la règle enfreinte)
-- ============================================================================================================
DO $$
DECLARE
    r core.build_run;
BEGIN
    SELECT * INTO r FROM core.build_run ORDER BY id DESC LIMIT 1;
    PERFORM pg_temp.check('12a', 'journal, lot 2 : fiches éligibles, retenues, en échec, livres-jours, versions, rangs',
        concat_ws(' ', r.product_pages_eligible, r.product_pages_used, r.product_pages_failed, r.product_days,
                  r.attribute_versions, r.product_category_ranks),
        '15 13 1 13 27 5');
    PERFORM pg_temp.check('12b', 'journal, lot 1 : pages retenues, lignes, livres, catégories',
        concat_ws(' ', r.pages_used, r.ranking_rows, r.books, r.categories), '1 2 5 3');
END;
$$;

ROLLBACK;

-- Contrôle final : CORE et son journal retrouvent leur état d'avant le test ; aucune page de test n'est restée
DO $$
BEGIN
    IF pg_temp.core_fingerprint() IS DISTINCT FROM current_setting('test.core_avant')
       OR (SELECT count(*) FROM core.build_run)::text <> current_setting('test.journal_avant')
       OR EXISTS (SELECT 1 FROM raw.raw_page
                   WHERE content_sha256 = encode(sha256(convert_to('test-core2-f1-1', 'UTF8')), 'hex')) THEN
        RAISE EXCEPTION 'ÉCHEC test final : CORE, son journal ou RAW diffèrent de l''état d''avant le test';
    END IF;
    RAISE NOTICE 'OK test final : CORE et journal inchangés, aucune page de test conservée';
END;
$$;
