-- Migration 017 : books_bi passe à 5 connexions au plus (décision 022, règle de révision, note du 11 novembre 2026)
-- À appliquer par le propriétaire de la base.
--
-- Une actualisation réelle de Power BI s'est heurtée à CONNECTION LIMIT 2 : une table fusionnée (jointure dans Power
-- Query) lit sa source de jointure en même temps qu'elle, d'où au moins deux connexions pour une seule table, plus le
-- réservoir de connexions de l'éditeur. Les droits et les autres réglages de books_bi ne changent pas.

BEGIN;

-- Garde-fou : migration appliquée dans l'ordre (IS DISTINCT FROM : un registre vide donne un max NULL)
DO $$
BEGIN
    IF (SELECT max(version) FROM public.schema_migration) IS DISTINCT FROM 16 THEN
        RAISE EXCEPTION 'migration 017 : la dernière migration appliquée doit être la 16 (trouvé : %)',
            (SELECT max(version) FROM public.schema_migration);
    END IF;
END;
$$;

ALTER ROLE books_bi CONNECTION LIMIT 5;

INSERT INTO public.schema_migration (version, description)
VALUES (17, 'Rôle books_bi : 5 connexions au plus');

COMMIT;
