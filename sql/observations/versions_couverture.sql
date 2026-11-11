-- Distribution du nombre de versions de couverture par livre (décision 021, question 3 : adresse de couverture non
-- normalisée ; ce relevé dira si des versions « de bruit » apparaissent).
-- Lecture seule, à lancer sous books_reader (décision 016), après le déploiement de la migration 015 et un passage de
-- l'extracteur :
--   docker compose exec -T postgres sh -c 'psql -X -At -F " | " -U books_reader -d "$POSTGRES_DB"' < sql/observations/versions_couverture.sql
-- Ne rend que des comptes : aucun ASIN, aucune adresse. Une ligne par nombre de versions : livres concernés, et
-- fiches observées par ces livres (une seule fiche ne peut donner qu'une version).

SELECT v.versions || ' version(s)' AS versions_par_livre,
       count(*) || ' livre(s)' AS livres,
       sum(v.observations) || ' observation(s) de couverture' AS observations
  FROM (SELECT asin, count(*) AS versions, sum(observations) AS observations
          FROM core.book_cover_version
         GROUP BY asin) v
 GROUP BY v.versions
UNION ALL
SELECT 'aucune version (fiche sans couverture lue)',
       count(*) || ' livre(s)', '-'
  FROM core.book b
 WHERE b.first_product_day IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM core.book_cover_version c WHERE c.asin = b.asin)
ORDER BY 1;
