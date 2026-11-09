-- Empreinte du contenu de CORE, pour comparer deux bases (décision 020 ; restauration d'essai, décision 009).
-- Lecture seule, à lancer sous books_reader (décision 016), sur atlas comme sur une base restaurée :
--   docker compose exec -T postgres sh -c 'psql -X -At -F " | " -U books_reader -d "$POSTGRES_DB"' < sql/observations/empreinte_core.sql
-- Ne rend que des comptes et des empreintes md5 : aucune donnée lisible. Le journal core.build_run n'est pas
-- reconstructible (il compte les constructions) : seul son nombre de lignes et la dernière version sont rendus.
-- Fuseau et format des dates fixés : l'empreinte ne dépend pas des réglages de la session.

SET TIME ZONE 'UTC';
SET datestyle = 'ISO, YMD';

SELECT '1 core.book', count(*) || ' | ' || md5(coalesce(string_agg(t::text, ';' ORDER BY t.asin), ''))
  FROM core.book t
UNION ALL
SELECT '2 core.category', count(*) || ' | '
       || md5(coalesce(string_agg(t::text, ';' ORDER BY t.source, t.category_node), ''))
  FROM core.category t
UNION ALL
SELECT '3 core.category_name', count(*) || ' | '
       || md5(coalesce(string_agg(t::text, ';' ORDER BY t.source, t.category_node, t.name_kind, t.first_raw_page_id), ''))
  FROM core.category_name t
UNION ALL
SELECT '4 core.list_day', count(*) || ' | '
       || md5(coalesce(string_agg(t::text, ';' ORDER BY t.source, t.category_node, t.list_type, t.day), ''))
  FROM core.list_day t
UNION ALL
SELECT '5 core.ranking_day', count(*) || ' | '
       || md5(coalesce(string_agg(t::text, ';' ORDER BY t.asin, t.source, t.category_node, t.list_type, t.day), ''))
  FROM core.ranking_day t
UNION ALL
SELECT '6 core.build_run (constructions | dernière version de CORE / de l''extracteur)',
       count(*) || ' | ' || coalesce((SELECT b.core_version || ' / ' || b.extractor_version
                                        FROM core.build_run b ORDER BY b.id DESC LIMIT 1), 'aucune')
  FROM core.build_run
ORDER BY 1;
