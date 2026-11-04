-- Comptes de la correspondance des textes sensibles (décision 019), pour comparer deux bases (décision 009 :
-- restauration d'essai d'une sauvegarde). books_reader ne voit pas le schéma mapping : à lancer par le PROPRIÉTAIRE,
-- sur atlas comme sur une base restaurée :
--   docker compose exec -T postgres sh -c 'psql -X -At -F " | " -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < sql/observations/comptes_correspondance.sql
-- Ne rend que des nombres de lignes par nature : aucune clé, aucun code. Toutes les natures figurent, même à 0.
-- Migration 10 supposée appliquée.

SELECT 'mapping.text_code ' || n.nature, count(t.code)::text
  FROM mapping.nature n
  LEFT JOIN mapping.text_code t ON t.nature = n.nature
 GROUP BY n.nature
 ORDER BY 1;
