-- Tests de la migration 007 : fiches produit dans STAGING (décision 015, étape D)
--
-- À exécuter EN TANT QUE PROPRIÉTAIRE de la base, depuis le dossier du dépôt (bash), migrations 001 à 007 appliquées :
--   docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_007_fiches_produit.sql
-- Même principe que test_006 : le propriétaire prépare raw, puis endosse books_transformer et books_collector
-- (SET LOCAL ROLE). Chaque refus attendu doit venir de la contrainte nommée (ou du droit) attendu.
-- Tout se déroule dans une transaction annulée par ROLLBACK : aucune donnée n'est conservée. Valeurs inventées.

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

-- Empreinte SHA-256 d'un texte, en hexadécimal (celle qu'attend la contrainte)
CREATE FUNCTION pg_temp.h(t text) RETURNS text LANGUAGE sql IMMUTABLE AS
    $$ SELECT encode(sha256(convert_to(t, 'UTF8')), 'hex') $$;

-- Préparation, en tant que propriétaire : trois fiches RAW de test
DO $$
BEGIN
    IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : connecté en tant que %, le propriétaire (superutilisateur) est attendu', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.schema_migration WHERE version = 7) THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : migration 7 absente de schema_migration';
    END IF;
    INSERT INTO raw.collect_run (collector_version) VALUES ('test');
    INSERT INTO raw.raw_page (run_id, page_type, asin, requested_url, fetch_status, content_sha256, content_bytes,
                              storage_path, capture_method, metadata_path, metadata_sha256)
        SELECT id, 'product', v.asin, 'https://test', 'ok', 'fe' || repeat(v.n::text, 62), 1, 'test',
               'extension-dom', 'test.json', 'fe' || repeat('c', 62)
          FROM raw.collect_run, (VALUES (1, 'B0FAUX0001'), (2, '2000000001'), (3, 'B0FAUX0003')) AS v(n, asin)
         WHERE collector_version = 'test';
    RAISE NOTICE 'OK test 0 : propriétaire, migration 7 présente, fiches RAW de test créées';
END;
$$;

CREATE TEMP TABLE test_ids ON COMMIT DROP AS
    SELECT (SELECT id FROM raw.raw_page WHERE requested_url = 'https://test' AND asin = 'B0FAUX0001') AS page1,
           (SELECT id FROM raw.raw_page WHERE requested_url = 'https://test' AND asin = '2000000001') AS page2,
           (SELECT id FROM raw.raw_page WHERE requested_url = 'https://test' AND asin = 'B0FAUX0003') AS page3;
GRANT SELECT ON test_ids TO books_transformer;

-- ============================================================================================================
-- books_transformer
-- ============================================================================================================
SET LOCAL ROLE books_transformer;

DO $$
DECLARE
    page1 bigint := (SELECT page1 FROM test_ids);
    page2 bigint := (SELECT page2 FROM test_ids);
    page3 bigint := (SELECT page3 FROM test_ids);
    run1  bigint;
    run   bigint;
    t     record;
    obs   text := 'INSERT INTO staging.product_observation (raw_page_id, extract_run_id, format_label, title';
BEGIN
    IF current_user <> 'books_transformer' THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : rôle courant %, books_transformer attendu', current_user;
    END IF;

    -- Test 1 : fiche Kindle complète, fiche papier mise à part, fiche sans avis ni description : acceptées
    INSERT INTO staging.extract_run (extractor_version) VALUES ('test') RETURNING id INTO run1;
    INSERT INTO staging.page_extraction (raw_page_id, extract_run_id, status, error_message, entry_count)
        VALUES (page1, run1, 'ok', NULL, 1), (page2, run1, 'skipped', 'format papier', 0), (page3, run1, 'ok', NULL, 1);
    INSERT INTO staging.product_observation (
        raw_page_id, extract_run_id, format_label, title, series_form, series_name, series_position, series_total,
        publication_date, language, print_pages, file_size_value, file_size_unit, isbn13, rating, review_count,
        cover_url, description_text, description_text_sha256, description_markup, description_markup_sha256,
        has_aplus, breadcrumb)
    VALUES (page1, run1, 'Format Kindle', 'Titre d’exemple pour les tests', 'livre_n_sur_n', 'La Saga d''exemple', 2, 3,
            '2026-01-01', 'Français', 412, 1.2, 'MB', '978-2000000005', 4.4, 1234,
            'https://m.media-amazon.com/images/I/exemple.jpg', 'Une description inventée.',
            pg_temp.h('Une description inventée.'), '<p>Une description <b>inventée</b>.</p>',
            pg_temp.h('<p>Une description <b>inventée</b>.</p>'), true, 'Boutique Kindle › Catégorie d''exemple'),
           (page3, run1, 'Format Kindle', 'Un autre livre', 'fait_partie', 'Une série', NULL, NULL,
            NULL, NULL, NULL, NULL, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, NULL, false, NULL);
    INSERT INTO staging.product_format (raw_page_id, extract_run_id, position, swatch_kind, label, is_selected,
                                        linked_asin, price_amount, currency, price_qualifier, ku_borrow)
        VALUES (page1, run1, 1, 'KINDLE', 'Format Kindle', true, NULL, 4.99, 'EUR', 'exact', true),
               (page1, run1, 2, 'AUDIO_DOWNLOAD', 'Livre audio', false, 'B0FAUX0004', 0, 'EUR', 'avec_abonnement', false),
               (page1, run1, 3, 'HARDCOVER', 'Relié', false, 'B0FAUX0005', NULL, NULL, 'non_affiche', false),
               (page1, run1, 4, 'PAPERBACK', 'Broché', false, '2000000001', 14.9, 'EUR', 'a_partir_de', false);
    INSERT INTO staging.product_sales_rank (raw_page_id, extract_run_id, position, is_general, rank, store,
                                            category_node, list_type)
        VALUES (page1, run1, 1, true, 1234, 'digital-text', NULL, 'paid'),
               (page1, run1, 2, false, 5, 'digital-text', '10000000001', 'paid'),
               (page1, run1, 3, false, 12, 'books', '10000000002', 'paid');
    INSERT INTO staging.product_rating_share (raw_page_id, extract_run_id, stars, percent)
        SELECT page1, run1, s, p FROM (VALUES (5, 62), (4, 20), (3, 10), (2, 5), (1, 3)) AS v(s, p);
    UPDATE staging.extract_run SET pages_skipped = 1, pages_extracted = 2 WHERE id = run1;
    RAISE NOTICE 'OK test 1 : fiche complète, fiche papier « skipped », fiche sans avis acceptées ; pages_skipped modifiable';

    -- Test 2 : nouvelle exécution enregistrée avant la suppression des lignes de la fiche : refusée par la clé composée
    INSERT INTO staging.extract_run (extractor_version) VALUES ('test-2') RETURNING id INTO run;
    DELETE FROM staging.product_format WHERE raw_page_id = page1;
    DELETE FROM staging.product_sales_rank WHERE raw_page_id = page1;
    DELETE FROM staging.product_rating_share WHERE raw_page_id = page1;
    PERFORM pg_temp.expect_refusal(2, 'nouvelle exécution enregistrée avant la suppression de l''observation',
        format('UPDATE staging.page_extraction SET extract_run_id = %s WHERE raw_page_id = %s', run, page1),
        '23503', 'product_observation_page_extraction_fk');

    -- Test 3 : réextraction dans l'ordre : suppression, mise à jour de page_extraction, insertion
    DELETE FROM staging.product_observation WHERE raw_page_id = page1;
    UPDATE staging.page_extraction SET extract_run_id = run, extracted_at = now() WHERE raw_page_id = page1;
    INSERT INTO staging.product_observation (raw_page_id, extract_run_id, format_label, title)
        VALUES (page1, run, 'Format Kindle', 'Titre changé');
    INSERT INTO staging.product_format (raw_page_id, extract_run_id, position, swatch_kind, label, is_selected,
                                        linked_asin, price_amount, currency, price_qualifier, ku_borrow)
        VALUES (page1, run, 1, 'OTHER', 'Format Kindle', true, NULL, 0, 'EUR', 'exact', false);
    RAISE NOTICE 'OK test 3 : réextraction acceptée (DELETE, UPDATE de page_extraction, INSERT)';

    -- Tests 10 à 49 : refus, chacun par la contrainte attendue
    FOR t IN
        SELECT * FROM (VALUES
            (10, 'statut « skipped » avec une ligne comptée',
                 format('UPDATE staging.page_extraction SET entry_count = 1 WHERE raw_page_id = %s', page2),
                 '23514', 'page_extraction_result_ck'),
            (11, 'statut « skipped » sans motif',
                 format('UPDATE staging.page_extraction SET error_message = NULL WHERE raw_page_id = %s', page2),
                 '23514', 'page_extraction_result_ck'),
            (12, 'statut inconnu',
                 format('UPDATE staging.page_extraction SET status = %L WHERE raw_page_id = %s', 'ignored', page2),
                 '23514', 'page_extraction_status_ck'),
            (13, 'titre vide', format(obs || ') VALUES (%s, %s, %L, %L)', page2, run1, 'Format Kindle', ' '),
                 '23514', 'product_observation_title_ck'),
            (14, 'empreinte de la description qui n''est pas celle du texte',
                 format(obs || ', description_text, description_text_sha256, description_markup, description_markup_sha256)'
                        ' VALUES (%s, %s, %L, %L, %L, %L, %L, %L)', page2, run1, 'Format Kindle', 'T', 'texte',
                        pg_temp.h('autre texte'), '<p>texte</p>', pg_temp.h('<p>texte</p>')),
                 '23514', 'product_observation_description_text_sha256_ck'),
            (15, 'empreinte du balisage qui n''est pas celle du balisage',
                 format(obs || ', description_text, description_text_sha256, description_markup, description_markup_sha256)'
                        ' VALUES (%s, %s, %L, %L, %L, %L, %L, %L)', page2, run1, 'Format Kindle', 'T', 'texte',
                        pg_temp.h('texte'), '<p>texte</p>', pg_temp.h('texte')),
                 '23514', 'product_observation_description_markup_sha256_ck'),
            (16, 'texte de description sans balisage',
                 format(obs || ', description_text, description_text_sha256) VALUES (%s, %s, %L, %L, %L, %L)',
                        page2, run1, 'Format Kindle', 'T', 'texte', pg_temp.h('texte')),
                 '23514', 'product_observation_description_ck'),
            (17, 'note avec zéro avis',
                 format(obs || ', rating, review_count) VALUES (%s, %s, %L, %L, 4.5, 0)', page2, run1, 'Format Kindle', 'T'),
                 '23514', 'product_observation_rating_reviews_ck'),
            (18, 'avis sans note',
                 format(obs || ', review_count) VALUES (%s, %s, %L, %L, 12)', page2, run1, 'Format Kindle', 'T'),
                 '23514', 'product_observation_rating_reviews_ck'),
            (19, 'note supérieure à 5',
                 format(obs || ', rating, review_count) VALUES (%s, %s, %L, %L, 5.5, 3)', page2, run1, 'Format Kindle', 'T'),
                 '23514', 'product_observation_rating_ck'),
            (20, 'rang dans la série sans série « Livre n sur N »',
                 format(obs || ', series_form, series_name, series_position, series_total) VALUES (%s, %s, %L, %L, %L, %L, 2, 3)',
                        page2, run1, 'Format Kindle', 'T', 'fait_partie', 'Une série'),
                 '23514', 'product_observation_series_ck'),
            (21, 'rang dans la série supérieur au total',
                 format(obs || ', series_form, series_name, series_position, series_total) VALUES (%s, %s, %L, %L, %L, %L, 4, 3)',
                        page2, run1, 'Format Kindle', 'T', 'livre_n_sur_n', 'Une série'),
                 '23514', 'product_observation_series_ck'),
            (22, 'série sans nom',
                 format(obs || ', series_form) VALUES (%s, %s, %L, %L, %L)', page2, run1, 'Format Kindle', 'T', 'fait_partie'),
                 '23514', 'product_observation_series_ck'),
            (23, 'taille du fichier sans unité',
                 format(obs || ', file_size_value) VALUES (%s, %s, %L, %L, 1.2)', page2, run1, 'Format Kindle', 'T'),
                 '23514', 'product_observation_file_size_ck'),
            (24, 'unité de taille non observée',
                 format(obs || ', file_size_value, file_size_unit) VALUES (%s, %s, %L, %L, 1.2, %L)',
                        page2, run1, 'Format Kindle', 'T', 'GB'),
                 '23514', 'product_observation_file_size_unit_ck'),
            (25, 'ISBN-13 sans tiret',
                 format(obs || ', isbn13) VALUES (%s, %s, %L, %L, %L)', page2, run1, 'Format Kindle', 'T', '9782000000005'),
                 '23514', 'product_observation_isbn13_ck'),
            (26, 'couverture en http',
                 format(obs || ', cover_url) VALUES (%s, %s, %L, %L, %L)', page2, run1, 'Format Kindle', 'T', 'http://x/y.jpg'),
                 '23514', 'product_observation_cover_url_ck'),
            (27, 'observation d''une autre exécution',
                 format(obs || ') VALUES (%s, %s, %L, %L)', page2, run, 'Format Kindle', 'T'),
                 '23503', 'product_observation_page_extraction_fk'),
            (28, 'observation d''une page sans page_extraction',
                 format(obs || ') VALUES (%s, %s, %L, %L)', -1, run, 'Format Kindle', 'T'),
                 '23503', 'product_observation_page_extraction_fk'),
            (30, 'onglet sélectionné avec un lien',
                 format('INSERT INTO staging.product_format VALUES (%s, %s, 9, %L, %L, true, %L, 1, %L, %L, false)',
                        page1, run, 'PAPERBACK', 'Broché', 'B0FAUX0009', 'EUR', 'exact'),
                 '23514', 'product_format_link_ck'),
            (31, 'onglet non sélectionné sans lien',
                 format('INSERT INTO staging.product_format VALUES (%s, %s, 9, %L, %L, false, NULL, 1, %L, %L, false)',
                        page1, run, 'PAPERBACK', 'Broché', 'EUR', 'exact'),
                 '23514', 'product_format_link_ck'),
            (32, 'prix « non affiché » avec un montant',
                 format('INSERT INTO staging.product_format VALUES (%s, %s, 9, %L, %L, false, %L, 1, %L, %L, false)',
                        page1, run, 'HARDCOVER', 'Relié', 'B0FAUX0009', 'EUR', 'non_affiche'),
                 '23514', 'product_format_price_shown_ck'),
            (33, 'prix exact sans montant',
                 format('INSERT INTO staging.product_format VALUES (%s, %s, 9, %L, %L, false, %L, NULL, NULL, %L, false)',
                        page1, run, 'HARDCOVER', 'Relié', 'B0FAUX0009', 'exact'),
                 '23514', 'product_format_price_shown_ck'),
            (34, 'montant sans devise',
                 format('INSERT INTO staging.product_format VALUES (%s, %s, 9, %L, %L, false, %L, 1, NULL, %L, false)',
                        page1, run, 'HARDCOVER', 'Relié', 'B0FAUX0009', 'exact'),
                 '23514', 'product_format_price_currency_ck'),
            (35, 'emprunt KU sur un onglet papier',
                 format('INSERT INTO staging.product_format VALUES (%s, %s, 9, %L, %L, false, %L, 1, %L, %L, true)',
                        page1, run, 'PAPERBACK', 'Broché', 'B0FAUX0009', 'EUR', 'exact'),
                 '23514', 'product_format_ku_borrow_ck'),
            (36, 'qualificatif de prix inconnu',
                 format('INSERT INTO staging.product_format VALUES (%s, %s, 9, %L, %L, false, %L, 1, %L, %L, false)',
                        page1, run, 'PAPERBACK', 'Broché', 'B0FAUX0009', 'EUR', 'gratuit'),
                 '23514', 'product_format_price_qualifier_ck'),
            (37, 'second onglet sélectionné pour une fiche',
                 format('INSERT INTO staging.product_format VALUES (%s, %s, 9, %L, %L, true, NULL, 1, %L, %L, false)',
                        page1, run, 'PAPERBACK', 'Broché', 'EUR', 'exact'),
                 '23505', 'product_format_selected_uq'),
            (38, 'onglet d''une autre exécution',
                 format('INSERT INTO staging.product_format VALUES (%s, %s, 9, %L, %L, false, %L, 1, %L, %L, false)',
                        page1, run1, 'PAPERBACK', 'Broché', 'B0FAUX0009', 'EUR', 'exact'),
                 '23503', 'product_format_page_extraction_fk'),
            (40, 'rang de catégorie sans numéro',
                 format('INSERT INTO staging.product_sales_rank VALUES (%s, %s, 1, false, 5, %L, NULL, %L)',
                        page1, run, 'digital-text', 'paid'),
                 '23514', 'product_sales_rank_node_ck'),
            (41, 'boutique inconnue',
                 format('INSERT INTO staging.product_sales_rank VALUES (%s, %s, 1, false, 5, %L, %L, %L)',
                        page1, run, 'music', '1', 'paid'),
                 '23514', 'product_sales_rank_store_ck'),
            (42, 'rang nul',
                 format('INSERT INTO staging.product_sales_rank VALUES (%s, %s, 1, true, 0, %L, NULL, %L)',
                        page1, run, 'books', 'paid'),
                 '23514', 'product_sales_rank_rank_ck'),
            (43, 'deux rangs généraux',
                 format('INSERT INTO staging.product_sales_rank VALUES (%s, %s, 1, true, 5, %L, NULL, %L), '
                        '(%s, %s, 2, true, 6, %L, NULL, %L)', page1, run, 'books', 'paid', page1, run, 'books', 'paid'),
                 '23505', 'product_sales_rank_general_uq'),
            (44, 'liste inconnue',
                 format('INSERT INTO staging.product_sales_rank VALUES (%s, %s, 1, true, 5, %L, NULL, %L)',
                        page1, run, 'books', 'kindle'),
                 '23514', 'product_sales_rank_list_type_ck'),
            (46, 'six étoiles',
                 format('INSERT INTO staging.product_rating_share VALUES (%s, %s, 6, 10)', page1, run),
                 '23514', 'product_rating_share_stars_ck'),
            (47, 'pourcentage supérieur à 100',
                 format('INSERT INTO staging.product_rating_share VALUES (%s, %s, 5, 101)', page1, run),
                 '23514', 'product_rating_share_percent_ck'),
            (48, 'deux pourcentages pour un niveau',
                 format('INSERT INTO staging.product_rating_share VALUES (%s, %s, 5, 10), (%s, %s, 5, 20)',
                        page1, run, page1, run),
                 '23505', 'product_rating_share_pk'),
            (49, 'répartition d''une autre exécution',
                 format('INSERT INTO staging.product_rating_share VALUES (%s, %s, 5, 10)', page1, run1),
                 '23503', 'product_rating_share_page_extraction_fk')
        ) AS v(num, label, sql, state, expected)
        ORDER BY num
    LOOP
        PERFORM pg_temp.expect_refusal(t.num, t.label, t.sql, t.state, t.expected);
    END LOOP;

    -- Tests 50 à 53 : droits refusés à books_transformer
    PERFORM pg_temp.expect_refusal(50, 'UPDATE de product_observation (seuls DELETE et INSERT sont permis)',
        format('UPDATE staging.product_observation SET title = %L WHERE raw_page_id = %s', 'x', page1), '42501', NULL);
    PERFORM pg_temp.expect_refusal(51, 'UPDATE de product_format',
        format('UPDATE staging.product_format SET label = %L WHERE raw_page_id = %s', 'x', page1), '42501', NULL);
    PERFORM pg_temp.expect_refusal(52, 'TRUNCATE de product_sales_rank', 'TRUNCATE staging.product_sales_rank',
        '42501', NULL);
    PERFORM pg_temp.expect_refusal(53, 'UPDATE de extract_run hors des colonnes de clôture',
        format('UPDATE staging.extract_run SET extractor_version = %L WHERE id = %s', 'x', run), '42501', NULL);
END;
$$;

-- ============================================================================================================
-- books_collector : aucun accès
-- ============================================================================================================
RESET ROLE;
SET LOCAL ROLE books_collector;

DO $$
DECLARE
    t text;
    n int := 60;
BEGIN
    FOREACH t IN ARRAY ARRAY['product_observation', 'product_format', 'product_sales_rank', 'product_rating_share'] LOOP
        PERFORM pg_temp.expect_refusal(n, 'lecture de ' || t || ' par books_collector',
            format('SELECT count(*) FROM staging.%I', t), '42501', NULL);
        n := n + 1;
    END LOOP;
END;
$$;

RESET ROLE;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.role_table_grants
                WHERE table_schema = 'staging'
                  AND table_name IN ('product_observation', 'product_format', 'product_sales_rank', 'product_rating_share')
                  AND grantee IN ('PUBLIC', 'books_collector')) THEN
        RAISE EXCEPTION 'ÉCHEC test 70 : PUBLIC ou books_collector a un droit sur une table de fiches';
    END IF;
    RAISE NOTICE 'OK test 70 : aucun droit de PUBLIC ni de books_collector sur les tables de fiches';
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
