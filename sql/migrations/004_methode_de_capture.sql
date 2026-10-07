-- Migration 004 : méthode de capture et métadonnées des captures (décisions 005, 007 et 008)
-- À appliquer par le propriétaire de la base.
--
-- Trois colonnes ajoutées à raw.raw_page, sans valeur par défaut : les lignes existantes valent NULL
-- (« méthode non enregistrée ») ; aucune n'est modifiée (RAW en ajout seul, aucun UPDATE).
BEGIN;

ALTER TABLE raw.raw_page
    -- extension-dom : capture du DOM par l'extension (décision 007) ;
    -- manual-html : page enregistrée à la main (Ctrl+S, « HTML uniquement »), développement uniquement
    ADD COLUMN capture_method  text CHECK (capture_method IN ('extension-dom', 'manual-html')),
    -- Emplacement du JSON de la capture déposé dans RAW, relatif à BOOKS_RAW_DIR (comme storage_path)
    ADD COLUMN metadata_path   text,
    -- Empreinte SHA-256 du JSON d'origine, non compressé (comme content_sha256 pour le HTML)
    ADD COLUMN metadata_sha256 text CHECK (metadata_sha256 ~ '^[0-9a-f]{64}$');

-- Méthode obligatoire pour les nouvelles lignes seulement.
-- NOT VALID : la contrainte s'applique à toute nouvelle ligne, sans vérifier les lignes existantes,
-- qui gardent leur NULL. Ne JAMAIS lancer « ALTER TABLE … VALIDATE CONSTRAINT raw_page_capture_method_nn » :
-- elle vérifierait les lignes anciennes et échouerait.
ALTER TABLE raw.raw_page
    ADD CONSTRAINT raw_page_capture_method_nn CHECK (capture_method IS NOT NULL) NOT VALID;

-- Cohérence entre la méthode et les métadonnées. Les lignes existantes (tout à NULL) la respectent :
-- elle est validée normalement.
--   extension-dom : JSON déposé et empreinte du HTML obligatoires (une capture est toujours un fichier,
--                   même blocked ou invalid) ;
--   manual-html ou NULL : aucun JSON.
ALTER TABLE raw.raw_page
    ADD CONSTRAINT raw_page_capture_metadata_ck CHECK (
        (capture_method = 'extension-dom'
            AND metadata_path IS NOT NULL AND metadata_sha256 IS NOT NULL AND content_sha256 IS NOT NULL)
     OR (capture_method IS DISTINCT FROM 'extension-dom'
            AND metadata_path IS NULL AND metadata_sha256 IS NULL)
    );

-- Une capture de l'extension n'est déposée qu'une fois (décision 008, « déjà ingérée »).
-- Index partiel : les pages enregistrées à la main (manual-html, ou méthode NULL), réingérées
-- plusieurs fois en développement, n'y figurent pas.
CREATE UNIQUE INDEX raw_page_capture_sha256_uq
    ON raw.raw_page (content_sha256)
    WHERE capture_method = 'extension-dom';

INSERT INTO public.schema_migration (version, description)
VALUES (4, 'Méthode de capture et métadonnées des captures');

COMMIT;
