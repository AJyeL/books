-- Migration 001 : couche RAW (registre des collectes et pages brutes)
BEGIN;

-- Registre des migrations appliquées
CREATE TABLE IF NOT EXISTS public.schema_migration (
    version     integer PRIMARY KEY,
    description text NOT NULL,
    applied_at  timestamptz NOT NULL DEFAULT now()
);

CREATE SCHEMA raw;

-- Une ligne par tournée de collecte
CREATE TABLE raw.collect_run (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at        timestamptz NOT NULL DEFAULT now(),
    finished_at       timestamptz,
    collector_version text NOT NULL,
    status            text NOT NULL DEFAULT 'running'
                      CHECK (status IN ('running', 'success', 'partial', 'failed', 'aborted')),
    pages_ok          integer NOT NULL DEFAULT 0,
    pages_failed      integer NOT NULL DEFAULT 0,
    notes             text
);

-- Une ligne par page téléchargée
CREATE TABLE raw.raw_page (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id          bigint NOT NULL REFERENCES raw.collect_run (id),
    source          text NOT NULL DEFAULT 'amazon_fr',
    page_type       text NOT NULL CHECK (page_type IN ('bestseller_list', 'product')),
    category_node   text CHECK (category_node ~ '^[0-9]+$'),
    list_type       text CHECK (list_type IN ('paid', 'free')),
    page_number     smallint CHECK (page_number IN (1, 2)),
    asin            text CHECK (asin ~ '^[A-Z0-9]{10}$'),
    requested_url   text NOT NULL,
    final_url       text,
    fetched_at      timestamptz NOT NULL DEFAULT now(),
    http_status     smallint,
    fetch_status    text NOT NULL
                    CHECK (fetch_status IN ('ok', 'blocked', 'http_error', 'network_error')),
    error_message   text,
    content_sha256  text,
    content_bytes   integer,
    storage_path    text,
    -- Une page de liste a une catégorie, un type et un numéro ; une fiche a un ASIN
    CONSTRAINT raw_page_target_ck CHECK (
        (page_type = 'bestseller_list' AND category_node IS NOT NULL
            AND list_type IS NOT NULL AND page_number IS NOT NULL AND asin IS NULL)
     OR (page_type = 'product' AND asin IS NOT NULL
            AND category_node IS NULL AND list_type IS NULL AND page_number IS NULL)
    ),
    -- Une collecte réussie a forcément un fichier stocké et son empreinte
    CONSTRAINT raw_page_content_ck CHECK (
        fetch_status <> 'ok'
        OR (storage_path IS NOT NULL AND content_sha256 IS NOT NULL AND content_bytes IS NOT NULL)
    )
);

CREATE INDEX raw_page_run_idx  ON raw.raw_page (run_id);
CREATE INDEX raw_page_list_idx ON raw.raw_page (category_node, list_type, fetched_at);
CREATE INDEX raw_page_asin_idx ON raw.raw_page (asin, fetched_at);

-- La couche RAW est en ajout seul : ni modification, ni suppression
CREATE FUNCTION raw.forbid_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'La table % est en ajout seul (append-only)', TG_TABLE_NAME;
END;
$$;

CREATE TRIGGER raw_page_append_only
    BEFORE UPDATE OR DELETE ON raw.raw_page
    FOR EACH ROW EXECUTE FUNCTION raw.forbid_change();

CREATE TRIGGER raw_page_no_truncate
    BEFORE TRUNCATE ON raw.raw_page
    FOR EACH STATEMENT EXECUTE FUNCTION raw.forbid_change();

INSERT INTO public.schema_migration (version, description)
VALUES (1, 'Couche RAW : collect_run et raw_page');

COMMIT;
