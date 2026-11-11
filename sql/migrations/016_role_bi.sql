-- Migration 016 : rôle books_bi pour Power BI, lecture de CORE seulement (décision 022)
-- À appliquer par le propriétaire de la base. Aucun mot de passe ici (dépôt public) : il est défini à la main sur
-- atlas avec \password, par le porteur du projet (décision 022, section 6), et n'est jamais écrit dans .env.
--
-- Liste blanche explicite, comme books_reader (décision 016) : aucun privilège par défaut. Toute migration qui ajoute une
-- table ou une colonne à core accorde SELECT à books_bi ; sinon le test 016 échoue (colonnes de core non lisibles).

BEGIN;

-- Garde-fou : migration appliquée dans l'ordre. IS DISTINCT FROM, et non <> : une table schema_migration vide donne un
-- max NULL, et « NULL <> 15 » vaut NULL, ce qui ne déclencherait pas l'exception.
DO $$
BEGIN
    IF (SELECT max(version) FROM public.schema_migration) IS DISTINCT FROM 15 THEN
        RAISE EXCEPTION 'migration 016 : la dernière migration appliquée doit être la 15 (trouvé : %)',
            (SELECT max(version) FROM public.schema_migration);
    END IF;
END;
$$;

-- Rôle de connexion, sans aucun autre attribut, membre d'aucun rôle, sans mot de passe
CREATE ROLE books_bi LOGIN CONNECTION LIMIT 2;

-- Garde-fous de session (la lecture seule vient de l'absence de droits d'écriture, pas de ces réglages)
ALTER ROLE books_bi SET default_transaction_read_only = on;
ALTER ROLE books_bi SET statement_timeout = '5min';
ALTER ROLE books_bi SET idle_in_transaction_session_timeout = '5min';

-- CORE : lecture de toutes les tables et de la vue (security_invoker : elle lit les tables avec les droits de books_bi)
GRANT USAGE ON SCHEMA core TO books_bi;
GRANT SELECT ON core.build_run, core.book, core.category, core.category_name, core.list_day, core.ranking_day,
    core.book_title_version, core.book_cover_version, core.book_description_version,
    core.book_description_markup_version, core.book_series_version, core.book_print_pages_version,
    core.book_aplus_version, core.book_publication_date_version, core.book_language_version,
    core.book_file_size_version, core.product_day, core.product_day_category_rank, core.book_current
    TO books_bi;
-- Rien d'autre : ni raw, ni staging (Ads compris), ni guide, ni mapping ; aucune fonction (celles de core sont fermées
-- à PUBLIC) ; TEMPORARY retiré à PUBLIC depuis la migration 002.

-- Avertissement reporté de la décision 021 (note du 11 novembre 2026) : trois portées du rang général
COMMENT ON COLUMN core.product_day.general_rank IS
    'Rang général de la fiche ; NULL : non affiché ce jour-là, le rang de la veille n''est jamais reporté. Trois portées : '
    'boutique entière payante, boutique entière gratuite, sous-boutique (general_rank_category_node renseigné). Ne comparer '
    'des rangs généraux qu''à portée égale (general_rank_store, general_rank_list_type, general_rank_category_node) ; le '
    'rang de la boutique entière est celui dont general_rank_category_node est NULL.';

INSERT INTO public.schema_migration (version, description)
VALUES (16, 'Rôle books_bi : lecture de CORE pour Power BI');

COMMIT;
