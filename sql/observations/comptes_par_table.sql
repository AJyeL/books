-- Comptes de lignes par table, pour comparer deux bases (décision 009 : restauration d'essai d'une sauvegarde).
-- Lecture seule, à lancer sous books_reader (décision 016), sur atlas comme sur une base restaurée :
--   docker compose exec -T postgres sh -c 'psql -X -At -F " | " -U books_reader -d "$POSTGRES_DB"' < sql/observations/comptes_par_table.sql
-- Ne rend que des comptes : aucune donnée, aucun ASIN, aucun nom. Toutes les migrations supposées appliquées (1 à 15).
-- guide.export_document est exclu : sa date d'export change à chaque lecture.

SELECT '01 migrations (nombre | versions)', count(*) || ' | ' || string_agg(version::text, ' ' ORDER BY version)
  FROM public.schema_migration
UNION ALL SELECT '02 raw.collect_run', count(*)::text FROM raw.collect_run
UNION ALL SELECT '03 raw.raw_page', count(id)::text FROM raw.raw_page
UNION ALL SELECT '04 raw.raw_page ' || page_type || ' ' || fetch_status, count(id)::text
  FROM raw.raw_page GROUP BY page_type, fetch_status
UNION ALL SELECT '05 staging.extract_run', count(*)::text FROM staging.extract_run
UNION ALL SELECT '06 staging.page_extraction', count(*)::text FROM staging.page_extraction
UNION ALL SELECT '07 staging.page_extraction ' || status, count(*)::text FROM staging.page_extraction GROUP BY status
UNION ALL SELECT '08 staging.ranking_entry', count(*)::text FROM staging.ranking_entry
UNION ALL SELECT '09 staging.category_observation', count(*)::text FROM staging.category_observation
UNION ALL SELECT '10 staging.product_observation', count(*)::text FROM staging.product_observation
UNION ALL SELECT '11 staging.product_format', count(*)::text FROM staging.product_format
UNION ALL SELECT '12 staging.product_sales_rank', count(*)::text FROM staging.product_sales_rank
UNION ALL SELECT '13 staging.product_rating_share', count(*)::text FROM staging.product_rating_share
UNION ALL SELECT '14 guide.reference_entry', count(*)::text FROM guide.reference_entry
UNION ALL SELECT '15 guide.kindle_product', count(*)::text FROM guide.kindle_product
UNION ALL SELECT '16 core.build_run', count(*)::text FROM core.build_run
UNION ALL SELECT '17 core.book', count(*)::text FROM core.book
UNION ALL SELECT '18 core.category', count(*)::text FROM core.category
UNION ALL SELECT '19 core.category_name', count(*)::text FROM core.category_name
UNION ALL SELECT '20 core.list_day', count(*)::text FROM core.list_day
UNION ALL SELECT '21 core.ranking_day', count(*)::text FROM core.ranking_day
UNION ALL SELECT '22 core.book_title_version', count(*)::text FROM core.book_title_version
UNION ALL SELECT '23 core.book_cover_version', count(*)::text FROM core.book_cover_version
UNION ALL SELECT '24 core.book_description_version', count(*)::text FROM core.book_description_version
UNION ALL SELECT '25 core.book_description_markup_version', count(*)::text FROM core.book_description_markup_version
UNION ALL SELECT '26 core.book_series_version', count(*)::text FROM core.book_series_version
UNION ALL SELECT '27 core.book_print_pages_version', count(*)::text FROM core.book_print_pages_version
UNION ALL SELECT '28 core.book_aplus_version', count(*)::text FROM core.book_aplus_version
UNION ALL SELECT '29 core.book_publication_date_version', count(*)::text FROM core.book_publication_date_version
UNION ALL SELECT '30 core.book_language_version', count(*)::text FROM core.book_language_version
UNION ALL SELECT '31 core.book_file_size_version', count(*)::text FROM core.book_file_size_version
UNION ALL SELECT '32 core.product_day', count(*)::text FROM core.product_day
UNION ALL SELECT '33 core.product_day_category_rank', count(*)::text FROM core.product_day_category_rank
ORDER BY 1;
