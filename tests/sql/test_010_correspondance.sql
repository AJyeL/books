-- Tests de la migration 010 : correspondance des textes sensibles, schéma mapping (décision 019)
--
-- À exécuter EN TANT QUE PROPRIÉTAIRE de la base, depuis le dossier du dépôt (bash), toutes les migrations appliquées :
--   docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < tests/sql/test_010_correspondance.sql
-- Même principe que test_008 : le propriétaire relève le catalogue et prépare les pièges, puis endosse
-- books_transformer, books_reader et books_collector (SET LOCAL ROLE). Les clés sont inventées et contiennent toutes
-- « Sentinelle » : aucun contrôle ne suppose la table vide ni une valeur de code précise (une séquence n'est pas
-- annulée par ROLLBACK). Les appels concurrents sont testés à part, en Python (test_correspondance_concurrence.py).
-- Tout se déroule dans une transaction annulée par ROLLBACK : aucune donnée ni aucun objet n'est conservé.

BEGIN;

-- Refus attendu : code d'erreur, et message qui ne recopie jamais une clé de test
CREATE FUNCTION pg_temp.expect_refusal(num int, label text, sql text, state text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    accepted boolean := false;
    got_state text;
    got_message text;
    got_detail text;
BEGIN
    BEGIN
        EXECUTE sql;
        accepted := true;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS got_state = RETURNED_SQLSTATE, got_message = MESSAGE_TEXT, got_detail = PG_EXCEPTION_DETAIL;
    END;
    IF accepted THEN
        RAISE EXCEPTION 'ÉCHEC test % : % accepté alors qu''il devait être refusé', num, label;
    END IF;
    IF got_state <> state THEN
        RAISE EXCEPTION 'ÉCHEC test % : % refusé par % (%) au lieu de %', num, label, got_state, got_message, state;
    END IF;
    IF got_message ILIKE '%sentinelle%' OR coalesce(got_detail, '') ILIKE '%sentinelle%' THEN
        RAISE EXCEPTION 'ÉCHEC test % : % : le message d''erreur recopie la clé', num, label;
    END IF;
    RAISE NOTICE 'OK test % : % refusé (%)', num, label, got_message;
END;
$$;

-- Codes obtenus par books_transformer, relus par le propriétaire (TEMPORARY est retiré à PUBLIC : le propriétaire
-- crée la table et l'accorde)
CREATE TEMP TABLE test_codes (label text PRIMARY KEY, code bigint) ON COMMIT DROP;
GRANT SELECT, INSERT ON test_codes TO books_transformer;

DO $$
BEGIN
    IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : connecté en tant que %, le propriétaire (superutilisateur) est attendu', current_user;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.schema_migration WHERE version = 10) THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : migration 10 absente de schema_migration';
    END IF;
    IF EXISTS (SELECT 1 FROM mapping.text_code WHERE key ILIKE '%sentinelle%') THEN
        RAISE EXCEPTION 'ÉCHEC test 0 : des clés de test sont déjà présentes dans mapping.text_code';
    END IF;
    RAISE NOTICE 'OK test 0 : propriétaire, migration 10 présente, aucune clé de test préexistante';
END;
$$;

-- ============================================================================================================
-- Test 1 : catalogue (propriété, rôle dédié, fonction, droits)
-- ============================================================================================================
DO $$
DECLARE
    got text;
BEGIN
    -- Propriété : schéma, tables, séquence et fonction appartiennent à books_mapping
    SELECT string_agg(o, ', ' ORDER BY o) INTO got FROM (
        SELECT 'schéma ' || nspname AS o FROM pg_namespace
         WHERE nspname = 'mapping' AND nspowner <> 'books_mapping'::regrole
        UNION ALL
        SELECT c.relname FROM pg_class c
         WHERE c.relnamespace = 'mapping'::regnamespace AND c.relkind IN ('r', 'S', 'i')
           AND c.relowner <> 'books_mapping'::regrole
        UNION ALL
        SELECT p.proname FROM pg_proc p
         WHERE p.pronamespace = 'mapping'::regnamespace AND p.proowner <> 'books_mapping'::regrole) x;
    IF got IS NOT NULL THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : objets de mapping qui n''appartiennent pas à books_mapping : %', got;
    END IF;
    SELECT string_agg(c.relname || '/' || c.relkind::text, ', ' ORDER BY c.relname) INTO got
      FROM pg_class c WHERE c.relnamespace = 'mapping'::regnamespace AND c.relkind IN ('r', 'S', 'v', 'm');
    IF got IS DISTINCT FROM 'nature/r, text_code/r, text_code_code_seq/S' THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : contenu du schéma mapping : % (attendu : nature, text_code et sa séquence)', got;
    END IF;

    -- Rôle dédié : sans connexion, sans attribut, sans membre, membre d'aucun rôle
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'books_mapping'
                AND (rolcanlogin OR rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls))
       OR EXISTS (SELECT 1 FROM pg_auth_members
                   WHERE roleid = 'books_mapping'::regrole OR member = 'books_mapping'::regrole) THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : books_mapping a un attribut, un membre ou une appartenance';
    END IF;

    -- Fonction : SECURITY DEFINER, search_path figé avec pg_temp en dernier, non STRICT, résultat bigint
    IF NOT EXISTS (SELECT 1 FROM pg_proc
                    WHERE oid = 'mapping.code_for(text, text)'::regprocedure
                      AND prosecdef AND NOT proisstrict
                      AND proconfig = ARRAY['search_path=pg_catalog, pg_temp']
                      AND prorettype = 'bigint'::regtype) THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : mapping.code_for n''a pas les attributs attendus';
    END IF;

    -- Exécution : books_mapping (propriétaire) et books_transformer seulement ; jamais PUBLIC
    SELECT string_agg(g, ', ' ORDER BY g) INTO got FROM (
        SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS g
          FROM pg_proc p, aclexplode(p.proacl) a
         WHERE p.oid = 'mapping.code_for(text, text)'::regprocedure AND a.privilege_type = 'EXECUTE') x;
    IF got IS DISTINCT FROM 'books_mapping, books_transformer' THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : droit d''exécution de mapping.code_for : % (attendu : books_mapping, books_transformer)', got;
    END IF;

    -- Tables et séquence : aucun droit accordé à qui que ce soit d'autre que le propriétaire
    SELECT string_agg(c.relname || ' → ' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END,
                      ', ') INTO got
      FROM pg_class c, aclexplode(c.relacl) a
     WHERE c.relnamespace = 'mapping'::regnamespace AND a.grantee <> c.relowner;
    IF got IS NOT NULL THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : droits sur les tables de mapping : %', got;
    END IF;

    -- Schéma : usage accordé au seul books_transformer
    SELECT string_agg(g, ', ' ORDER BY g) INTO got FROM (
        SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END || ':' || a.privilege_type AS g
          FROM pg_namespace n, aclexplode(n.nspacl) a
         WHERE n.nspname = 'mapping' AND a.grantee <> n.nspowner) x;
    IF got IS DISTINCT FROM 'books_transformer:USAGE' THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : droits sur le schéma mapping : % (attendu : books_transformer:USAGE)', got;
    END IF;

    -- Natures prévues
    SELECT string_agg(nature, ', ' ORDER BY nature) INTO got FROM mapping.nature;
    IF got IS DISTINCT FROM 'ad_group, author, campaign, product_title, search_term, targeting' THEN
        RAISE EXCEPTION 'ÉCHEC test 1 : natures : %', got;
    END IF;
    RAISE NOTICE 'OK test 1 : objets de books_mapping (sans connexion ni membre), fonction SECURITY DEFINER à search_path figé, exécution réservée à books_transformer, aucun droit sur les tables, six natures';
END;
$$;

-- ============================================================================================================
-- Tests 2 à 6 : sous books_transformer
-- ============================================================================================================
SET LOCAL ROLE books_transformer;

-- Tests 2 à 5 : idempotence, natures distinctes, clé telle quelle, forme du code
INSERT INTO test_codes VALUES
    ('auteur 1',      mapping.code_for('author', 'Camille Sentinelle')),
    ('auteur 2',      mapping.code_for('author', 'Camille Sentinelle')),
    ('terme',         mapping.code_for('search_term', 'Camille Sentinelle')),
    ('minuscules',    mapping.code_for('author', 'camille sentinelle')),
    ('espace',        mapping.code_for('author', ' Camille Sentinelle')),
    ('court',         mapping.code_for('targeting', 'Sentinelle')),
    ('long',          mapping.code_for('product_title', 'Sentinelle ' || repeat('x', 1500)));

DO $$
BEGIN
    PERFORM pg_temp.expect_refusal(6, 'clé NULL', $q$SELECT mapping.code_for('author', NULL)$q$, '22004');
    PERFORM pg_temp.expect_refusal(6, 'clé vide', $q$SELECT mapping.code_for('author', '')$q$, '22023');
    PERFORM pg_temp.expect_refusal(6, 'clé faite d''espaces', $q$SELECT mapping.code_for('author', '   ')$q$, '22023');
    PERFORM pg_temp.expect_refusal(6, 'clé faite de séparateurs (tabulation, saut de ligne, U+00A0, U+202F)',
        $q$SELECT mapping.code_for('author', E'\t\r\n  ')$q$, '22023');
    PERFORM pg_temp.expect_refusal(6, 'clé de 2001 octets',
        $q$SELECT mapping.code_for('author', 'Sentinelle' || repeat('x', 1991))$q$, '22023');
    PERFORM pg_temp.expect_refusal(6, 'clé de 1001 caractères mais 2001 octets (lettres accentuées)',
        $q$SELECT mapping.code_for('author', 'é' || repeat('é', 999) || 'x')$q$, '22023');
    PERFORM pg_temp.expect_refusal(6, 'nature NULL', $q$SELECT mapping.code_for(NULL, 'Camille Sentinelle')$q$, '22023');
    PERFORM pg_temp.expect_refusal(6, 'nature inconnue', $q$SELECT mapping.code_for('auteur', 'Camille Sentinelle')$q$, '22023');
    PERFORM pg_temp.expect_refusal(6, 'texte passé à la place de la nature',
        $q$SELECT mapping.code_for('Camille Sentinelle', 'author')$q$, '22023');
    -- Limite exacte : 2000 octets acceptés
    IF mapping.code_for('author', 'Sentinelle' || repeat('x', 1990)) IS NULL THEN
        RAISE EXCEPTION 'ÉCHEC test 6 : clé de 2000 octets refusée';
    END IF;
    RAISE NOTICE 'OK test 6 : clé de 2000 octets acceptée';
END;
$$;

RESET ROLE;

DO $$
DECLARE
    c record;
BEGIN
    SELECT max(code) FILTER (WHERE label = 'auteur 1') AS a1, max(code) FILTER (WHERE label = 'auteur 2') AS a2,
           max(code) FILTER (WHERE label = 'terme') AS t, max(code) FILTER (WHERE label = 'minuscules') AS m,
           max(code) FILTER (WHERE label = 'espace') AS e, count(*) FILTER (WHERE code IS NULL) AS nuls
      INTO c FROM test_codes;
    IF c.nuls > 0 THEN
        RAISE EXCEPTION 'ÉCHEC test 2 : code NULL rendu';
    END IF;
    IF c.a1 <> c.a2 OR (SELECT count(*) FROM mapping.text_code WHERE nature = 'author' AND key = 'Camille Sentinelle') <> 1 THEN
        RAISE EXCEPTION 'ÉCHEC test 2 : deux appels avec la même clé ne rendent pas un seul et même code';
    END IF;
    RAISE NOTICE 'OK test 2 : idempotence, même code et une seule ligne pour deux appels';
    IF c.t = c.a1 THEN
        RAISE EXCEPTION 'ÉCHEC test 3 : même texte, natures différentes, même code';
    END IF;
    RAISE NOTICE 'OK test 3 : même texte, nature différente, code différent';
    IF c.m IN (c.a1, c.e) OR c.e = c.a1
       OR NOT EXISTS (SELECT 1 FROM mapping.text_code WHERE code = c.e AND key = ' Camille Sentinelle') THEN
        RAISE EXCEPTION 'ÉCHEC test 4 : clé normalisée (casse ou espace) au lieu d''être stockée telle quelle';
    END IF;
    RAISE NOTICE 'OK test 4 : clé stockée telle que donnée (casse et espace initiale distinguées)';
    IF pg_get_function_result('mapping.code_for(text, text)'::regprocedure) <> 'bigint'
       OR EXISTS (SELECT 1 FROM test_codes WHERE code <= 0) THEN
        RAISE EXCEPTION 'ÉCHEC test 5 : le code n''est pas un entier tiré de la séquence';
    END IF;
    RAISE NOTICE 'OK test 5 : code entier positif, de même forme pour une clé courte et une clé de 1 500 caractères';
    IF (SELECT count(*) FROM mapping.text_code WHERE key ILIKE '%sentinelle%') <> 7 THEN
        RAISE EXCEPTION 'ÉCHEC test 6 : % lignes de test au lieu de 7 (un refus a-t-il créé une ligne ?)',
            (SELECT count(*) FROM mapping.text_code WHERE key ILIKE '%sentinelle%');
    END IF;
    RAISE NOTICE 'OK test 6 : aucun refus n''a créé de ligne';
END;
$$;

-- ============================================================================================================
-- Test 7 : droits ; books_transformer ne lit pas la table, books_reader et books_collector n'ont rien
-- ============================================================================================================
DO $$
BEGIN
    IF has_schema_privilege('books_reader', 'mapping', 'USAGE') OR has_schema_privilege('books_collector', 'mapping', 'USAGE')
       OR has_schema_privilege('public', 'mapping', 'USAGE')
       OR has_function_privilege('books_reader', 'mapping.code_for(text, text)', 'EXECUTE')
       OR has_function_privilege('books_collector', 'mapping.code_for(text, text)', 'EXECUTE')
       OR has_function_privilege('public', 'mapping.code_for(text, text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'ÉCHEC test 7 : books_reader, books_collector ou PUBLIC a un droit sur mapping';
    END IF;
    RAISE NOTICE 'OK test 7 : catalogue, aucun droit pour books_reader, books_collector ni PUBLIC';
END;
$$;

SET LOCAL ROLE books_transformer;
DO $$
BEGIN
    PERFORM pg_temp.expect_refusal(7, 'lecture de mapping.text_code par books_transformer',
        'SELECT key FROM mapping.text_code', '42501');
    PERFORM pg_temp.expect_refusal(7, 'lecture de mapping.nature par books_transformer',
        'SELECT nature FROM mapping.nature', '42501');
    PERFORM pg_temp.expect_refusal(7, 'insertion directe par books_transformer',
        $q$INSERT INTO mapping.text_code (nature, key) VALUES ('author', 'Sentinelle directe')$q$, '42501');
    PERFORM pg_temp.expect_refusal(7, 'modification par books_transformer',
        $q$UPDATE mapping.text_code SET key = 'Sentinelle modifiée'$q$, '42501');
    PERFORM pg_temp.expect_refusal(7, 'suppression par books_transformer', 'DELETE FROM mapping.text_code', '42501');
    PERFORM pg_temp.expect_refusal(7, 'séquence utilisée par books_transformer',
        $q$SELECT nextval('mapping.text_code_code_seq')$q$, '42501');
END;
$$;
RESET ROLE;

SET LOCAL ROLE books_reader;
DO $$
BEGIN
    PERFORM pg_temp.expect_refusal(7, 'exécution de mapping.code_for par books_reader',
        $q$SELECT mapping.code_for('author', 'Camille Sentinelle')$q$, '42501');
    PERFORM pg_temp.expect_refusal(7, 'lecture de mapping.text_code par books_reader',
        'SELECT key FROM mapping.text_code', '42501');
END;
$$;
RESET ROLE;

SET LOCAL ROLE books_collector;
DO $$
BEGIN
    PERFORM pg_temp.expect_refusal(7, 'exécution de mapping.code_for par books_collector',
        $q$SELECT mapping.code_for('author', 'Camille Sentinelle')$q$, '42501');
    PERFORM pg_temp.expect_refusal(7, 'lecture de mapping.text_code par books_collector',
        'SELECT key FROM mapping.text_code', '42501');
END;
$$;
RESET ROLE;

-- ============================================================================================================
-- Test 8 : détournement par search_path, avec contre-épreuves
-- ============================================================================================================
-- Pièges, posés par le propriétaire : une fausse table text_code dans un schéma placé en tête du search_path de
-- l'appelant, et une autre dans le schéma temporaire de la session. Toutes deux donnent le code -42 à la clé visée.
CREATE SCHEMA test_piege;
CREATE TABLE test_piege.text_code (code bigint, nature text, key text);
INSERT INTO test_piege.text_code VALUES (-42, 'author', 'Camille Sentinelle-Piège');
CREATE TEMP TABLE text_code (code bigint, nature text, key text) ON COMMIT DROP;
INSERT INTO pg_temp.text_code VALUES (-42, 'author', 'Camille Sentinelle-Piège');
GRANT USAGE ON SCHEMA test_piege TO books_transformer;

-- Contre-épreuves : deux copies fautives de la fonction (lecture seule, noms non qualifiés)
--   sans_search_path : aucun search_path figé, elle prend celui de l'appelant ;
--   sans_pg_temp     : search_path = pg_catalog seulement, pg_temp est alors cherché en premier pour les tables.
CREATE FUNCTION test_piege.sans_search_path(p_nature text, p_key text) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
AS $f$ BEGIN RETURN (SELECT code FROM text_code WHERE nature = p_nature AND key = p_key); END; $f$;
CREATE FUNCTION test_piege.sans_pg_temp(p_nature text, p_key text) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $f$ BEGIN RETURN (SELECT code FROM text_code WHERE nature = p_nature AND key = p_key); END; $f$;
GRANT EXECUTE ON FUNCTION test_piege.sans_search_path(text, text), test_piege.sans_pg_temp(text, text) TO books_transformer;

SET LOCAL ROLE books_transformer;
SET LOCAL search_path = test_piege, pg_temp, mapping, public;
INSERT INTO test_codes VALUES
    ('piège vraie fonction', mapping.code_for('author', 'Camille Sentinelle-Piège')),
    ('piège sans search_path', test_piege.sans_search_path('author', 'Camille Sentinelle-Piège')),
    ('piège sans pg_temp', test_piege.sans_pg_temp('author', 'Camille Sentinelle-Piège'));
RESET search_path;
RESET ROLE;

DO $$
DECLARE
    vraie bigint := (SELECT code FROM test_codes WHERE label = 'piège vraie fonction');
BEGIN
    IF vraie IS NULL OR vraie = -42
       OR NOT EXISTS (SELECT 1 FROM mapping.text_code WHERE code = vraie AND key = 'Camille Sentinelle-Piège')
       OR (SELECT count(*) FROM test_piege.text_code) <> 1 OR (SELECT count(*) FROM pg_temp.text_code) <> 1 THEN
        RAISE EXCEPTION 'ÉCHEC test 8 : mapping.code_for détournée par le search_path de l''appelant';
    END IF;
    RAISE NOTICE 'OK test 8 : mapping.code_for ignore les fausses tables (schéma en tête du search_path et pg_temp)';
    IF (SELECT code FROM test_codes WHERE label = 'piège sans search_path') IS DISTINCT FROM -42 THEN
        RAISE EXCEPTION 'ÉCHEC test 8 : contre-épreuve sans effet, la copie sans search_path figé n''est pas détournée';
    END IF;
    IF (SELECT code FROM test_codes WHERE label = 'piège sans pg_temp') IS DISTINCT FROM -42 THEN
        RAISE EXCEPTION 'ÉCHEC test 8 : contre-épreuve sans effet, la copie sans pg_temp en fin de search_path n''est pas détournée';
    END IF;
    RAISE NOTICE 'OK test 8 : contre-épreuves, les deux copies fautives sont détournées (le piège fonctionne)';
END;
$$;

-- ============================================================================================================
-- Test 9 : après suppression d'une correspondance, un nouveau code ; un code n'est jamais réattribué
-- ============================================================================================================
DELETE FROM mapping.text_code WHERE nature = 'author' AND key = 'Camille Sentinelle';

SET LOCAL ROLE books_transformer;
INSERT INTO test_codes VALUES ('après suppression', mapping.code_for('author', 'Camille Sentinelle'));
RESET ROLE;

DO $$
BEGIN
    IF (SELECT code FROM test_codes WHERE label = 'après suppression')
       <= (SELECT max(code) FROM test_codes WHERE label NOT IN ('après suppression') AND code > 0) THEN
        RAISE EXCEPTION 'ÉCHEC test 9 : après suppression, le code rendu n''est pas un code neuf';
    END IF;
    RAISE NOTICE 'OK test 9 : après suppression de la correspondance, un code neuf (jamais réattribué)';
END;
$$;

ROLLBACK;

-- ============================================================================================================
-- Test 10 : rien n'est conservé (la séquence, non transactionnelle, n'est pas contrôlée)
-- ============================================================================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM mapping.text_code WHERE key ILIKE '%sentinelle%')
       OR EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'test_piege') THEN
        RAISE EXCEPTION 'ÉCHEC test 10 : des lignes ou des objets de test ont été conservés';
    END IF;
    RAISE NOTICE 'OK test 10 : aucune ligne ni aucun objet de test conservé';
END;
$$;
