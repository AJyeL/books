-- Migration 006 : observation du nom des catégories (décision 014, section 3)
-- À appliquer par le propriétaire de la base.
--
-- Une ligne par page RAW extraite avec succès : les noms de la catégorie tels qu'affichés sur la page ce jour-là.
-- Rien n'est écrasé d'une page à l'autre : l'historique des noms d'une catégorie est l'ensemble de ses observations.
-- Le numéro de catégorie n'est pas recopié : il s'obtient par jointure avec raw.raw_page (contexte par jointure,
-- décision 011). Comme ranking_entry, la table se recalcule à partir de RAW (réextraction).

BEGIN;

CREATE TABLE staging.category_observation (
    raw_page_id    bigint PRIMARY KEY,
    extract_run_id bigint NOT NULL,
    -- Nom vide (NULL) : élément absent ou de forme inconnue sur la page ; jamais une chaîne vide
    display_name   text CONSTRAINT category_observation_display_name_ck CHECK (btrim(display_name) <> ''),
    short_name     text CONSTRAINT category_observation_short_name_ck CHECK (btrim(short_name) <> ''),
    -- Jamais deux versions mélangées : l'observation n'existe que pour l'exécution enregistrée pour sa page
    -- (même règle que ranking_entry, migration 005)
    CONSTRAINT category_observation_page_extraction_fk FOREIGN KEY (raw_page_id, extract_run_id)
        REFERENCES staging.page_extraction (raw_page_id, extract_run_id)
);

COMMENT ON COLUMN staging.category_observation.display_name IS
    'Nom d''affichage : second <h1>, après le préfixe « Les meilleures ventes en », tel qu''affiché (suffixe compris).';
COMMENT ON COLUMN staging.category_observation.short_name IS
    'Nom court : élément sélectionné de l''arborescence des catégories (texte direct, sans le texte caché « (Current) »).';

-- Réextraction d'une page : suppression de son observation, puis insertion de la nouvelle (comme ranking_entry)
GRANT SELECT, INSERT, DELETE ON staging.category_observation TO books_transformer;
-- books_collector ne reçoit aucun droit sur staging.

INSERT INTO public.schema_migration (version, description)
VALUES (6, 'Observation du nom des catégories');

COMMIT;
