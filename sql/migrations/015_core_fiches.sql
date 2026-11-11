-- Migration 015 : couche CORE, lot 2 : fiches produit (décision 021)
-- À appliquer par le propriétaire de la base, après la migration 014.
--
-- Attributs des fiches Kindle versionnés attribut par attribut (dix tables typées), mesures en état du jour
-- (core.product_day et ses rangs par catégorie), jours par source dans core.book et core.category, vue des valeurs
-- actuelles. core.rebuild() reconstruit les deux lots dans la même transaction ; CORE_VERSION passe à 2.
-- La description n'entre dans CORE que par empreinte et longueur, jamais par son texte (décision 013).

BEGIN;

DO $$
BEGIN
    IF (SELECT max(version) FROM public.schema_migration) <> 14 THEN
        RAISE EXCEPTION 'Migration 015 : la dernière migration appliquée doit être la 14';
    END IF;
END;
$$;

-- ------------------------------------------------------------------------------------------------------------
-- Jours par source (décision 021, section 6) : les lignes existantes gardent leurs jours de Top ; les jours de
-- fiche sont remplis à la prochaine construction
-- ------------------------------------------------------------------------------------------------------------
ALTER TABLE core.book DROP CONSTRAINT book_days_ck;
ALTER TABLE core.book RENAME COLUMN first_day TO first_ranking_day;
ALTER TABLE core.book RENAME COLUMN last_day TO last_ranking_day;
ALTER TABLE core.book
    ALTER COLUMN first_ranking_day DROP NOT NULL,
    ALTER COLUMN last_ranking_day DROP NOT NULL,
    ADD COLUMN first_product_day date,
    ADD COLUMN last_product_day date,
    ADD CONSTRAINT book_ranking_days_ck CHECK ((first_ranking_day IS NULL) = (last_ranking_day IS NULL)
                                              AND first_ranking_day <= last_ranking_day),
    ADD CONSTRAINT book_product_days_ck CHECK ((first_product_day IS NULL) = (last_product_day IS NULL)
                                              AND first_product_day <= last_product_day),
    ADD CONSTRAINT book_some_source_ck CHECK (first_ranking_day IS NOT NULL OR first_product_day IS NOT NULL);
COMMENT ON COLUMN core.book.first_ranking_day IS 'Premier jour (Paris) dans une page de Top retenue ; NULL : jamais vu dans un Top.';
COMMENT ON COLUMN core.book.first_product_day IS 'Premier jour (Paris) d''une fiche Kindle éligible ; NULL : aucune fiche.';

ALTER TABLE core.category DROP CONSTRAINT category_days_ck;
ALTER TABLE core.category RENAME COLUMN first_day TO first_list_day;
ALTER TABLE core.category RENAME COLUMN last_day TO last_list_day;
ALTER TABLE core.category
    ALTER COLUMN first_list_day DROP NOT NULL,
    ALTER COLUMN last_list_day DROP NOT NULL,
    ADD COLUMN first_product_rank_day date,
    ADD COLUMN last_product_rank_day date,
    ADD CONSTRAINT category_list_days_ck CHECK ((first_list_day IS NULL) = (last_list_day IS NULL)
                                               AND first_list_day <= last_list_day),
    ADD CONSTRAINT category_product_rank_days_ck CHECK ((first_product_rank_day IS NULL) = (last_product_rank_day IS NULL)
                                                       AND first_product_rank_day <= last_product_rank_day),
    ADD CONSTRAINT category_some_source_ck CHECK (first_list_day IS NOT NULL OR first_product_rank_day IS NOT NULL);
COMMENT ON COLUMN core.category.first_product_rank_day IS
    'Premier jour (Paris) où la catégorie apparaît dans les rangs (général ou par catégorie) d''une fiche retenue.';

-- Journal : comptes du lot 2 (NULL pour les constructions antérieures à CORE_VERSION 2)
ALTER TABLE core.build_run
    ADD COLUMN product_pages_eligible      integer CHECK (product_pages_eligible >= 0),
    ADD COLUMN product_pages_used          integer CHECK (product_pages_used >= 0),
    ADD COLUMN product_pages_other_version integer CHECK (product_pages_other_version >= 0),
    ADD COLUMN product_pages_failed        integer CHECK (product_pages_failed >= 0),
    ADD COLUMN product_days                integer CHECK (product_days >= 0),
    ADD COLUMN attribute_versions          integer CHECK (attribute_versions >= 0),
    ADD COLUMN product_category_ranks      integer CHECK (product_category_ranks >= 0);
COMMENT ON COLUMN core.build_run.product_pages_failed IS
    'Fiches extraites par cette version de l''extracteur mais en échec (parse_failed, integrity_failed) : hors de CORE.';

-- ------------------------------------------------------------------------------------------------------------
-- Attributs : une table de versions par attribut (décision 021, sections 3 et 4)
-- ------------------------------------------------------------------------------------------------------------
CREATE TABLE core.book_title_version (
    asin text NOT NULL REFERENCES core.book (asin),
    title text NOT NULL CONSTRAINT book_title_version_title_ck CHECK (btrim(title) <> ''),
    valid_from date NOT NULL, valid_to date NOT NULL,
    first_observed_at timestamptz NOT NULL, last_observed_at timestamptz NOT NULL,
    observations integer NOT NULL CHECK (observations >= 1),
    first_raw_page_id bigint NOT NULL REFERENCES raw.raw_page (id),
    last_raw_page_id bigint NOT NULL REFERENCES raw.raw_page (id),
    CONSTRAINT book_title_version_pk PRIMARY KEY (asin, first_raw_page_id),
    CONSTRAINT book_title_version_bounds_ck CHECK (valid_from <= valid_to AND first_observed_at <= last_observed_at)
);

CREATE TABLE core.book_cover_version (
    asin text NOT NULL REFERENCES core.book (asin),
    cover_url text NOT NULL CONSTRAINT book_cover_version_cover_url_ck CHECK (cover_url LIKE 'https://%'),
    valid_from date NOT NULL, valid_to date NOT NULL,
    first_observed_at timestamptz NOT NULL, last_observed_at timestamptz NOT NULL,
    observations integer NOT NULL CHECK (observations >= 1),
    first_raw_page_id bigint NOT NULL REFERENCES raw.raw_page (id),
    last_raw_page_id bigint NOT NULL REFERENCES raw.raw_page (id),
    CONSTRAINT book_cover_version_pk PRIMARY KEY (asin, first_raw_page_id),
    CONSTRAINT book_cover_version_bounds_ck CHECK (valid_from <= valid_to AND first_observed_at <= last_observed_at)
);

CREATE TABLE core.book_description_version (
    asin text NOT NULL REFERENCES core.book (asin),
    description_sha256 text NOT NULL CONSTRAINT book_description_version_sha256_ck CHECK (description_sha256 ~ '^[0-9a-f]{64}$'),
    description_length integer NOT NULL CONSTRAINT book_description_version_length_ck CHECK (description_length >= 1),
    valid_from date NOT NULL, valid_to date NOT NULL,
    first_observed_at timestamptz NOT NULL, last_observed_at timestamptz NOT NULL,
    observations integer NOT NULL CHECK (observations >= 1),
    first_raw_page_id bigint NOT NULL REFERENCES raw.raw_page (id),
    last_raw_page_id bigint NOT NULL REFERENCES raw.raw_page (id),
    CONSTRAINT book_description_version_pk PRIMARY KEY (asin, first_raw_page_id),
    CONSTRAINT book_description_version_bounds_ck CHECK (valid_from <= valid_to AND first_observed_at <= last_observed_at)
);

CREATE TABLE core.book_description_markup_version (
    asin text NOT NULL REFERENCES core.book (asin),
    description_markup_sha256 text NOT NULL
        CONSTRAINT book_description_markup_version_sha256_ck CHECK (description_markup_sha256 ~ '^[0-9a-f]{64}$'),
    description_markup_length integer NOT NULL
        CONSTRAINT book_description_markup_version_length_ck CHECK (description_markup_length >= 1),
    valid_from date NOT NULL, valid_to date NOT NULL,
    first_observed_at timestamptz NOT NULL, last_observed_at timestamptz NOT NULL,
    observations integer NOT NULL CHECK (observations >= 1),
    first_raw_page_id bigint NOT NULL REFERENCES raw.raw_page (id),
    last_raw_page_id bigint NOT NULL REFERENCES raw.raw_page (id),
    CONSTRAINT book_description_markup_version_pk PRIMARY KEY (asin, first_raw_page_id),
    CONSTRAINT book_description_markup_version_bounds_ck CHECK (valid_from <= valid_to AND first_observed_at <= last_observed_at)
);

CREATE TABLE core.book_series_version (
    asin text NOT NULL REFERENCES core.book (asin),
    series_form text NOT NULL CONSTRAINT book_series_version_form_ck CHECK (series_form IN ('livre_n_sur_n', 'fait_partie')),
    series_name text NOT NULL CONSTRAINT book_series_version_name_ck CHECK (btrim(series_name) <> ''),
    series_position smallint CONSTRAINT book_series_version_position_ck CHECK (series_position >= 1),
    series_total smallint CONSTRAINT book_series_version_total_ck CHECK (series_total >= 1),
    valid_from date NOT NULL, valid_to date NOT NULL,
    first_observed_at timestamptz NOT NULL, last_observed_at timestamptz NOT NULL,
    observations integer NOT NULL CHECK (observations >= 1),
    first_raw_page_id bigint NOT NULL REFERENCES raw.raw_page (id),
    last_raw_page_id bigint NOT NULL REFERENCES raw.raw_page (id),
    CONSTRAINT book_series_version_pk PRIMARY KEY (asin, first_raw_page_id),
    CONSTRAINT book_series_version_bounds_ck CHECK (valid_from <= valid_to AND first_observed_at <= last_observed_at),
    -- Même cohérence que staging.product_observation (migration 007)
    CONSTRAINT book_series_version_series_ck CHECK (
        (series_position IS NULL) = (series_form <> 'livre_n_sur_n')
        AND (series_total IS NULL) = (series_form <> 'livre_n_sur_n')
        AND (series_position IS NULL OR series_position <= series_total))
);

CREATE TABLE core.book_print_pages_version (
    asin text NOT NULL REFERENCES core.book (asin),
    print_pages integer NOT NULL CONSTRAINT book_print_pages_version_ck CHECK (print_pages >= 1),
    valid_from date NOT NULL, valid_to date NOT NULL,
    first_observed_at timestamptz NOT NULL, last_observed_at timestamptz NOT NULL,
    observations integer NOT NULL CHECK (observations >= 1),
    first_raw_page_id bigint NOT NULL REFERENCES raw.raw_page (id),
    last_raw_page_id bigint NOT NULL REFERENCES raw.raw_page (id),
    CONSTRAINT book_print_pages_version_pk PRIMARY KEY (asin, first_raw_page_id),
    CONSTRAINT book_print_pages_version_bounds_ck CHECK (valid_from <= valid_to AND first_observed_at <= last_observed_at)
);

CREATE TABLE core.book_aplus_version (
    asin text NOT NULL REFERENCES core.book (asin),
    has_aplus boolean NOT NULL,
    valid_from date NOT NULL, valid_to date NOT NULL,
    first_observed_at timestamptz NOT NULL, last_observed_at timestamptz NOT NULL,
    observations integer NOT NULL CHECK (observations >= 1),
    first_raw_page_id bigint NOT NULL REFERENCES raw.raw_page (id),
    last_raw_page_id bigint NOT NULL REFERENCES raw.raw_page (id),
    CONSTRAINT book_aplus_version_pk PRIMARY KEY (asin, first_raw_page_id),
    CONSTRAINT book_aplus_version_bounds_ck CHECK (valid_from <= valid_to AND first_observed_at <= last_observed_at)
);
COMMENT ON COLUMN core.book_aplus_version.has_aplus IS
    'Vrai : bloc A+ avec contenu ; faux : bloc vide (une valeur). Élément absent (NULL dans STAGING) : observation ignorée.';

CREATE TABLE core.book_publication_date_version (
    asin text NOT NULL REFERENCES core.book (asin),
    publication_date date NOT NULL,
    valid_from date NOT NULL, valid_to date NOT NULL,
    first_observed_at timestamptz NOT NULL, last_observed_at timestamptz NOT NULL,
    observations integer NOT NULL CHECK (observations >= 1),
    first_raw_page_id bigint NOT NULL REFERENCES raw.raw_page (id),
    last_raw_page_id bigint NOT NULL REFERENCES raw.raw_page (id),
    CONSTRAINT book_publication_date_version_pk PRIMARY KEY (asin, first_raw_page_id),
    CONSTRAINT book_publication_date_version_bounds_ck CHECK (valid_from <= valid_to AND first_observed_at <= last_observed_at)
);

CREATE TABLE core.book_language_version (
    asin text NOT NULL REFERENCES core.book (asin),
    language text NOT NULL CONSTRAINT book_language_version_ck CHECK (btrim(language) <> ''),
    valid_from date NOT NULL, valid_to date NOT NULL,
    first_observed_at timestamptz NOT NULL, last_observed_at timestamptz NOT NULL,
    observations integer NOT NULL CHECK (observations >= 1),
    first_raw_page_id bigint NOT NULL REFERENCES raw.raw_page (id),
    last_raw_page_id bigint NOT NULL REFERENCES raw.raw_page (id),
    CONSTRAINT book_language_version_pk PRIMARY KEY (asin, first_raw_page_id),
    CONSTRAINT book_language_version_bounds_ck CHECK (valid_from <= valid_to AND first_observed_at <= last_observed_at)
);

CREATE TABLE core.book_file_size_version (
    asin text NOT NULL REFERENCES core.book (asin),
    file_size_value numeric(8,1) NOT NULL CONSTRAINT book_file_size_version_value_ck CHECK (file_size_value > 0),
    file_size_unit text NOT NULL CONSTRAINT book_file_size_version_unit_ck CHECK (file_size_unit IN ('KB', 'MB')),
    valid_from date NOT NULL, valid_to date NOT NULL,
    first_observed_at timestamptz NOT NULL, last_observed_at timestamptz NOT NULL,
    observations integer NOT NULL CHECK (observations >= 1),
    first_raw_page_id bigint NOT NULL REFERENCES raw.raw_page (id),
    last_raw_page_id bigint NOT NULL REFERENCES raw.raw_page (id),
    CONSTRAINT book_file_size_version_pk PRIMARY KEY (asin, first_raw_page_id),
    CONSTRAINT book_file_size_version_bounds_ck CHECK (valid_from <= valid_to AND first_observed_at <= last_observed_at)
);

COMMENT ON TABLE core.book_title_version IS
    'Versions d''un attribut de fiche (décision 021) : suite ininterrompue d''observations de même valeur (ordre fetched_at, '
    'puis id de la page). NULL n''est pas un changement ; un retour à une ancienne valeur ouvre une nouvelle version. '
    'Même règle pour les dix tables core.book_*_version.';
COMMENT ON TABLE core.book_description_version IS
    'Empreinte SHA-256 et longueur (caractères) du texte de la description, jamais le texte (minimisation, décision 013).';
COMMENT ON TABLE core.book_description_markup_version IS
    'Empreinte SHA-256 et longueur du balisage de la description, jamais le balisage : distingue une réécriture d''un '
    'simple changement de mise en forme.';

-- ------------------------------------------------------------------------------------------------------------
-- Mesures : état du jour (décision 021, section 5)
-- ------------------------------------------------------------------------------------------------------------
CREATE TABLE core.product_day (
    asin                       text NOT NULL REFERENCES core.book (asin),
    source                     text NOT NULL,
    day                        date NOT NULL,
    raw_page_id                bigint NOT NULL REFERENCES raw.raw_page (id),
    observed_at                timestamptz NOT NULL,
    day_observations           smallint NOT NULL CONSTRAINT product_day_observations_ck CHECK (day_observations >= 1),
    price_amount               numeric(8,2) CONSTRAINT product_day_price_ck CHECK (price_amount >= 0),
    currency                   text CONSTRAINT product_day_currency_ck CHECK (currency ~ '^[A-Z]{3}$'),
    price_qualifier            text CONSTRAINT product_day_price_qualifier_ck
                               CHECK (price_qualifier IN ('exact', 'a_partir_de', 'avec_abonnement', 'avec_offre_essai',
                                                          'non_affiche')),
    ku_borrow                  boolean,
    rating                     numeric(2,1) CONSTRAINT product_day_rating_ck CHECK (rating BETWEEN 0 AND 5),
    review_count               integer CONSTRAINT product_day_review_count_ck CHECK (review_count >= 0),
    stars_1_percent            smallint CHECK (stars_1_percent BETWEEN 0 AND 100),
    stars_2_percent            smallint CHECK (stars_2_percent BETWEEN 0 AND 100),
    stars_3_percent            smallint CHECK (stars_3_percent BETWEEN 0 AND 100),
    stars_4_percent            smallint CHECK (stars_4_percent BETWEEN 0 AND 100),
    stars_5_percent            smallint CHECK (stars_5_percent BETWEEN 0 AND 100),
    general_rank               integer CONSTRAINT product_day_general_rank_ck CHECK (general_rank >= 1),
    general_rank_store         text CONSTRAINT product_day_general_rank_store_ck
                               CHECK (general_rank_store IN ('digital-text', 'books')),
    general_rank_list_type     text CONSTRAINT product_day_general_rank_list_type_ck
                               CHECK (general_rank_list_type IN ('paid', 'free')),
    general_rank_category_node text,
    CONSTRAINT product_day_pk PRIMARY KEY (asin, day),
    -- Nœud de sous-boutique du rang général (forme rare) : catégorie connue de CORE (MATCH SIMPLE : NULL non vérifié)
    CONSTRAINT product_day_general_rank_category_fk FOREIGN KEY (source, general_rank_category_node) REFERENCES core.category,
    CONSTRAINT product_day_price_currency_ck CHECK ((price_amount IS NULL) = (currency IS NULL)),
    CONSTRAINT product_day_format_ck CHECK ((price_qualifier IS NULL) = (ku_borrow IS NULL)),
    CONSTRAINT product_day_rating_reviews_ck CHECK ((rating IS NULL) = (review_count IS NULL OR review_count = 0)),
    CONSTRAINT product_day_general_rank_ck2 CHECK (
        (general_rank IS NULL) = (general_rank_store IS NULL)
        AND (general_rank IS NULL) = (general_rank_list_type IS NULL)
        AND (general_rank_category_node IS NULL OR general_rank IS NOT NULL))
);

COMMENT ON TABLE core.product_day IS
    'Mesures d''une fiche Kindle, une ligne par (livre, jour de Paris) : dernière fiche éligible du jour (fetched_at, puis id). '
    'Jamais mêlées aux valeurs des cartes de Top (core.ranking_day). Aucune observation, aucune ligne.';
COMMENT ON COLUMN core.product_day.price_amount IS
    'Prix de l''onglet du format de la fiche (sélectionné) ; avec « Emprunt », prix d''achat du message « ou … pour acheter ».';
COMMENT ON COLUMN core.product_day.ku_borrow IS
    'Indice NON VÉRIFIÉ : l''onglet affiche « Emprunt » (offre d''abonnement). Exclu de toute analyse avant décision (décision 015).';
COMMENT ON COLUMN core.product_day.review_count IS
    'Nombre d''avis affiché sur la fiche (« Commentaires client ») ; 0 : aucun avis. Différent des « évaluations » des Tops.';
COMMENT ON COLUMN core.product_day.general_rank IS
    'Rang général de la fiche ; NULL : non affiché ce jour-là. Le rang de la veille n''est jamais reporté.';

CREATE TABLE core.product_day_category_rank (
    asin          text NOT NULL,
    day           date NOT NULL,
    position      smallint NOT NULL CONSTRAINT product_day_category_rank_position_ck CHECK (position >= 1),
    rank          integer NOT NULL CONSTRAINT product_day_category_rank_rank_ck CHECK (rank >= 1),
    store         text NOT NULL CONSTRAINT product_day_category_rank_store_ck CHECK (store IN ('digital-text', 'books')),
    list_type     text NOT NULL CONSTRAINT product_day_category_rank_list_type_ck CHECK (list_type IN ('paid', 'free')),
    source        text NOT NULL,
    category_node text NOT NULL,
    CONSTRAINT product_day_category_rank_pk PRIMARY KEY (asin, day, position),
    CONSTRAINT product_day_category_rank_day_fk FOREIGN KEY (asin, day) REFERENCES core.product_day,
    CONSTRAINT product_day_category_rank_category_fk FOREIGN KEY (source, category_node) REFERENCES core.category
);
COMMENT ON TABLE core.product_day_category_rank IS
    'Rangs par catégorie de la fiche retenue du jour ; la boutique reste sur chaque rang (décision 021, section 6).';

-- ------------------------------------------------------------------------------------------------------------
-- Fiches éligibles et fiche retenue du jour
-- ------------------------------------------------------------------------------------------------------------
-- Fiches Kindle extraites avec succès par la version donnée de l'extracteur (les fiches papier sont « skipped »)
CREATE FUNCTION core.eligible_product_page(p_extractor_version text)
RETURNS TABLE (id bigint, source text, asin text, fetched_at timestamptz, day date)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT rp.id, rp.source, rp.asin, rp.fetched_at, (rp.fetched_at AT TIME ZONE 'Europe/Paris')::date
      FROM raw.raw_page rp
      JOIN staging.page_extraction pe ON pe.raw_page_id = rp.id
      JOIN staging.extract_run er ON er.id = pe.extract_run_id
     WHERE rp.page_type = 'product'
       AND rp.fetch_status = 'ok'
       AND pe.status = 'ok'
       AND er.extractor_version = p_extractor_version
$$;

-- Dernière fiche éligible du jour de chaque livre (fetched_at le plus grand, puis id le plus grand), avec le compte
CREATE FUNCTION core.retained_product_page(p_extractor_version text)
RETURNS TABLE (id bigint, source text, asin text, fetched_at timestamptz, day date, observations integer)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT c.id, c.source, c.asin, c.fetched_at, c.day, c.observations::integer
      FROM (SELECT e.*,
                   count(*) OVER (PARTITION BY e.asin, e.day) AS observations,
                   row_number() OVER (PARTITION BY e.asin, e.day ORDER BY e.fetched_at DESC, e.id DESC) AS rn
              FROM core.eligible_product_page(p_extractor_version) e) c
     WHERE c.rn = 1
$$;

-- ------------------------------------------------------------------------------------------------------------
-- Construction des deux lots
-- ------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.rebuild(p_extractor_version text)
RETURNS core.build_run
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
SET lock_timeout = '30s'
AS $$
DECLARE
    -- CORE_VERSION : version des règles de construction (décisions 020 et 021)
    v_core_version CONSTANT text := '2';
    v_candidates integer;
    v_rows integer;
    v_attribute_versions integer := 0;
    v_run core.build_run;
    v_spec record;
    v_select text;
    v_change text;
    v_values text;
    v_count integer;
BEGIN
    IF p_extractor_version IS NULL OR btrim(p_extractor_version) = '' THEN
        RAISE EXCEPTION 'core.rebuild : version de l''extracteur obligatoire';
    END IF;
    -- Verrou de l'extracteur (repository.LOCK_KEY) : jamais pendant une extraction d'une autre session
    PERFORM pg_advisory_xact_lock(4211011005);

    -- Ordre imposé par les clés étrangères : lot 2, puis lot 1
    DELETE FROM core.product_day_category_rank;
    DELETE FROM core.product_day;
    DELETE FROM core.book_title_version;
    DELETE FROM core.book_cover_version;
    DELETE FROM core.book_description_version;
    DELETE FROM core.book_description_markup_version;
    DELETE FROM core.book_series_version;
    DELETE FROM core.book_print_pages_version;
    DELETE FROM core.book_aplus_version;
    DELETE FROM core.book_publication_date_version;
    DELETE FROM core.book_language_version;
    DELETE FROM core.book_file_size_version;
    DELETE FROM core.ranking_day;
    DELETE FROM core.list_day;
    DELETE FROM core.category_name;
    DELETE FROM core.book;
    DELETE FROM core.category;

    -- Catégories : pages de Top éligibles et rangs (général ou par catégorie) des fiches retenues
    WITH list_days AS (
        SELECT e.source, e.category_node, min(e.day) AS first_day, max(e.day) AS last_day
          FROM core.eligible_page(p_extractor_version) e
         GROUP BY e.source, e.category_node
    ), rank_days AS (
        SELECT r.source, sr.category_node, min(r.day) AS first_day, max(r.day) AS last_day
          FROM core.retained_product_page(p_extractor_version) r
          JOIN staging.product_sales_rank sr ON sr.raw_page_id = r.id
         WHERE sr.category_node IS NOT NULL
         GROUP BY r.source, sr.category_node
    )
    INSERT INTO core.category (source, category_node, first_list_day, last_list_day, first_product_rank_day,
                               last_product_rank_day)
    SELECT coalesce(l.source, d.source), coalesce(l.category_node, d.category_node), l.first_day, l.last_day,
           d.first_day, d.last_day
      FROM list_days l
      FULL JOIN rank_days d ON d.source = l.source AND d.category_node = l.category_node;

    -- Lot 1 : versions des noms (pages de Top seulement)
    WITH observation AS (
        SELECT e.source, e.category_node, n.kind, n.name, e.day, e.fetched_at, e.id
          FROM core.eligible_page(p_extractor_version) e
          JOIN staging.category_observation co ON co.raw_page_id = e.id
         CROSS JOIN LATERAL (VALUES ('display', co.display_name), ('short', co.short_name)) AS n (kind, name)
         WHERE n.name IS NOT NULL
    ), marked AS (
        SELECT o.*, CASE WHEN o.name IS DISTINCT FROM lag(o.name) OVER w THEN 1 ELSE 0 END AS opens
          FROM observation o
        WINDOW w AS (PARTITION BY o.source, o.category_node, o.kind ORDER BY o.fetched_at, o.id)
    ), numbered AS (
        SELECT m.*, sum(m.opens) OVER (PARTITION BY m.source, m.category_node, m.kind
                                       ORDER BY m.fetched_at, m.id) AS version_no
          FROM marked m
    )
    INSERT INTO core.category_name (source, category_node, name_kind, name, valid_from, valid_to, first_observed_at,
                                    last_observed_at, observations, first_raw_page_id, last_raw_page_id)
    SELECT n.source, n.category_node, n.kind, n.name, min(n.day), max(n.day), min(n.fetched_at), max(n.fetched_at),
           count(*), (array_agg(n.id ORDER BY n.fetched_at, n.id))[1],
           (array_agg(n.id ORDER BY n.fetched_at DESC, n.id DESC))[1]
      FROM numbered n
     GROUP BY n.source, n.category_node, n.kind, n.version_no, n.name;

    -- Lot 1 : dernière capture du jour de chaque page de liste
    WITH counted AS (
        SELECT e.*,
               count(*) OVER (PARTITION BY e.source, e.category_node, e.list_type, e.page_number, e.day) AS observations,
               row_number() OVER (PARTITION BY e.source, e.category_node, e.list_type, e.page_number, e.day
                                  ORDER BY e.fetched_at DESC, e.id DESC) AS rn
          FROM core.eligible_page(p_extractor_version) e
    ), retained AS (
        SELECT c.source, c.category_node, c.list_type, c.day,
               max(c.id) FILTER (WHERE c.page_number = 1) AS p1_id,
               max(c.fetched_at) FILTER (WHERE c.page_number = 1) AS p1_at,
               coalesce(max(c.observations) FILTER (WHERE c.page_number = 1), 0) AS p1_obs,
               coalesce(max(c.entry_count) FILTER (WHERE c.page_number = 1), 0) AS p1_ranks,
               max(c.id) FILTER (WHERE c.page_number = 2) AS p2_id,
               max(c.fetched_at) FILTER (WHERE c.page_number = 2) AS p2_at,
               coalesce(max(c.observations) FILTER (WHERE c.page_number = 2), 0) AS p2_obs,
               coalesce(max(c.entry_count) FILTER (WHERE c.page_number = 2), 0) AS p2_ranks
          FROM counted c
         WHERE c.rn = 1
         GROUP BY c.source, c.category_node, c.list_type, c.day
    )
    INSERT INTO core.list_day (source, category_node, list_type, day, p1_raw_page_id, p1_observed_at, p1_observations,
                               p1_ranks, p2_raw_page_id, p2_observed_at, p2_observations, p2_ranks, complete)
    SELECT r.source, r.category_node, r.list_type, r.day, r.p1_id, r.p1_at, r.p1_obs, r.p1_ranks,
           r.p2_id, r.p2_at, r.p2_obs, r.p2_ranks, r.p1_id IS NOT NULL AND (r.p1_ranks < 50 OR r.p2_id IS NOT NULL)
      FROM retained r;

    -- Livres : pages de Top retenues et fiches éligibles, jours par source
    WITH ranking AS (
        SELECT re.asin, min(ld.day) AS first_day, max(ld.day) AS last_day
          FROM core.list_day ld
         CROSS JOIN LATERAL (VALUES (ld.p1_raw_page_id), (ld.p2_raw_page_id)) AS p (raw_page_id)
          JOIN staging.ranking_entry re ON re.raw_page_id = p.raw_page_id
         GROUP BY re.asin
    ), product AS (
        SELECT e.asin, min(e.day) AS first_day, max(e.day) AS last_day
          FROM core.eligible_product_page(p_extractor_version) e
         GROUP BY e.asin
    )
    INSERT INTO core.book (asin, first_ranking_day, last_ranking_day, first_product_day, last_product_day)
    SELECT asin, r.first_day, r.last_day, p.first_day, p.last_day
      FROM ranking r
      FULL JOIN product p USING (asin);

    -- Lot 1 : lignes des pages retenues ; un livre sur p1 et p2 garde la ligne de la capture la plus récente
    SELECT count(*) INTO v_candidates
      FROM core.list_day ld
     CROSS JOIN LATERAL (VALUES (ld.p1_raw_page_id), (ld.p2_raw_page_id)) AS p (raw_page_id)
      JOIN staging.ranking_entry re ON re.raw_page_id = p.raw_page_id;

    WITH candidate AS (
        SELECT ld.source, ld.category_node, ld.list_type, ld.day, p.raw_page_id, p.observed_at, p.observations,
               re.asin, re.rank, re.has_card, re.price_amount, re.currency, re.rating, re.review_count,
               re.ku_sticker_hint,
               row_number() OVER (PARTITION BY ld.source, ld.category_node, ld.list_type, ld.day, re.asin
                                  ORDER BY p.observed_at DESC, p.raw_page_id DESC) AS rn
          FROM core.list_day ld
         CROSS JOIN LATERAL (VALUES (ld.p1_raw_page_id, ld.p1_observed_at, ld.p1_observations),
                                    (ld.p2_raw_page_id, ld.p2_observed_at, ld.p2_observations))
                            AS p (raw_page_id, observed_at, observations)
          JOIN staging.ranking_entry re ON re.raw_page_id = p.raw_page_id
    )
    INSERT INTO core.ranking_day (asin, source, category_node, list_type, day, rank, raw_page_id, observed_at,
                                  day_observations, has_card, price_amount, currency, rating, review_count,
                                  ku_sticker_hint)
    SELECT c.asin, c.source, c.category_node, c.list_type, c.day, c.rank, c.raw_page_id, c.observed_at,
           c.observations, c.has_card, c.price_amount, c.currency, c.rating, c.review_count, c.ku_sticker_hint
      FROM candidate c
     WHERE c.rn = 1;
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    -- Lot 2 : versions des attributs. Une seule règle, écrite une fois, appliquée aux dix tables (décision 021,
    -- section 4) : observations où la première valeur est non nulle, ordre (fetched_at, id), nouvelle version quand
    -- une valeur quelconque diffère (IS DISTINCT FROM) de l'observation précédente.
    FOR v_spec IN
        SELECT * FROM (VALUES
            ('book_title_version', ARRAY['title'], ARRAY['po.title']),
            ('book_cover_version', ARRAY['cover_url'], ARRAY['po.cover_url']),
            ('book_description_version', ARRAY['description_sha256', 'description_length'],
             ARRAY['po.description_text_sha256', 'char_length(po.description_text)']),
            ('book_description_markup_version', ARRAY['description_markup_sha256', 'description_markup_length'],
             ARRAY['po.description_markup_sha256', 'char_length(po.description_markup)']),
            ('book_series_version', ARRAY['series_name', 'series_form', 'series_position', 'series_total'],
             ARRAY['po.series_name', 'po.series_form', 'po.series_position', 'po.series_total']),
            ('book_print_pages_version', ARRAY['print_pages'], ARRAY['po.print_pages']),
            ('book_aplus_version', ARRAY['has_aplus'], ARRAY['po.has_aplus']),
            ('book_publication_date_version', ARRAY['publication_date'], ARRAY['po.publication_date']),
            ('book_language_version', ARRAY['language'], ARRAY['po.language']),
            ('book_file_size_version', ARRAY['file_size_value', 'file_size_unit'],
             ARRAY['po.file_size_value', 'po.file_size_unit'])
        ) AS s (target_table, target_columns, source_expressions)
    LOOP
        SELECT string_agg(format('%s AS v%s', x.expr, x.n), ', ' ORDER BY x.n),
               string_agg(format('o.v%1$s IS DISTINCT FROM lag(o.v%1$s) OVER w', x.n), ' OR ' ORDER BY x.n),
               string_agg(format('n.v%s', x.n), ', ' ORDER BY x.n)
          INTO v_select, v_change, v_values
          FROM unnest(v_spec.source_expressions) WITH ORDINALITY AS x (expr, n);
        EXECUTE format($sql$
            WITH observation AS (
                SELECT e.asin, e.day, e.fetched_at, e.id, %1$s
                  FROM core.eligible_product_page($1) e
                  JOIN staging.product_observation po ON po.raw_page_id = e.id
                 WHERE %2$s IS NOT NULL
            ), marked AS (
                SELECT o.*, CASE WHEN %3$s THEN 1 ELSE 0 END AS opens
                  FROM observation o
                WINDOW w AS (PARTITION BY o.asin ORDER BY o.fetched_at, o.id)
            ), numbered AS (
                SELECT m.*, sum(m.opens) OVER (PARTITION BY m.asin ORDER BY m.fetched_at, m.id) AS version_no
                  FROM marked m
            )
            INSERT INTO core.%4$I (asin, %5$s, valid_from, valid_to, first_observed_at, last_observed_at, observations,
                                   first_raw_page_id, last_raw_page_id)
            SELECT n.asin, %6$s, min(n.day), max(n.day), min(n.fetched_at), max(n.fetched_at), count(*),
                   (array_agg(n.id ORDER BY n.fetched_at, n.id))[1],
                   (array_agg(n.id ORDER BY n.fetched_at DESC, n.id DESC))[1]
              FROM numbered n
             GROUP BY n.asin, n.version_no, %6$s
            $sql$,
            v_select, v_spec.source_expressions[1], v_change, v_spec.target_table,
            (SELECT string_agg(quote_ident(c), ', ') FROM unnest(v_spec.target_columns) AS c), v_values)
        USING p_extractor_version;
        GET DIAGNOSTICS v_count = ROW_COUNT;
        v_attribute_versions := v_attribute_versions + v_count;
    END LOOP;

    -- Lot 2 : mesures de la fiche retenue du jour
    INSERT INTO core.product_day (asin, source, day, raw_page_id, observed_at, day_observations, price_amount, currency,
                                  price_qualifier, ku_borrow, rating, review_count, stars_1_percent, stars_2_percent,
                                  stars_3_percent, stars_4_percent, stars_5_percent, general_rank, general_rank_store,
                                  general_rank_list_type, general_rank_category_node)
    SELECT r.asin, r.source, r.day, r.id, r.fetched_at, r.observations, f.price_amount, f.currency, f.price_qualifier,
           f.ku_borrow, po.rating, po.review_count, s.s1, s.s2, s.s3, s.s4, s.s5, g.rank, g.store, g.list_type,
           g.category_node
      FROM core.retained_product_page(p_extractor_version) r
      JOIN staging.product_observation po ON po.raw_page_id = r.id
      LEFT JOIN staging.product_format f ON f.raw_page_id = r.id AND f.is_selected
      LEFT JOIN staging.product_sales_rank g ON g.raw_page_id = r.id AND g.is_general
      LEFT JOIN LATERAL (
          SELECT max(rs.percent) FILTER (WHERE rs.stars = 1) AS s1, max(rs.percent) FILTER (WHERE rs.stars = 2) AS s2,
                 max(rs.percent) FILTER (WHERE rs.stars = 3) AS s3, max(rs.percent) FILTER (WHERE rs.stars = 4) AS s4,
                 max(rs.percent) FILTER (WHERE rs.stars = 5) AS s5
            FROM staging.product_rating_share rs
           WHERE rs.raw_page_id = r.id) s ON true;

    INSERT INTO core.product_day_category_rank (asin, day, position, rank, store, list_type, source, category_node)
    SELECT r.asin, r.day, sr.position, sr.rank, sr.store, sr.list_type, r.source, sr.category_node
      FROM core.retained_product_page(p_extractor_version) r
      JOIN staging.product_sales_rank sr ON sr.raw_page_id = r.id AND NOT sr.is_general;

    INSERT INTO core.build_run (core_version, extractor_version, pages_eligible, pages_other_version, pages_used,
                                books, categories, category_name_versions, list_days, list_days_incomplete,
                                ranking_rows, cross_page_duplicates, product_pages_eligible, product_pages_used,
                                product_pages_other_version, product_pages_failed, product_days, attribute_versions,
                                product_category_ranks)
    SELECT v_core_version, p_extractor_version,
           (SELECT count(*) FROM core.eligible_page(p_extractor_version)),
           (SELECT count(*)
              FROM raw.raw_page rp
              JOIN staging.page_extraction pe ON pe.raw_page_id = rp.id
              JOIN staging.extract_run er ON er.id = pe.extract_run_id
             WHERE rp.page_type = 'bestseller_list' AND rp.fetch_status = 'ok' AND pe.status = 'ok'
               AND er.extractor_version <> p_extractor_version),
           (SELECT count(ld.p1_raw_page_id) + count(ld.p2_raw_page_id) FROM core.list_day ld),
           (SELECT count(*) FROM core.book),
           (SELECT count(*) FROM core.category),
           (SELECT count(*) FROM core.category_name),
           (SELECT count(*) FROM core.list_day),
           (SELECT count(*) FROM core.list_day ld WHERE NOT ld.complete),
           v_rows,
           v_candidates - v_rows,
           (SELECT count(*) FROM core.eligible_product_page(p_extractor_version)),
           (SELECT count(*) FROM core.retained_product_page(p_extractor_version)),
           (SELECT count(*)
              FROM raw.raw_page rp
              JOIN staging.page_extraction pe ON pe.raw_page_id = rp.id
              JOIN staging.extract_run er ON er.id = pe.extract_run_id
             WHERE rp.page_type = 'product' AND rp.fetch_status = 'ok' AND pe.status = 'ok'
               AND er.extractor_version <> p_extractor_version),
           (SELECT count(*)
              FROM raw.raw_page rp
              JOIN staging.page_extraction pe ON pe.raw_page_id = rp.id
              JOIN staging.extract_run er ON er.id = pe.extract_run_id
             WHERE rp.page_type = 'product' AND pe.status IN ('parse_failed', 'integrity_failed')
               AND er.extractor_version = p_extractor_version),
           (SELECT count(*) FROM core.product_day),
           v_attribute_versions,
           (SELECT count(*) FROM core.product_day_category_rank)
    RETURNING * INTO v_run;
    RETURN v_run;
END;
$$;

-- ------------------------------------------------------------------------------------------------------------
-- Vue des valeurs actuelles : dernière valeur observée de chaque attribut, avec le jour de cette observation, et
-- dernières mesures de fiche (décision 021, section 8). « Actuelle » = dernière vue, pas « d'aujourd'hui ».
-- ------------------------------------------------------------------------------------------------------------
CREATE VIEW core.book_current WITH (security_invoker = true) AS
SELECT b.asin, b.first_ranking_day, b.last_ranking_day, b.first_product_day, b.last_product_day,
       t.title, t.valid_to AS title_seen_on,
       c.cover_url, c.valid_to AS cover_seen_on,
       d.description_sha256, d.description_length, d.valid_to AS description_seen_on,
       dm.description_markup_sha256, dm.description_markup_length, dm.valid_to AS description_markup_seen_on,
       s.series_form, s.series_name, s.series_position, s.series_total, s.valid_to AS series_seen_on,
       pp.print_pages, pp.valid_to AS print_pages_seen_on,
       a.has_aplus, a.valid_to AS aplus_seen_on,
       pd.publication_date, pd.valid_to AS publication_date_seen_on,
       l.language, l.valid_to AS language_seen_on,
       fs.file_size_value, fs.file_size_unit, fs.valid_to AS file_size_seen_on,
       m.day AS measured_on, m.price_amount, m.currency, m.price_qualifier, m.rating, m.review_count,
       m.general_rank, m.general_rank_store, m.general_rank_list_type
  FROM core.book b
  LEFT JOIN LATERAL (SELECT v.* FROM core.book_title_version v WHERE v.asin = b.asin
                      ORDER BY v.last_observed_at DESC, v.last_raw_page_id DESC LIMIT 1) t ON true
  LEFT JOIN LATERAL (SELECT v.* FROM core.book_cover_version v WHERE v.asin = b.asin
                      ORDER BY v.last_observed_at DESC, v.last_raw_page_id DESC LIMIT 1) c ON true
  LEFT JOIN LATERAL (SELECT v.* FROM core.book_description_version v WHERE v.asin = b.asin
                      ORDER BY v.last_observed_at DESC, v.last_raw_page_id DESC LIMIT 1) d ON true
  LEFT JOIN LATERAL (SELECT v.* FROM core.book_description_markup_version v WHERE v.asin = b.asin
                      ORDER BY v.last_observed_at DESC, v.last_raw_page_id DESC LIMIT 1) dm ON true
  LEFT JOIN LATERAL (SELECT v.* FROM core.book_series_version v WHERE v.asin = b.asin
                      ORDER BY v.last_observed_at DESC, v.last_raw_page_id DESC LIMIT 1) s ON true
  LEFT JOIN LATERAL (SELECT v.* FROM core.book_print_pages_version v WHERE v.asin = b.asin
                      ORDER BY v.last_observed_at DESC, v.last_raw_page_id DESC LIMIT 1) pp ON true
  LEFT JOIN LATERAL (SELECT v.* FROM core.book_aplus_version v WHERE v.asin = b.asin
                      ORDER BY v.last_observed_at DESC, v.last_raw_page_id DESC LIMIT 1) a ON true
  LEFT JOIN LATERAL (SELECT v.* FROM core.book_publication_date_version v WHERE v.asin = b.asin
                      ORDER BY v.last_observed_at DESC, v.last_raw_page_id DESC LIMIT 1) pd ON true
  LEFT JOIN LATERAL (SELECT v.* FROM core.book_language_version v WHERE v.asin = b.asin
                      ORDER BY v.last_observed_at DESC, v.last_raw_page_id DESC LIMIT 1) l ON true
  LEFT JOIN LATERAL (SELECT v.* FROM core.book_file_size_version v WHERE v.asin = b.asin
                      ORDER BY v.last_observed_at DESC, v.last_raw_page_id DESC LIMIT 1) fs ON true
  LEFT JOIN LATERAL (SELECT p.* FROM core.product_day p WHERE p.asin = b.asin
                      ORDER BY p.day DESC LIMIT 1) m ON true;

COMMENT ON VIEW core.book_current IS
    'Valeurs actuelles par livre : dernière valeur observée de chaque attribut (version au last_observed_at le plus grand) '
    'et jour de cette observation (*_seen_on) ; dernière ligne de core.product_day (measured_on). Indices d''abonnement exclus.';

-- ------------------------------------------------------------------------------------------------------------
-- Droits
-- ------------------------------------------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION core.eligible_product_page(text), core.retained_product_page(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.eligible_product_page(text), core.retained_product_page(text) TO books_transformer;

GRANT SELECT, INSERT, DELETE ON core.book_title_version, core.book_cover_version, core.book_description_version,
    core.book_description_markup_version, core.book_series_version, core.book_print_pages_version,
    core.book_aplus_version, core.book_publication_date_version, core.book_language_version,
    core.book_file_size_version, core.product_day, core.product_day_category_rank
    TO books_transformer;

-- Lecture : books_reader lit les nouvelles tables et la vue (liste blanche, décision 016 ; test 008)
GRANT SELECT ON core.book_title_version, core.book_cover_version, core.book_description_version,
    core.book_description_markup_version, core.book_series_version, core.book_print_pages_version,
    core.book_aplus_version, core.book_publication_date_version, core.book_language_version,
    core.book_file_size_version, core.product_day, core.product_day_category_rank, core.book_current
    TO books_reader;
-- books_collector ne reçoit aucun droit sur core. Aucun privilège par défaut.

INSERT INTO public.schema_migration (version, description)
VALUES (15, 'Couche CORE, lot 2 : fiches produit');

COMMIT;
