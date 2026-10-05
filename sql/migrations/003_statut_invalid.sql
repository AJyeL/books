-- Migration 003 : statut « invalid » pour les pages reçues mais non conformes (décision 004)
-- À appliquer par le propriétaire de la base.
--
-- « invalid » : une page a bien été reçue, mais sa structure ne correspond pas à la page demandée
-- (canonical d'une autre catégorie, absence de render.zg.rank), sans signe de CAPTCHA.
-- Elle est conservée dans RAW pour diagnostic, mais n'est jamais lue comme une page valide.
BEGIN;

-- Suppression et recréation dans la même instruction : la table n'est jamais sans contrôle.
-- La recréation vérifie les lignes existantes ; l'ancienne liste étant incluse dans la nouvelle,
-- elles restent toutes valides.
ALTER TABLE raw.raw_page
    DROP CONSTRAINT raw_page_fetch_status_check,
    ADD CONSTRAINT raw_page_fetch_status_check
        CHECK (fetch_status IN ('ok', 'blocked', 'invalid', 'http_error', 'network_error'));

INSERT INTO public.schema_migration (version, description)
VALUES (3, 'Statut invalid pour les pages non conformes');

COMMIT;
