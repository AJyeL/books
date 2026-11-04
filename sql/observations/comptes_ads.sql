-- Comptes des rapports Amazon Ads dans RAW (décision 018), pour comparer deux bases (décision 009 : restauration
-- d'essai d'une sauvegarde). books_reader n'a aucun droit sur ces tables : à lancer par le PROPRIÉTAIRE,
-- sur atlas comme sur une base restaurée :
--   docker compose exec -T postgres sh -c 'psql -X -At -F " | " -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < sql/observations/comptes_ads.sql
-- Ne rend que des comptes : ni nom de fichier, ni empreinte, ni motif. Migration 11 supposée appliquée.

SELECT '01 raw.ads_ingest_run', count(*)::text FROM raw.ads_ingest_run
UNION ALL SELECT '02 raw.ads_ingest_run ' || status, count(*)::text FROM raw.ads_ingest_run GROUP BY status
UNION ALL SELECT '03 raw.ads_report_file', count(*)::text FROM raw.ads_report_file
UNION ALL SELECT '04 raw.ads_report_file ' || coalesce(report_type, 'type inconnu') || ' ' || status, count(*)::text
  FROM raw.ads_report_file GROUP BY report_type, status
ORDER BY 1;
