-- Migration 010 : correspondance des textes sensibles, schéma mapping (décisions 013 et 019)
-- À appliquer par le propriétaire de la base, toutes les migrations 001 à 009 appliquées.
--
-- Étape 1 de la décision 013 : le mécanisme seul, sans aucun utilisateur (ni l'extracteur ni les rapports Ads ne
-- l'appellent encore). Un texte sensible (nom d'auteur, terme de recherche, ciblage, nom de campagne ou de groupe,
-- titre de produit) reçoit un code tiré d'une séquence ; STAGING ne portera que ce code. Le texte ne vit que dans le
-- schéma mapping, propriété d'un rôle sans connexion ; books_transformer obtient un code par mapping.code_for, sans
-- jamais lire la table. Aucun autre rôle n'a de droit (liste blanche de la décision 016).

BEGIN;

-- Garde-fou : migration appliquée dans l'ordre, sur une base où les trois rôles existent
DO $$
BEGIN
    IF (SELECT max(version) FROM public.schema_migration) IS DISTINCT FROM 9 THEN
        RAISE EXCEPTION 'migration 010 : la dernière migration appliquée doit être la 9 (trouvé : %)',
            (SELECT max(version) FROM public.schema_migration);
    END IF;
    IF (SELECT count(*) FROM pg_roles
         WHERE rolname IN ('books_collector', 'books_transformer', 'books_reader')) <> 3 THEN
        RAISE EXCEPTION 'migration 010 : les rôles books_collector, books_transformer et books_reader sont requis';
    END IF;
END;
$$;

-- Rôle propriétaire de la correspondance : sans connexion, sans aucun attribut, membre d'aucun rôle
CREATE ROLE books_mapping NOLOGIN;

CREATE SCHEMA mapping AUTHORIZATION books_mapping;

-- Les objets sont créés sous l'identité du rôle dédié : ils lui appartiennent d'emblée
SET LOCAL ROLE books_mapping;

-- Natures autorisées : une seule liste, lue par la clé étrangère et par la fonction
CREATE TABLE mapping.nature (
    nature      text PRIMARY KEY,
    description text NOT NULL
);

INSERT INTO mapping.nature (nature, description) VALUES
    ('author',        'Nom d''auteur affiché (décision 013)'),
    ('search_term',   'Terme de recherche d''un rapport Amazon Ads (décision 018)'),
    ('targeting',     'Ciblage d''un rapport Amazon Ads (décision 018)'),
    ('campaign',      'Nom de campagne Amazon Ads (décision 018)'),
    ('ad_group',      'Nom de groupe de publicités Amazon Ads (décision 018)'),
    ('product_title', 'Titre du produit promu d''un rapport Amazon Ads (décision 018)');

-- Une ligne par (nature, clé). Le code vient d'une séquence commune à toutes les natures : il ne contient rien du
-- texte, ni même sa nature, et n'est jamais réattribué. Aucune clé étrangère ne pointera vers cette table depuis
-- STAGING : la suppression d'une correspondance (décision 013, section 6) doit laisser les codes en place.
CREATE TABLE mapping.text_code (
    code             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nature           text NOT NULL REFERENCES mapping.nature (nature),
    -- Stockée telle que l'appelant la donne : la normalisation (casse, espaces, Unicode) appartient à chaque
    -- utilisateur (étapes 2 et 3). Refusée si elle ne contient que des séparateurs déjà rencontrés.
    key              text NOT NULL
                     CONSTRAINT text_code_key_not_blank_ck
                     CHECK (btrim(key, E' \t\r\n  ') <> '')
                     CONSTRAINT text_code_key_length_ck
                     CHECK (octet_length(key) <= 2000),
    -- Prévu pour l'étape 2, jamais rempli à l'étape 1 : identifiant d'auteur Amazon, auteurs seulement
    amazon_author_id text
                     CONSTRAINT text_code_amazon_author_id_ck
                     CHECK (amazon_author_id IS NULL
                            OR (nature = 'author' AND btrim(amazon_author_id, E' \t\r\n  ') <> '')),
    created_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT text_code_nature_key_uq UNIQUE (nature, key)
);

CREATE UNIQUE INDEX text_code_amazon_author_id_uq ON mapping.text_code (amazon_author_id)
    WHERE amazon_author_id IS NOT NULL;

-- Rend le code d'un texte, et le crée s'il n'existe pas. SECURITY DEFINER : s'exécute avec les droits de
-- books_mapping, seul à lire la table. search_path figé (pg_temp nommé en dernier, sinon il serait cherché en
-- premier) et noms qualifiés : un appelant ne peut pas substituer une table ou une fonction.
-- Idempotente, y compris entre transactions concurrentes : ON CONFLICT fait attendre la seconde transaction jusqu'à
-- la fin de la première. Aucun message d'erreur ne contient la clé ni la nature reçue (qui pourrait être un texte
-- passé par erreur à sa place) : la journalisation d'une erreur ne doit jamais recopier un texte sensible.
CREATE FUNCTION mapping.code_for(p_nature text, p_key text) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_code bigint;
BEGIN
    IF p_nature IS NULL OR NOT EXISTS (SELECT 1 FROM mapping.nature n WHERE n.nature = p_nature) THEN
        RAISE EXCEPTION USING ERRCODE = '22023',
            MESSAGE = 'mapping.code_for : nature NULL ou inconnue (valeurs admises : table mapping.nature)';
    END IF;
    IF p_key IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '22004', MESSAGE = 'mapping.code_for : clé NULL refusée';
    END IF;
    IF btrim(p_key, E' \t\r\n  ') = '' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'mapping.code_for : clé vide ou blanche refusée';
    END IF;
    IF octet_length(p_key) > 2000 THEN
        RAISE EXCEPTION USING ERRCODE = '22023',
            MESSAGE = format('mapping.code_for : clé trop longue (%s octets, 2000 au plus)', octet_length(p_key));
    END IF;

    SELECT t.code INTO v_code FROM mapping.text_code t WHERE t.nature = p_nature AND t.key = p_key;
    IF FOUND THEN
        RETURN v_code;
    END IF;

    INSERT INTO mapping.text_code (nature, key) VALUES (p_nature, p_key)
        ON CONFLICT (nature, key) DO NOTHING
        RETURNING code INTO v_code;
    IF v_code IS NOT NULL THEN
        RETURN v_code;
    END IF;

    -- Conflit : la ligne vient d'être validée par une transaction concurrente (visible en READ COMMITTED)
    SELECT t.code INTO v_code FROM mapping.text_code t WHERE t.nature = p_nature AND t.key = p_key;
    IF FOUND THEN
        RETURN v_code;
    END IF;
    RAISE EXCEPTION USING ERRCODE = '40001',
        MESSAGE = 'mapping.code_for : code créé par une transaction concurrente, invisible dans l''isolation en cours';
END;
$$;

-- PostgreSQL accorde par défaut l'exécution de toute fonction à PUBLIC : fermée dans la même transaction
-- (décision 013, note du 11 octobre 2026), puis accordée nommément au seul books_transformer
REVOKE EXECUTE ON FUNCTION mapping.code_for(text, text) FROM PUBLIC;
GRANT USAGE ON SCHEMA mapping TO books_transformer;
GRANT EXECUTE ON FUNCTION mapping.code_for(text, text) TO books_transformer;
-- Aucun droit sur les tables ni sur la séquence, pour aucun rôle.

RESET ROLE;

INSERT INTO public.schema_migration (version, description)
VALUES (10, 'Schéma mapping : correspondance des textes sensibles (étape 1 de la décision 013)');

COMMIT;
