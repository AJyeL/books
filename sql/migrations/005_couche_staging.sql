-- Migration 005 : couche STAGING et rôle books_transformer (décision 011)
-- À appliquer par le propriétaire de la base. Aucun mot de passe ici (dépôt public) :
-- celui de books_transformer est défini à la main avec \password, une fois par environnement (voir README).
--
-- STAGING est recalculable à partir de RAW : contrairement à raw, ses lignes peuvent être supprimées et
-- remplacées (réextraction d'une page, décision 011, section 6).

BEGIN;

CREATE SCHEMA staging;

-- Une ligne par exécution de l'extracteur (sur le modèle de raw.collect_run, sans la valeur « aborted »)
CREATE TABLE staging.extract_run (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at        timestamptz NOT NULL DEFAULT now(),
    finished_at       timestamptz,
    extractor_version text NOT NULL,
    status            text NOT NULL DEFAULT 'running'
                      CONSTRAINT extract_run_status_ck
                      CHECK (status IN ('running', 'success', 'partial', 'failed')),
    pages_extracted   integer NOT NULL DEFAULT 0,
    pages_failed      integer NOT NULL DEFAULT 0,
    notes             text
);

-- Une ligne par page RAW examinée : rend visibles les pages en échec, qui n'ont aucune ligne dans
-- ranking_entry, et indique quelle version de l'extracteur a traité chaque page
CREATE TABLE staging.page_extraction (
    raw_page_id       bigint PRIMARY KEY REFERENCES raw.raw_page (id),
    extract_run_id    bigint NOT NULL REFERENCES staging.extract_run (id),
    extractor_version text NOT NULL,
    status            text NOT NULL
                      CONSTRAINT page_extraction_status_ck
                      CHECK (status IN ('ok', 'parse_failed', 'integrity_failed')),
    error_message     text,
    entry_count       integer NOT NULL,
    extracted_at      timestamptz NOT NULL DEFAULT now(),
    -- Page extraite : au moins une ligne, aucun motif ; page en échec : un motif, aucune ligne
    CONSTRAINT page_extraction_result_ck CHECK (
        (status = 'ok' AND error_message IS NULL AND entry_count >= 1)
     OR (status <> 'ok' AND error_message IS NOT NULL AND entry_count = 0)
    )
);

-- Une ligne par (page RAW, rang). Le contexte (catégorie, liste, page, horodatage, méthode) s'obtient par
-- jointure avec raw.raw_page : il n'est pas recopié.
CREATE TABLE staging.ranking_entry (
    raw_page_id     bigint NOT NULL REFERENCES raw.raw_page (id),
    extract_run_id  bigint NOT NULL REFERENCES staging.extract_run (id),
    rank            smallint NOT NULL CONSTRAINT ranking_entry_rank_ck CHECK (rank BETWEEN 1 AND 100),
    asin            text NOT NULL CONSTRAINT ranking_entry_asin_ck CHECK (asin ~ '^[A-Z0-9]{10}$'),
    has_card        boolean NOT NULL,
    title           text,
    price_amount    numeric(8,2) CONSTRAINT ranking_entry_price_ck CHECK (price_amount >= 0),
    currency        text CONSTRAINT ranking_entry_currency_ck CHECK (currency ~ '^[A-Z]{3}$'),
    rating          numeric(2,1) CONSTRAINT ranking_entry_rating_ck CHECK (rating BETWEEN 0 AND 5),
    review_count    integer CONSTRAINT ranking_entry_review_count_ck CHECK (review_count >= 0),
    cover_url       text,
    ku_sticker_hint boolean,
    CONSTRAINT ranking_entry_pk PRIMARY KEY (raw_page_id, rank),
    CONSTRAINT ranking_entry_asin_uq UNIQUE (raw_page_id, asin),
    -- Sans carte détaillée, tous les champs de détail sont inconnus (NULL) : jamais une valeur supposée
    CONSTRAINT ranking_entry_no_card_ck CHECK (
        has_card
        OR (title IS NULL AND price_amount IS NULL AND currency IS NULL AND rating IS NULL
            AND review_count IS NULL AND cover_url IS NULL AND ku_sticker_hint IS NULL)
    ),
    -- Note et nombre d'évaluations vont ensemble (inventaire du 8 octobre 2026) ; prix et devise aussi
    CONSTRAINT ranking_entry_rating_reviews_ck CHECK ((rating IS NULL) = (review_count IS NULL)),
    CONSTRAINT ranking_entry_price_currency_ck CHECK ((price_amount IS NULL) = (currency IS NULL))
);

COMMENT ON COLUMN staging.ranking_entry.ku_sticker_hint IS
    'Indice NON VÉRIFIÉ : « ku-sticker » présent dans cover_url. Ce n''est pas une appartenance à Kindle Unlimited. '
    'Exclu de toute analyse tant que l''hypothèse n''est pas vérifiée et consignée (décision 011, section 8).';
COMMENT ON COLUMN staging.ranking_entry.has_card IS
    'Faux : le livre n''a pas de carte détaillée dans la page, ses champs de détail sont inconnus (NULL). '
    'Vrai avec rating NULL : carte présente, aucune évaluation affichée.';

-- Rôle de connexion de l'extracteur, sans attribut particulier ; sans mot de passe, pas de connexion réseau
CREATE ROLE books_transformer LOGIN;

-- RAW : lecture seule
GRANT USAGE ON SCHEMA raw TO books_transformer;
GRANT SELECT ON raw.collect_run, raw.raw_page TO books_transformer;

-- STAGING : écriture limitée à ce que fait l'extracteur
GRANT USAGE ON SCHEMA staging TO books_transformer;
-- Réextraction d'une page : suppression de ses lignes, puis insertion des nouvelles
GRANT SELECT, INSERT, DELETE ON staging.ranking_entry TO books_transformer;
-- Une ligne par page, remplacée à chaque extraction (INSERT … ON CONFLICT DO UPDATE) ; raw_page_id non modifiable
GRANT SELECT, INSERT ON staging.page_extraction TO books_transformer;
GRANT UPDATE (extract_run_id, extractor_version, status, error_message, entry_count, extracted_at)
    ON staging.page_extraction TO books_transformer;
-- Clôture d'une exécution : modification limitée à ces colonnes
GRANT SELECT, INSERT ON staging.extract_run TO books_transformer;
GRANT UPDATE (finished_at, status, pages_extracted, pages_failed, notes)
    ON staging.extract_run TO books_transformer;
-- books_collector ne reçoit aucun droit sur staging. Le droit TEMPORARY a déjà été retiré à PUBLIC (migration 002).

INSERT INTO public.schema_migration (version, description)
VALUES (5, 'Couche STAGING et rôle books_transformer');

COMMIT;
