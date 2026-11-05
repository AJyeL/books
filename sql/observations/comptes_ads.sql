-- Comptes des rapports Amazon Ads dans RAW et STAGING (décision 018), pour comparer deux bases (décision 009 :
-- restauration d'essai d'une sauvegarde). books_reader n'a aucun droit sur ces tables : à lancer par le PROPRIÉTAIRE,
-- sur atlas comme sur une base restaurée :
--   docker compose exec -T postgres sh -c 'psql -X -At -F " | " -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < sql/observations/comptes_ads.sql
-- Ne rend que des comptes : ni nom de fichier, ni empreinte, ni motif. Migrations 11 et 12 supposées appliquées.

SELECT '01 raw.ads_ingest_run', count(*)::text FROM raw.ads_ingest_run
UNION ALL SELECT '02 raw.ads_ingest_run ' || status, count(*)::text FROM raw.ads_ingest_run GROUP BY status
UNION ALL SELECT '03 raw.ads_report_file', count(*)::text FROM raw.ads_report_file
UNION ALL SELECT '04 raw.ads_report_file ' || coalesce(report_type, 'type inconnu') || ' ' || status, count(*)::text
  FROM raw.ads_report_file GROUP BY report_type, status
UNION ALL SELECT '05 staging.ads_extract_run', count(*)::text FROM staging.ads_extract_run
UNION ALL SELECT '06 staging.ads_file_extraction ' || status, count(*)::text FROM staging.ads_file_extraction GROUP BY status
UNION ALL SELECT '07 staging.ads_product_day', count(*)::text FROM staging.ads_product_day
UNION ALL SELECT '08 staging.ads_search_term_day', count(*)::text FROM staging.ads_search_term_day
UNION ALL SELECT '09 staging.ads_day_source', count(*)::text FROM staging.ads_day_source
UNION ALL SELECT '10 staging.ads_product_day_best', count(*)::text FROM staging.ads_product_day_best
UNION ALL SELECT '11 staging.ads_search_term_day_best', count(*)::text FROM staging.ads_search_term_day_best
ORDER BY 1;
