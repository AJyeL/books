-- Migration 014 : couche CORE, lot 1 : classements (décision 020)
-- À appliquer par le propriétaire de la base.
--
-- CORE est entièrement dérivée de STAGING : ses tables (sauf le journal core.build_run) sont vidées puis remplies en
-- entier par core.rebuild(), dans une seule transaction, après chaque extraction. Jamais écrite à la main ; deux
-- constructions sur les mêmes données donnent le même contenu. DELETE plutôt que TRUNCATE : un lecteur voit l'ancien
-- contenu, en entier, jusqu'à la validation (décision 020, section 1).
--
-- Règle de projet : toute modification des règles de construction de CORE est une nouvelle migration qui remplace
-- core.rebuild() et incrémente CORE_VERSION (constante v_core_version ci-dessous) dans le même commit.

BEGIN;

DO $$
BEGIN
    IF (SELECT max(version) FROM public.schema_migration) <> 13 THEN
        RAISE EXCEPTION 'Migration 014 : la dernière migration appliquée doit être la 13';
    END IF;
END;
$$;

CREATE SCHEMA core;

-- Journal des constructions réussies. Historique, hors du contenu reconstructible : jamais vidé. Une construction
-- annulée n'y laisse rien ; elle est signalée dans le bilan de l'extracteur.
CREATE TABLE core.build_run (
    id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    built_at               timestamptz NOT NULL DEFAULT now(),
    core_version           text NOT NULL,
    extractor_version      text NOT NULL,
    pages_eligible         integer NOT NULL CHECK (pages_eligible >= 0),
    pages_other_version    integer NOT NULL CHECK (pages_other_version >= 0),
    pages_used             integer NOT NULL CHECK (pages_used >= 0),
    books                  integer NOT NULL CHECK (books >= 0),
    categories             integer NOT NULL CHECK (categories >= 0),
    category_name_versions integer NOT NULL CHECK (category_name_versions >= 0),
    list_days              integer NOT NULL CHECK (list_days >= 0),
    list_days_incomplete   integer NOT NULL CHECK (list_days_incomplete >= 0),
    ranking_rows           integer NOT NULL CHECK (ranking_rows >= 0),
    cross_page_duplicates  integer NOT NULL CHECK (cross_page_duplicates >= 0)
);

COMMENT ON TABLE core.build_run IS
    'Journal des constructions de CORE réussies (décision 020). Seule table de CORE qui n''est pas reconstruite.';
COMMENT ON COLUMN core.build_run.extractor_version IS
    'Version de l''extracteur dont les pages ont été lues : CORE ne lit que les pages extraites par cette version.';
COMMENT ON COLUMN core.build_run.pages_other_version IS
    'Pages de classement extraites (ok) par une autre version de l''extracteur, exclues : jamais deux versions mélangées.';
COMMENT ON COLUMN core.build_run.cross_page_duplicates IS
    'Livres présents sur la p1 et la p2 retenues d''une même liste du jour : seule la capture la plus récente est gardée.';

-- Un livre par ASIN observé dans une liste retenue
CREATE TABLE core.book (
    asin      text PRIMARY KEY CONSTRAINT book_asin_ck CHECK (asin ~ '^[A-Z0-9]{10}$'),
    first_day date NOT NULL,
    last_day  date NOT NULL,
    CONSTRAINT book_days_ck CHECK (first_day <= last_day)
);

-- Une catégorie par (source, numéro de nœud)
CREATE TABLE core.category (
    source        text NOT NULL CONSTRAINT category_source_ck CHECK (source ~ '^[a-z0-9_]+$'),
    category_node text NOT NULL CONSTRAINT category_node_ck CHECK (category_node ~ '^[0-9]+$'),
    first_day     date NOT NULL,
    last_day      date NOT NULL,
    CONSTRAINT category_pk PRIMARY KEY (source, category_node),
    CONSTRAINT category_days_ck CHECK (first_day <= last_day)
);

-- Versions des noms observés d'une catégorie (décision 020, section 6)
CREATE TABLE core.category_name (
    source            text NOT NULL,
    category_node     text NOT NULL,
    name_kind         text NOT NULL CONSTRAINT category_name_kind_ck CHECK (name_kind IN ('display', 'short')),
    name              text NOT NULL CONSTRAINT category_name_name_ck CHECK (btrim(name) <> ''),
    valid_from        date NOT NULL,
    valid_to          date NOT NULL,
    first_observed_at timestamptz NOT NULL,
    last_observed_at  timestamptz NOT NULL,
    observations      integer NOT NULL CONSTRAINT category_name_observations_ck CHECK (observations >= 1),
    first_raw_page_id bigint NOT NULL REFERENCES raw.raw_page (id),
    last_raw_page_id  bigint NOT NULL REFERENCES raw.raw_page (id),
    CONSTRAINT category_name_pk PRIMARY KEY (source, category_node, name_kind, first_raw_page_id),
    CONSTRAINT category_name_category_fk FOREIGN KEY (source, category_node) REFERENCES core.category,
    CONSTRAINT category_name_days_ck CHECK (valid_from <= valid_to AND first_observed_at <= last_observed_at)
);

COMMENT ON TABLE core.category_name IS
    'Une version = suite ininterrompue d''observations portant le même nom (ordre : fetched_at, puis id de la page). '
    'Un nom non lu (NULL) n''est pas un changement ; un retour à un ancien nom ouvre une nouvelle version.';
COMMENT ON COLUMN core.category_name.valid_from IS
    'Premier jour (Europe/Paris) observé de la version ; valid_to : dernier jour observé. Entre deux versions, le nom est inconnu.';

-- Une ligne par (source, catégorie, type de liste, jour de Paris) observé : pages retenues et complétude
CREATE TABLE core.list_day (
    source          text NOT NULL,
    category_node   text NOT NULL,
    list_type       text NOT NULL CONSTRAINT list_day_list_type_ck CHECK (list_type IN ('paid', 'free')),
    day             date NOT NULL,
    p1_raw_page_id  bigint REFERENCES raw.raw_page (id),
    p1_observed_at  timestamptz,
    p1_observations smallint NOT NULL CONSTRAINT list_day_p1_observations_ck CHECK (p1_observations >= 0),
    p1_ranks        smallint NOT NULL CONSTRAINT list_day_p1_ranks_ck CHECK (p1_ranks BETWEEN 0 AND 50),
    p2_raw_page_id  bigint REFERENCES raw.raw_page (id),
    p2_observed_at  timestamptz,
    p2_observations smallint NOT NULL CONSTRAINT list_day_p2_observations_ck CHECK (p2_observations >= 0),
    p2_ranks        smallint NOT NULL CONSTRAINT list_day_p2_ranks_ck CHECK (p2_ranks BETWEEN 0 AND 50),
    complete        boolean NOT NULL,
    CONSTRAINT list_day_pk PRIMARY KEY (source, category_node, list_type, day),
    CONSTRAINT list_day_category_fk FOREIGN KEY (source, category_node) REFERENCES core.category,
    CONSTRAINT list_day_some_page_ck CHECK (p1_raw_page_id IS NOT NULL OR p2_raw_page_id IS NOT NULL),
    -- Page absente : ni horodatage, ni observation, ni rang ; page retenue : tout renseigné
    CONSTRAINT list_day_p1_ck CHECK ((p1_raw_page_id IS NULL) = (p1_observed_at IS NULL)
                                     AND (p1_raw_page_id IS NULL) = (p1_observations = 0)
                                     AND (p1_raw_page_id IS NULL) = (p1_ranks = 0)),
    CONSTRAINT list_day_p2_ck CHECK ((p2_raw_page_id IS NULL) = (p2_observed_at IS NULL)
                                     AND (p2_raw_page_id IS NULL) = (p2_observations = 0)
                                     AND (p2_raw_page_id IS NULL) = (p2_ranks = 0)),
    -- Complète : p1 courte (moins de 50 rangs, pas de page 2), ou p1 et p2 (règle des 50 rangs, décision 004)
    CONSTRAINT list_day_complete_ck CHECK (
        complete = (p1_raw_page_id IS NOT NULL AND (p1_ranks < 50 OR p2_raw_page_id IS NOT NULL)))
);

COMMENT ON TABLE core.list_day IS
    'Liste du jour : pour chaque numéro de page, la dernière capture du jour extraite avec succès (fetched_at, puis id). '
    'Les deux heures sont conservées, sans seuil ni alerte. Dans une liste incomplète, l''absence d''un livre ne dit rien.';
COMMENT ON COLUMN core.list_day.p1_ranks IS 'Rangs extraits de la page retenue (staging.page_extraction.entry_count).';

-- Une ligne par (livre, source, catégorie, type de liste, jour de Paris)
CREATE TABLE core.ranking_day (
    asin             text NOT NULL REFERENCES core.book (asin),
    source           text NOT NULL,
    category_node    text NOT NULL,
    list_type        text NOT NULL,
    day              date NOT NULL,
    rank             smallint NOT NULL CONSTRAINT ranking_day_rank_ck CHECK (rank BETWEEN 1 AND 100),
    raw_page_id      bigint NOT NULL REFERENCES raw.raw_page (id),
    observed_at      timestamptz NOT NULL,
    day_observations smallint NOT NULL CONSTRAINT ranking_day_observations_ck CHECK (day_observations >= 1),
    has_card         boolean NOT NULL,
    price_amount     numeric(8,2) CONSTRAINT ranking_day_price_ck CHECK (price_amount >= 0),
    currency         text CONSTRAINT ranking_day_currency_ck CHECK (currency ~ '^[A-Z]{3}$'),
    rating           numeric(2,1) CONSTRAINT ranking_day_rating_ck CHECK (rating BETWEEN 0 AND 5),
    review_count     integer CONSTRAINT ranking_day_review_count_ck CHECK (review_count >= 0),
    ku_sticker_hint  boolean,
    CONSTRAINT ranking_day_pk PRIMARY KEY (asin, source, category_node, list_type, day),
    CONSTRAINT ranking_day_rank_uq UNIQUE (source, category_node, list_type, day, rank),
    CONSTRAINT ranking_day_list_day_fk FOREIGN KEY (source, category_node, list_type, day) REFERENCES core.list_day,
    -- Mêmes règles que staging.ranking_entry (migration 005)
    CONSTRAINT ranking_day_no_card_ck CHECK (
        has_card
        OR (price_amount IS NULL AND currency IS NULL AND rating IS NULL AND review_count IS NULL
            AND ku_sticker_hint IS NULL)),
    CONSTRAINT ranking_day_rating_reviews_ck CHECK ((rating IS NULL) = (review_count IS NULL)),
    CONSTRAINT ranking_day_price_currency_ck CHECK ((price_amount IS NULL) = (currency IS NULL))
);

COMMENT ON TABLE core.ranking_day IS
    'Classement du jour (décision 020). Lignage : (raw_page_id, rank) désigne la ligne de staging.ranking_entry retenue. '
    'Aucune observation, aucune ligne : ni report de la veille, ni interpolation.';
COMMENT ON COLUMN core.ranking_day.day_observations IS
    'Captures extraites avec succès, ce jour-là, de la page de liste (catégorie, liste, numéro de page) d''où vient la ligne.';
COMMENT ON COLUMN core.ranking_day.has_card IS
    'Faux : pas de carte détaillée, prix, note, nombre d''évaluations et indice inconnus (NULL). '
    'Vrai avec rating NULL : carte présente, aucune évaluation affichée.';
COMMENT ON COLUMN core.ranking_day.review_count IS
    'Nombre d''évaluations affiché sur la carte (notes avec ou sans commentaire écrit), pas un nombre d''avis écrits.';
COMMENT ON COLUMN core.ranking_day.ku_sticker_hint IS
    'Indice NON VÉRIFIÉ : « ku-sticker » présent dans l''adresse de la couverture. Ce n''est pas une appartenance à '
    'Kindle Unlimited. Exclu de toute analyse tant que l''hypothèse n''est pas vérifiée (décision 011, section 8).';

-- Pages éligibles : pages de classement extraites avec succès par la version donnée de l'extracteur, avec leur jour
-- de Paris (fuseau écrit en toutes lettres : le réglage TimeZone de la session n'y est pour rien).
CREATE FUNCTION core.eligible_page(p_extractor_version text)
RETURNS TABLE (id bigint, source text, category_node text, list_type text, page_number smallint,
               fetched_at timestamptz, day date, entry_count integer)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT rp.id, rp.source, rp.category_node, rp.list_type, rp.page_number, rp.fetched_at,
           (rp.fetched_at AT TIME ZONE 'Europe/Paris')::date, pe.entry_count
      FROM raw.raw_page rp
      JOIN staging.page_extraction pe ON pe.raw_page_id = rp.id
      JOIN staging.extract_run er ON er.id = pe.extract_run_id
     WHERE rp.page_type = 'bestseller_list'
       AND rp.fetch_status = 'ok'
       AND pe.status = 'ok'
       AND er.extractor_version = p_extractor_version
$$;

CREATE FUNCTION core.rebuild(p_extractor_version text)
RETURNS core.build_run
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
SET lock_timeout = '30s'
AS $$
DECLARE
    -- CORE_VERSION : version des règles de construction (décision 020, section 10)
    v_core_version CONSTANT text := '1';
    v_candidates integer;
    v_rows integer;
    v_run core.build_run;
BEGIN
    IF p_extractor_version IS NULL OR btrim(p_extractor_version) = '' THEN
        RAISE EXCEPTION 'core.rebuild : version de l''extracteur obligatoire';
    END IF;
    -- Verrou de l'extracteur (repository.LOCK_KEY) : jamais pendant une extraction d'une autre session, donc sur un
    -- STAGING immobile ; pris d'office par la session de l'extracteur, qui le détient déjà.
    PERFORM pg_advisory_xact_lock(4211011005);

    DELETE FROM core.ranking_day;
    DELETE FROM core.list_day;
    DELETE FROM core.category_name;
    DELETE FROM core.book;
    DELETE FROM core.category;

    INSERT INTO core.category (source, category_node, first_day, last_day)
    SELECT e.source, e.category_node, min(e.day), max(e.day)
      FROM core.eligible_page(p_extractor_version) e
     GROUP BY e.source, e.category_node;

    -- Versions des noms : un nom différent du précédent (dans l'ordre fetched_at, id) ouvre une version
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

    -- Dernière capture du jour de chaque page de liste : fetched_at le plus grand, puis id le plus grand
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

    INSERT INTO core.book (asin, first_day, last_day)
    SELECT re.asin, min(ld.day), max(ld.day)
      FROM core.list_day ld
     CROSS JOIN LATERAL (VALUES (ld.p1_raw_page_id), (ld.p2_raw_page_id)) AS p (raw_page_id)
      JOIN staging.ranking_entry re ON re.raw_page_id = p.raw_page_id
     GROUP BY re.asin;

    -- Lignes des pages retenues ; un livre présent sur p1 et p2 garde la ligne de la capture la plus récente
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

    INSERT INTO core.build_run (core_version, extractor_version, pages_eligible, pages_other_version, pages_used,
                                books, categories, category_name_versions, list_days, list_days_incomplete,
                                ranking_rows, cross_page_duplicates)
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
           v_candidates - v_rows
    RETURNING * INTO v_run;
    RETURN v_run;
END;
$$;

COMMENT ON FUNCTION core.rebuild(text) IS
    'Reconstruit CORE en entier à partir de STAGING (décision 020), dans la transaction de l''appelant. '
    'Lancée par l''extracteur après chaque exécution, avec sa version (EXTRACTOR_VERSION).';

-- Fonctions fermées à PUBLIC (décisions 013 et 016) ; seul l'extracteur les exécute
REVOKE EXECUTE ON FUNCTION core.eligible_page(text), core.rebuild(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.eligible_page(text), core.rebuild(text) TO books_transformer;

-- Extracteur : reconstruction (DELETE puis INSERT) et journal
GRANT USAGE ON SCHEMA core TO books_transformer;
GRANT SELECT, INSERT, DELETE ON core.book, core.category, core.category_name, core.list_day, core.ranking_day
    TO books_transformer;
GRANT SELECT, INSERT ON core.build_run TO books_transformer;

-- Lecture : books_reader lit les six tables (liste blanche, décision 016 ; tests/sql/test_008_role_lecture.sql)
GRANT USAGE ON SCHEMA core TO books_reader;
GRANT SELECT ON core.build_run, core.book, core.category, core.category_name, core.list_day, core.ranking_day
    TO books_reader;
-- books_collector ne reçoit aucun droit sur core. Aucun privilège par défaut.

INSERT INTO public.schema_migration (version, description)
VALUES (14, 'Couche CORE, lot 1 : classements');

COMMIT;
