-- Migration 009 : guide de veille, schéma guide (décision 017, section 3)
-- À appliquer par le propriétaire de la base.
--
-- Trois vues, sans aucune donnée stockée, lues par books_reader (décision 016) pour l'export du guide
-- (scripts/exporter-guide.sh). security_invoker = true : une vue lit les tables avec les droits du rôle qui
-- l'interroge, et ne peut donc jamais lui montrer plus que ce qu'il lit déjà (ni les adresses de RAW, ni la future
-- correspondance de la décision 013).

BEGIN;

CREATE SCHEMA guide;

-- Référence de chaque liste : pour chaque page (1, 2), la dernière page extraite « ok » ; chaque ligne garde la date
-- de sa page ; un ASIN présent dans les deux pages de référence ne garde que sa ligne la plus récente.
CREATE VIEW guide.reference_entry WITH (security_invoker = true) AS
WITH latest_page AS (
    SELECT DISTINCT ON (rp.category_node, rp.list_type, rp.page_number)
           rp.id, rp.category_node, rp.list_type, rp.fetched_at
      FROM raw.raw_page rp
      JOIN staging.page_extraction pe ON pe.raw_page_id = rp.id AND pe.status = 'ok'
     WHERE rp.page_type = 'bestseller_list'
     ORDER BY rp.category_node, rp.list_type, rp.page_number, rp.fetched_at DESC, rp.id DESC
)
SELECT DISTINCT ON (lp.category_node, lp.list_type, re.asin)
       lp.category_node, lp.list_type, re.asin, re.rank, lp.fetched_at AS observed_at
  FROM latest_page lp
  JOIN staging.ranking_entry re ON re.raw_page_id = lp.id
 ORDER BY lp.category_node, lp.list_type, re.asin, lp.fetched_at DESC, lp.id DESC;

COMMENT ON VIEW guide.reference_entry IS
    'Dernière observation de chaque liste, page par page (décision 017, section 3) ; observed_at : date de la page.';

-- ASIN dont une fiche Kindle est extraite (statut ok) ; fiches papier (skipped), en échec ou refusées exclues
CREATE VIEW guide.kindle_product WITH (security_invoker = true) AS
SELECT rp.asin, max(rp.fetched_at) AS last_observed_at
  FROM raw.raw_page rp
  JOIN staging.page_extraction pe ON pe.raw_page_id = rp.id AND pe.status = 'ok'
 WHERE rp.page_type = 'product'
 GROUP BY rp.asin;

COMMENT ON VIEW guide.kindle_product IS
    'ASIN dont une fiche Kindle est extraite (décision 017, section 3) ; fiches papier, en échec et refusées exclues.';

-- Document JSON exporté (décision 017, section 4) : une ligne. json (et non jsonb) : l'ordre des clés est conservé.
CREATE VIEW guide.export_document WITH (security_invoker = true) AS
SELECT json_build_object(
    'schema_version', 1,
    'generated_at', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'lists', coalesce((
        SELECT json_agg(json_build_object('category_node', l.category_node, 'list_type', l.list_type,
                                          'entries', l.entries)
                        ORDER BY l.category_node, l.list_type)
          FROM (SELECT r.category_node, r.list_type,
                       json_agg(json_build_object(
                           'asin', r.asin, 'rank', r.rank,
                           'observed_at', to_char(r.observed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
                           ORDER BY r.rank) AS entries
                  FROM guide.reference_entry r
                 GROUP BY r.category_node, r.list_type) AS l), '[]'::json),
    'kindle_asins', coalesce((SELECT json_agg(k.asin ORDER BY k.asin) FROM guide.kindle_product k), '[]'::json)
) AS document;

COMMENT ON VIEW guide.export_document IS
    'Document du guide de veille, format version 1 (décision 017, section 4).';

-- Lecture par books_reader seulement ; liste attendue du test 008 mise à jour dans le même commit (décision 016)
GRANT USAGE ON SCHEMA guide TO books_reader;
GRANT SELECT ON guide.reference_entry, guide.kindle_product, guide.export_document TO books_reader;

INSERT INTO public.schema_migration (version, description)
VALUES (9, 'Guide de veille : schéma guide, vues lues par books_reader');

COMMIT;
