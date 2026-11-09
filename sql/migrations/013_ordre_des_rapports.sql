-- Migration 013 : ordre des rapports Amazon Ads par leurs données, et non par leur nom (décision 018, note du
-- 9 novembre 2026). À appliquer par le propriétaire de la base, toutes les migrations 001 à 012 appliquées.
--
-- Hypothèse réfutée : l'horodatage du nom d'un rapport n'est pas sa date d'export. C'est le nom du rapport, proposé par
-- défaut à l'ouverture du formulaire d'Amazon Ads et modifiable par l'utilisateur ; un rapport programmé garde ce nom à
-- chaque livraison. Il ne sert donc plus à rien : ni au verdict de RAW, ni à l'ordre des rapports.
-- 1. RAW : un fichier ok n'exige plus de date d'export (le nom n'est plus jugé). Aucune donnée RAW n'est modifiée :
--    seule la contrainte est assouplie, et les colonnes reçoivent un commentaire qui documente leur vrai sens.
-- 2. STAGING : les vues de meilleure estimation ordonnent les fichiers par la dernière date de leurs données, puis par
--    leur horodatage d'ingestion. La migration 012, déployée, n'est pas modifiée : ses vues sont remplacées ici.

BEGIN;

-- Garde-fou : migration appliquée dans l'ordre
DO $$
BEGIN
    IF (SELECT max(version) FROM public.schema_migration) IS DISTINCT FROM 12 THEN
        RAISE EXCEPTION 'migration 013 : la dernière migration appliquée doit être la 12 (trouvé : %)',
            (SELECT max(version) FROM public.schema_migration);
    END IF;
END;
$$;

-- 1. RAW : verdict sans date d'export obligatoire. Toutes les lignes existantes respectent déjà la contrainte assouplie
-- (elle est moins exigeante que l'ancienne) ; elle est vérifiée sur elles à son ajout.
ALTER TABLE raw.ads_report_file DROP CONSTRAINT ads_report_file_verdict_ck;
ALTER TABLE raw.ads_report_file ADD CONSTRAINT ads_report_file_verdict_ck CHECK (
    (status = 'invalid' AND reason IS NOT NULL AND reason <> '')
 OR (status = 'ok' AND reason IS NULL AND report_type IS NOT NULL)
);

COMMENT ON COLUMN raw.ads_report_file.export_date IS
    'Date lue dans l''horodatage du nom du fichier, s''il est présent (mois puis jour), sinon NULL. Ce n''est PAS une '
    'date d''export : c''est le nom du rapport proposé par défaut à l''ouverture du formulaire d''Amazon Ads, modifiable, '
    'et identique à chaque livraison d''un rapport programmé. Pour mémoire seulement : aucun calcul ne l''utilise.';
COMMENT ON COLUMN raw.ads_report_file.export_time IS
    'Heure lue dans l''horodatage du nom du fichier (fuseau inconnu), s''il est présent, sinon NULL. Même sens que '
    'export_date : nom proposé par Amazon Ads, pas une heure d''export. Pour mémoire seulement.';

-- 2. STAGING : vues remplacées (leurs colonnes changent : export_date devient last_day)
DROP VIEW staging.ads_product_day_best, staging.ads_search_term_day_best, staging.ads_day_source;

-- Source de chaque jour, pour chaque type (décision 018, section 6, notes des 5 et 9 novembre 2026). Un export, ce sont
-- les fichiers extraits ok de même dernière date de données ; sa couverture est la réunion de leurs bornes. Pour chaque
-- jour et chaque type, l'emporte l'export le plus récent (par dernière date) qui contient un fichier de CE type et dont
-- la couverture inclut ce jour ; dans l'export, le fichier de ce type ingéré en dernier (puis par l'ordre d'ingestion).
-- Un jour couvert sans ligne dans le fichier retenu a pour meilleure estimation l'absence ; un export sans fichier d'un
-- type ne masque jamais un export plus ancien qui en avait un. Un fichier « aucune activité rapportée » n'a pas de
-- dates : il ne peut être placé dans le temps et ne l'emporte jamais. Le nom du fichier n'intervient pas.
CREATE VIEW staging.ads_day_source WITH (security_invoker = true) AS
WITH observed AS (
    SELECT f.id, f.report_type, f.ingested_at, e.first_day, e.last_day
      FROM raw.ads_report_file f
      JOIN staging.ads_file_extraction e ON e.ads_report_file_id = f.id
     WHERE f.status = 'ok' AND e.status = 'ok'
), covered AS (
    SELECT DISTINCT o.last_day AS export_last_day, d::date AS day
      FROM observed o, generate_series(o.first_day, o.last_day, interval '1 day') AS d
), chosen AS (
    SELECT DISTINCT ON (last_day, report_type) last_day, report_type, id
      FROM observed ORDER BY last_day, report_type, ingested_at DESC, id DESC
)
SELECT DISTINCT ON (c.day, ch.report_type) c.day, ch.report_type, ch.last_day, ch.id AS file_id
  FROM covered c
  JOIN chosen ch ON ch.last_day = c.export_last_day
 ORDER BY c.day, ch.report_type, ch.last_day DESC;

-- Meilleure estimation de chaque jour : les lignes du fichier retenu pour ce jour et ce type, et seulement elles ;
-- last_day : dernière date de données de l'export retenu
CREATE VIEW staging.ads_product_day_best WITH (security_invoker = true) AS
SELECT p.*, s.last_day
  FROM staging.ads_product_day p
  JOIN staging.ads_day_source s
    ON s.day = p.day AND s.report_type = 'advertised_product' AND s.file_id = p.ads_report_file_id;

CREATE VIEW staging.ads_search_term_day_best WITH (security_invoker = true) AS
SELECT t.*, s.last_day
  FROM staging.ads_search_term_day t
  JOIN staging.ads_day_source s
    ON s.day = t.day AND s.report_type = 'search_term' AND s.file_id = t.ads_report_file_id;

-- Mêmes droits que les vues de la migration 012 : books_transformer seulement (contrôles du bilan)
GRANT SELECT ON staging.ads_day_source, staging.ads_product_day_best, staging.ads_search_term_day_best
    TO books_transformer;
-- Aucun droit pour books_collector, books_reader (décision 018, hors périmètre) ni PUBLIC.

INSERT INTO public.schema_migration (version, description)
VALUES (13, 'Rapports Amazon Ads : ordre par les données, nom non jugé, vues de meilleure estimation remplacées');

COMMIT;
