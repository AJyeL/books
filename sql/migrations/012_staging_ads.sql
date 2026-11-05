-- Migration 012 : rapports Amazon Ads dans STAGING (décision 018, lot B)
-- À appliquer par le propriétaire de la base, toutes les migrations 001 à 011 appliquées.
--
-- STAGING est recalculable à partir de RAW : les lignes d'un fichier sont supprimées et remplacées à chaque
-- réextraction (nouvelle version de l'extracteur des rapports). Les contrôles de CONTENU vivent ici, en statuts
-- d'extraction recalculables ; RAW n'a jugé que la nature du fichier (migration 011).
-- Aucun texte : identifiants Amazon, énumérations d'Amazon, codes de mapping.text_code (décision 019) et quantités
-- additives. L'IDENTITÉ d'une campagne ou d'un groupe est son identifiant Amazon ; le code de son nom est une
-- observation portée par chaque ligne journalière (un renommage ne fusionne ni ne sépare jamais deux campagnes).
-- Écrit par books_transformer seulement ; aucun droit pour books_collector, books_reader (décision 018) ni PUBLIC.

BEGIN;

-- Garde-fou : migration appliquée dans l'ordre
DO $$
BEGIN
    IF (SELECT max(version) FROM public.schema_migration) IS DISTINCT FROM 11 THEN
        RAISE EXCEPTION 'migration 012 : la dernière migration appliquée doit être la 11 (trouvé : %)',
            (SELECT max(version) FROM public.schema_migration);
    END IF;
END;
$$;

-- Une ligne par exécution de l'extracteur des rapports (version propre, distincte de celle des pages)
CREATE TABLE staging.ads_extract_run (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at        timestamptz NOT NULL DEFAULT now(),
    finished_at       timestamptz,
    extractor_version text NOT NULL,
    status            text NOT NULL DEFAULT 'running'
                      CONSTRAINT ads_extract_run_status_ck
                      CHECK (status IN ('running', 'success', 'partial', 'failed')),
    files_ok          integer NOT NULL DEFAULT 0,
    files_no_activity integer NOT NULL DEFAULT 0,
    files_failed      integer NOT NULL DEFAULT 0,
    notes             text
);

-- Une ligne par fichier RAW examiné, remplacée à chaque réextraction
CREATE TABLE staging.ads_file_extraction (
    ads_report_file_id bigint PRIMARY KEY REFERENCES raw.ads_report_file (id),
    extract_run_id     bigint NOT NULL REFERENCES staging.ads_extract_run (id),
    status             text NOT NULL
                       CONSTRAINT ads_file_extraction_status_ck
                       CHECK (status IN ('ok', 'no_activity', 'parse_failed', 'integrity_failed')),
    error_message      text,
    row_count          integer NOT NULL CONSTRAINT ads_file_extraction_row_count_ck CHECK (row_count >= 0),
    -- Première et dernière date des lignes du fichier : bornes de sa contribution à la couverture de son export
    first_day          date,
    last_day           date,
    -- Libellés des colonnes inconnues (information) ; jamais une valeur de cellule
    unknown_columns    text[] NOT NULL DEFAULT '{}',
    extracted_at       timestamptz NOT NULL DEFAULT now(),
    -- Cible des clés étrangères composées des tables de lignes
    CONSTRAINT ads_file_extraction_run_uq UNIQUE (ads_report_file_id, extract_run_id),
    -- ok : des lignes et leurs bornes, aucun motif ; aucune activité rapportée : ni ligne, ni borne, ni motif (ce
    -- n'est pas une anomalie) ; échec : un motif, ni ligne ni borne
    CONSTRAINT ads_file_extraction_result_ck CHECK (
        (status = 'ok' AND error_message IS NULL AND row_count >= 1
            AND first_day IS NOT NULL AND last_day IS NOT NULL AND first_day <= last_day)
     OR (status = 'no_activity' AND error_message IS NULL AND row_count = 0 AND first_day IS NULL AND last_day IS NULL)
     OR (status IN ('parse_failed', 'integrity_failed') AND error_message IS NOT NULL AND error_message <> ''
            AND row_count = 0 AND first_day IS NULL AND last_day IS NULL)
    )
);

-- Une ligne par (fichier, jour, campagne, groupe, produit promu) d'un rapport Advertised product.
-- Mesures : quantités additives seulement ; NULL = cellule vide, jamais remplacée par 0. Coût, ventes et redevances
-- en euros (devise imposée par l'extraction).
CREATE TABLE staging.ads_product_day (
    ads_report_file_id    bigint NOT NULL,
    extract_run_id        bigint NOT NULL,
    day                   date NOT NULL,
    campaign_id           text NOT NULL CONSTRAINT ads_product_day_campaign_ck CHECK (campaign_id <> ''),
    ad_group_id           text NOT NULL CONSTRAINT ads_product_day_ad_group_ck CHECK (ad_group_id <> ''),
    advertised_product_id text NOT NULL CONSTRAINT ads_product_day_product_ck CHECK (advertised_product_id <> ''),
    campaign_name_code    bigint,
    ad_group_name_code    bigint,
    product_title_code    bigint,
    impressions           bigint CONSTRAINT ads_product_day_impressions_ck CHECK (impressions >= 0),
    clicks                bigint CONSTRAINT ads_product_day_clicks_ck CHECK (clicks >= 0),
    cost                  numeric(14,5) CONSTRAINT ads_product_day_cost_ck CHECK (cost >= 0),
    purchases             bigint CONSTRAINT ads_product_day_purchases_ck CHECK (purchases >= 0),
    sales                 numeric(14,5) CONSTRAINT ads_product_day_sales_ck CHECK (sales >= 0),
    units_sold            bigint CONSTRAINT ads_product_day_units_ck CHECK (units_sold >= 0),
    kenp_pages            bigint CONSTRAINT ads_product_day_kenp_ck CHECK (kenp_pages >= 0),
    borrows               bigint CONSTRAINT ads_product_day_borrows_ck CHECK (borrows >= 0),
    royalties             numeric(14,5) CONSTRAINT ads_product_day_royalties_ck CHECK (royalties >= 0),
    CONSTRAINT ads_product_day_pk PRIMARY KEY (ads_report_file_id, day, campaign_id, ad_group_id, advertised_product_id),
    -- Jamais deux versions mélangées pour un fichier (comme staging.ranking_entry)
    CONSTRAINT ads_product_day_extraction_fk FOREIGN KEY (ads_report_file_id, extract_run_id)
        REFERENCES staging.ads_file_extraction (ads_report_file_id, extract_run_id)
);

-- Une ligne par (fichier, jour, campagne, groupe, ID cible, type de correspondance, terme) d'un rapport Search term.
-- Le terme fait partie du grain par son code (unique par texte, décision 019).
CREATE TABLE staging.ads_search_term_day (
    ads_report_file_id bigint NOT NULL,
    extract_run_id     bigint NOT NULL,
    day                date NOT NULL,
    campaign_id        text NOT NULL CONSTRAINT ads_search_term_day_campaign_ck CHECK (campaign_id <> ''),
    ad_group_id        text NOT NULL CONSTRAINT ads_search_term_day_ad_group_ck CHECK (ad_group_id <> ''),
    target_id          text NOT NULL CONSTRAINT ads_search_term_day_target_ck CHECK (target_id <> ''),
    -- Énumérations d'Amazon (« Type de cible », « Type de correspondance associé au ciblage »), gardées telles quelles
    target_type        text,
    match_type         text NOT NULL CONSTRAINT ads_search_term_day_match_type_ck CHECK (match_type <> ''),
    search_term_code   bigint NOT NULL,
    targeting_code     bigint,
    campaign_name_code bigint,
    ad_group_name_code bigint,
    impressions        bigint CONSTRAINT ads_search_term_day_impressions_ck CHECK (impressions >= 0),
    clicks             bigint CONSTRAINT ads_search_term_day_clicks_ck CHECK (clicks >= 0),
    cost               numeric(14,5) CONSTRAINT ads_search_term_day_cost_ck CHECK (cost >= 0),
    purchases          bigint CONSTRAINT ads_search_term_day_purchases_ck CHECK (purchases >= 0),
    sales              numeric(14,5) CONSTRAINT ads_search_term_day_sales_ck CHECK (sales >= 0),
    units_sold         bigint CONSTRAINT ads_search_term_day_units_ck CHECK (units_sold >= 0),
    kenp_pages         bigint CONSTRAINT ads_search_term_day_kenp_ck CHECK (kenp_pages >= 0),
    borrows            bigint CONSTRAINT ads_search_term_day_borrows_ck CHECK (borrows >= 0),
    royalties          numeric(14,5) CONSTRAINT ads_search_term_day_royalties_ck CHECK (royalties >= 0),
    CONSTRAINT ads_search_term_day_pk
        PRIMARY KEY (ads_report_file_id, day, campaign_id, ad_group_id, target_id, match_type, search_term_code),
    CONSTRAINT ads_search_term_day_extraction_fk FOREIGN KEY (ads_report_file_id, extract_run_id)
        REFERENCES staging.ads_file_extraction (ads_report_file_id, extract_run_id)
);

COMMENT ON COLUMN staging.ads_product_day.campaign_name_code IS
    'Code (mapping.text_code, nature campaign) du nom observé ce jour-là. Observation, pas identité : regrouper '
    'par campaign_id, jamais par ce code (un renommage change le code).';
COMMENT ON COLUMN staging.ads_search_term_day.campaign_name_code IS
    'Code (mapping.text_code, nature campaign) du nom observé ce jour-là. Observation, pas identité : regrouper '
    'par campaign_id, jamais par ce code (un renommage change le code).';

-- Source de chaque jour, pour chaque type (décision 018, section 6, notes du 5 novembre 2026). Un export, ce sont les
-- fichiers de même date d'export ; sa couverture est la réunion des bornes de ses fichiers extraits ok. Pour chaque
-- jour et chaque type, l'emporte l'export le plus récent qui contient un fichier de CE type au statut ok ou
-- no_activity, et dont la couverture inclut ce jour. Un fichier no_activity est une observation d'absence : il
-- l'emporte, sans ligne. Un export sans fichier d'un type n'observe rien de ce type : il ne masque jamais un export
-- plus ancien qui en avait un. Deux fichiers du même type et de même date d'export : le plus récent par l'heure
-- (puis par l'ordre d'ingestion). Un jour sans aucune ligne pour un type n'a donc pas de source.
CREATE VIEW staging.ads_day_source WITH (security_invoker = true) AS
WITH observed AS (
    SELECT f.id, f.report_type, f.export_date, f.export_time, e.status, e.first_day, e.last_day
      FROM raw.ads_report_file f
      JOIN staging.ads_file_extraction e ON e.ads_report_file_id = f.id
     WHERE f.status = 'ok' AND e.status IN ('ok', 'no_activity')
), covered AS (
    -- Seuls les fichiers ok ont des bornes : un fichier no_activity ne couvre aucun jour à lui seul
    SELECT DISTINCT o.export_date, d::date AS day
      FROM observed o, generate_series(o.first_day, o.last_day, interval '1 day') AS d
     WHERE o.status = 'ok'
), chosen AS (
    SELECT DISTINCT ON (export_date, report_type) export_date, report_type, id
      FROM observed ORDER BY export_date, report_type, export_time DESC, id DESC
)
SELECT DISTINCT ON (c.day, ch.report_type) c.day, ch.report_type, ch.export_date, ch.id AS file_id
  FROM covered c
  JOIN chosen ch ON ch.export_date = c.export_date
 ORDER BY c.day, ch.report_type, ch.export_date DESC;

-- Meilleure estimation de chaque jour : les lignes du fichier retenu pour ce jour et ce type, et seulement elles
CREATE VIEW staging.ads_product_day_best WITH (security_invoker = true) AS
SELECT p.*, s.export_date
  FROM staging.ads_product_day p
  JOIN staging.ads_day_source s
    ON s.day = p.day AND s.report_type = 'advertised_product' AND s.file_id = p.ads_report_file_id;

CREATE VIEW staging.ads_search_term_day_best WITH (security_invoker = true) AS
SELECT t.*, s.export_date
  FROM staging.ads_search_term_day t
  JOIN staging.ads_day_source s
    ON s.day = t.day AND s.report_type = 'search_term' AND s.file_id = t.ads_report_file_id;

-- books_transformer : lecture des fichiers RAW de rapports (le lot B l'accorde, décision 018) ; dans STAGING,
-- ajout et suppression des lignes, remplacement limité de la ligne d'extraction, clôture limitée de l'exécution ;
-- lecture des vues (contrôles du bilan). La séquence d'identité n'exige aucun droit : INSERT suffit.
GRANT SELECT ON raw.ads_report_file TO books_transformer;
GRANT SELECT, INSERT ON staging.ads_extract_run TO books_transformer;
GRANT UPDATE (finished_at, status, files_ok, files_no_activity, files_failed, notes)
    ON staging.ads_extract_run TO books_transformer;
GRANT SELECT, INSERT ON staging.ads_file_extraction TO books_transformer;
GRANT UPDATE (extract_run_id, status, error_message, row_count, first_day, last_day, unknown_columns, extracted_at)
    ON staging.ads_file_extraction TO books_transformer;
GRANT SELECT, INSERT, DELETE ON staging.ads_product_day, staging.ads_search_term_day TO books_transformer;
GRANT SELECT ON staging.ads_day_source, staging.ads_product_day_best, staging.ads_search_term_day_best
    TO books_transformer;
-- Aucun droit pour books_collector, books_reader (décision 018, hors périmètre) ni PUBLIC.

INSERT INTO public.schema_migration (version, description)
VALUES (12, 'Rapports Amazon Ads dans STAGING : extraction, lignes journalières, meilleure estimation (décision 018, lot B)');

COMMIT;
