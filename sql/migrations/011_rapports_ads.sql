-- Migration 011 : rapports Amazon Ads dans RAW (décision 018, lot A)
-- À appliquer par le propriétaire de la base, toutes les migrations 001 à 010 appliquées.
--
-- RAW ne juge que la NATURE d'un fichier (vide, encodage, type, dimension « Date », nom), jamais son contenu :
-- un verdict gravé dans une couche immuable, dédoublonnée par empreinte, ne pourrait pas être corrigé si le
-- validateur avait un défaut. Les contrôles de contenu sont des statuts d'extraction recalculables (lot B, STAGING).
-- Écrit par books_collector seulement ; aucun droit pour books_transformer (lot B), books_reader (décision 018) ni PUBLIC.

BEGIN;

-- Garde-fou : migration appliquée dans l'ordre
DO $$
BEGIN
    IF (SELECT max(version) FROM public.schema_migration) IS DISTINCT FROM 10 THEN
        RAISE EXCEPTION 'migration 011 : la dernière migration appliquée doit être la 10 (trouvé : %)',
            (SELECT max(version) FROM public.schema_migration);
    END IF;
END;
$$;

-- Une ligne par ingestion de rapports (sur le modèle de raw.collect_run) : statut, compteurs et bilan
CREATE TABLE raw.ads_ingest_run (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at        timestamptz NOT NULL DEFAULT now(),
    finished_at       timestamptz,
    collector_version text NOT NULL,
    status            text NOT NULL DEFAULT 'running'
                      CONSTRAINT ads_ingest_run_status_ck
                      CHECK (status IN ('running', 'success', 'partial', 'failed')),
    files_ok          integer NOT NULL DEFAULT 0,
    files_invalid     integer NOT NULL DEFAULT 0,
    notes             text
);

-- Une ligne par fichier de rapport reçu, jamais modifiée. Le fichier lui-même est déposé, compressé, sous
-- BOOKS_RAW_DIR/amazon_ads/ ; empreinte et taille sont celles du fichier d'origine.
CREATE TABLE raw.ads_report_file (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id          bigint NOT NULL REFERENCES raw.ads_ingest_run (id),
    -- Lot de transfert (horodatage UTC de l'envoi, décision 008) et nom du fichier tel que reçu
    lot             text NOT NULL CONSTRAINT ads_report_file_lot_ck CHECK (lot ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z$'),
    original_name   text NOT NULL CONSTRAINT ads_report_file_name_ck CHECK (original_name <> ''),
    ingested_at     timestamptz NOT NULL DEFAULT now(),
    -- Empreinte unique : un même fichier n'est déposé qu'une fois (dédoublonnage, décision 018, section 2)
    content_sha256  text NOT NULL CONSTRAINT ads_report_file_sha256_ck CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),
    content_bytes   integer NOT NULL CONSTRAINT ads_report_file_bytes_ck CHECK (content_bytes >= 0),
    storage_path    text NOT NULL,
    -- Type détecté par les en-têtes, jamais par le nom ; NULL s'il n'a pas pu l'être
    report_type     text CONSTRAINT ads_report_file_type_ck CHECK (report_type IN ('advertised_product', 'search_term')),
    -- Date et heure d'export lues dans le nom (…_MM_JJ_AAAAThh_mm_ss.csv) ; fuseau inconnu, d'où « time » sans fuseau
    export_date     date,
    export_time     time,
    status          text NOT NULL CONSTRAINT ads_report_file_status_ck CHECK (status IN ('ok', 'invalid')),
    reason          text,
    CONSTRAINT ads_report_file_sha256_uq UNIQUE (content_sha256),
    CONSTRAINT ads_report_file_storage_uq UNIQUE (storage_path),
    CONSTRAINT ads_report_file_export_ck CHECK ((export_date IS NULL) = (export_time IS NULL)),
    -- Un fichier invalid a toujours son motif ; un fichier ok n'en a pas, et a son type et sa date d'export
    CONSTRAINT ads_report_file_verdict_ck CHECK (
        (status = 'invalid' AND reason IS NOT NULL AND reason <> '')
     OR (status = 'ok' AND reason IS NULL AND report_type IS NOT NULL AND export_date IS NOT NULL)
    )
);

CREATE INDEX ads_report_file_run_idx ON raw.ads_report_file (run_id);

-- Ajout seul, comme raw.raw_page (raw.forbid_change, migration 001)
CREATE TRIGGER ads_report_file_append_only
    BEFORE UPDATE OR DELETE ON raw.ads_report_file
    FOR EACH ROW EXECUTE FUNCTION raw.forbid_change();

CREATE TRIGGER ads_report_file_no_truncate
    BEFORE TRUNCATE ON raw.ads_report_file
    FOR EACH STATEMENT EXECUTE FUNCTION raw.forbid_change();

-- books_collector : lecture et ajout ; clôture d'une ingestion limitée à ces colonnes (privilège par colonne)
GRANT SELECT, INSERT ON raw.ads_ingest_run, raw.ads_report_file TO books_collector;
GRANT UPDATE (finished_at, status, files_ok, files_invalid, notes) ON raw.ads_ingest_run TO books_collector;
-- Aucun droit pour books_transformer (lot B), books_reader (décision 018, hors périmètre) ni PUBLIC.

INSERT INTO public.schema_migration (version, description)
VALUES (11, 'Rapports Amazon Ads dans RAW : ads_ingest_run et ads_report_file (décision 018, lot A)');

COMMIT;
