-- Tests de la migration 001 : couche RAW
--
-- Lancement sur atlas, depuis le dossier du dépôt :
--   docker exec -i books-postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_001_couche_raw.sql
-- Ne pas ajouter -v ON_ERROR_STOP=1 : les erreurs sont attendues, psql doit continuer jusqu'au bout.
--
-- Résultats attendus :
--   - Test 1 : ERROR « La table raw_page est en ajout seul (append-only) »
--   - Test 2 : ERROR « La table raw_page est en ajout seul (append-only) »
--   - Test 3 : ERROR violation de la contrainte « raw_page_asin_check »
--   - Test 4 : ERROR violation de la contrainte « raw_page_content_ck »
--   - Vérification finale : runs_test = 0 et pages_test = 0, quelle que soit la quantité de vraies données
-- Chaque test est annulé par ROLLBACK : aucune donnée n'est conservée.

-- Test 1 : une suppression doit être refusée
BEGIN;
INSERT INTO raw.collect_run (collector_version) VALUES ('test');
INSERT INTO raw.raw_page (run_id, page_type, asin, requested_url, fetch_status)
  VALUES ((SELECT max(id) FROM raw.collect_run), 'product', 'B0F8VVKM5S', 'https://test', 'network_error');
DELETE FROM raw.raw_page;
ROLLBACK;

-- Test 2 : un vidage complet doit être refusé
BEGIN;
TRUNCATE raw.raw_page;
ROLLBACK;

-- Test 3 : un ASIN invalide doit être refusé
BEGIN;
INSERT INTO raw.collect_run (collector_version) VALUES ('test');
INSERT INTO raw.raw_page (run_id, page_type, asin, requested_url, fetch_status)
  VALUES ((SELECT max(id) FROM raw.collect_run), 'product', 'pas-un-asin', 'https://test', 'network_error');
ROLLBACK;

-- Test 4 : une collecte « ok » sans fichier doit être refusée
BEGIN;
INSERT INTO raw.collect_run (collector_version) VALUES ('test');
INSERT INTO raw.raw_page (run_id, page_type, asin, requested_url, fetch_status)
  VALUES ((SELECT max(id) FROM raw.collect_run), 'product', 'B0F8VVKM5S', 'https://test', 'ok');
ROLLBACK;

-- Vérification finale : aucune ligne créée par les tests ne doit subsister
SELECT (SELECT count(*) FROM raw.collect_run WHERE collector_version = 'test') AS runs_test,
       (SELECT count(*) FROM raw.raw_page WHERE requested_url = 'https://test') AS pages_test;
