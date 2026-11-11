-- Empreinte du contenu de CORE, pour comparer deux bases (décisions 020 et 021 ; restauration d'essai, décision 009).
-- Lecture seule, à lancer sous books_reader (décision 016), sur atlas comme sur une base restaurée :
--   docker compose exec -T postgres sh -c 'psql -X -At -F " | " -U books_reader -d "$POSTGRES_DB"' < sql/observations/empreinte_core.sql
-- Ne rend que des comptes et des empreintes md5 : aucune donnée lisible. Le journal core.build_run n'est pas
-- reconstructible (il compte les constructions) : seul son nombre de lignes et la dernière version sont rendus.
-- La vue core.book_current est exclue : elle se déduit des tables.
-- Fuseau et format des dates fixés : l'empreinte ne dépend pas des réglages de la session.

SET TIME ZONE 'UTC';
SET datestyle = 'ISO, YMD';

SELECT '01 core.book', count(*) || ' | '
       || md5(coalesce(string_agg(t::text, ';' ORDER BY t.asin), ''))
  FROM core.book t
UNION ALL
SELECT '02 core.category', count(*) || ' | '
       || md5(coalesce(string_agg(t::text, ';' ORDER BY t.source, t.category_node), ''))
  FROM core.category t
UNION ALL
SELECT '03 core.category_name', count(*) || ' | '
       || md5(coalesce(string_agg(t::text, ';' ORDER BY t.source, t.category_node, t.name_kind, t.first_raw_page_id), ''))
  FROM core.category_name t
UNION ALL
SELECT '04 core.list_day', count(*) || ' | '
       || md5(coalesce(string_agg(t::text, ';' ORDER BY t.source, t.category_node, t.list_type, t.day), ''))
  FROM core.list_day t
UNION ALL
SELECT '05 core.ranking_day', count(*) || ' | '
       || md5(coalesce(string_agg(t::text, ';' ORDER BY t.asin, t.source, t.category_node, t.list_type, t.day), ''))
  FROM core.ranking_day t
UNION ALL
SELECT '06 core.book_title_version', count(*) || ' | '
       || md5(coalesce(string_agg(t::text, ';' ORDER BY t.asin, t.first_raw_page_id), ''))
  FROM core.book_title_version t
UNION ALL
SELECT '07 core.book_cover_version', count(*) || ' | '
       || md5(coalesce(string_agg(t::text, ';' ORDER BY t.asin, t.first_raw_page_id), ''))
  FROM core.book_cover_version t
UNION ALL
SELECT '08 core.book_description_version', count(*) || ' | '
       || md5(coalesce(string_agg(t::text, ';' ORDER BY t.asin, t.first_raw_page_id), ''))
  FROM core.book_description_version t
UNION ALL
SELECT '09 core.book_description_markup_version', count(*) || ' | '
       || md5(coalesce(string_agg(t::text, ';' ORDER BY t.asin, t.first_raw_page_id), ''))
  FROM core.book_description_markup_version t
UNION ALL
SELECT '10 core.book_series_version', count(*) || ' | '
       || md5(coalesce(string_agg(t::text, ';' ORDER BY t.asin, t.first_raw_page_id), ''))
  FROM core.book_series_version t
UNION ALL
SELECT '11 core.book_print_pages_version', count(*) || ' | '
       || md5(coalesce(string_agg(t::text, ';' ORDER BY t.asin, t.first_raw_page_id), ''))
  FROM core.book_print_pages_version t
UNION ALL
SELECT '12 core.book_aplus_version', count(*) || ' | '
       || md5(coalesce(string_agg(t::text, ';' ORDER BY t.asin, t.first_raw_page_id), ''))
  FROM core.book_aplus_version t
UNION ALL
SELECT '13 core.book_publication_date_version', count(*) || ' | '
       || md5(coalesce(string_agg(t::text, ';' ORDER BY t.asin, t.first_raw_page_id), ''))
  FROM core.book_publication_date_version t
UNION ALL
SELECT '14 core.book_language_version', count(*) || ' | '
       || md5(coalesce(string_agg(t::text, ';' ORDER BY t.asin, t.first_raw_page_id), ''))
  FROM core.book_language_version t
UNION ALL
SELECT '15 core.book_file_size_version', count(*) || ' | '
       || md5(coalesce(string_agg(t::text, ';' ORDER BY t.asin, t.first_raw_page_id), ''))
  FROM core.book_file_size_version t
UNION ALL
SELECT '16 core.product_day', count(*) || ' | '
       || md5(coalesce(string_agg(t::text, ';' ORDER BY t.asin, t.day), ''))
  FROM core.product_day t
UNION ALL
SELECT '17 core.product_day_category_rank', count(*) || ' | '
       || md5(coalesce(string_agg(t::text, ';' ORDER BY t.asin, t.day, t.position), ''))
  FROM core.product_day_category_rank t
UNION ALL
SELECT '18 core.build_run (constructions | dernière version de CORE / de l''extracteur)',
       count(*) || ' | ' || coalesce((SELECT b.core_version || ' / ' || b.extractor_version
                                        FROM core.build_run b ORDER BY b.id DESC LIMIT 1), 'aucune')
  FROM core.build_run
ORDER BY 1;
