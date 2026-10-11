-- Migration 007 : fiches produit dans STAGING (décision 015, section 6 et note de l'étape D du 11 octobre 2026)
-- À appliquer par le propriétaire de la base.
--
-- Quatre tables, une ligne d'observation par fiche Kindle extraite et ses lignes de détail (onglets de formats, rangs
-- de vente, répartition des notes). Comme ranking_entry, elles se recalculent à partir de RAW (réextraction) et sont
-- rattachées à page_extraction par la clé composée (page RAW, exécution) : jamais deux versions mélangées.
-- L'ASIN et l'horodatage de la fiche ne sont pas recopiés : ils s'obtiennent par jointure avec raw.raw_page (contexte
-- par jointure, décision 011 ; même règle que category_observation).
-- Ni auteur, ni éditeur, ni avis individuels, ni mention de livraison (décisions 013 et 015).

BEGIN;

-- Fiches papier mises à part (statut « skipped », motif « format papier ») : ni succès ni anomalie. La contrainte
-- page_extraction_result_ck s'applique telle quelle : un motif, aucune ligne.
ALTER TABLE staging.page_extraction DROP CONSTRAINT page_extraction_status_ck;
ALTER TABLE staging.page_extraction ADD CONSTRAINT page_extraction_status_ck
    CHECK (status IN ('ok', 'parse_failed', 'integrity_failed', 'skipped'));

ALTER TABLE staging.extract_run ADD COLUMN pages_skipped integer NOT NULL DEFAULT 0;

-- Une ligne par fiche Kindle extraite
CREATE TABLE staging.product_observation (
    raw_page_id     bigint PRIMARY KEY,
    extract_run_id  bigint NOT NULL,
    format_label    text NOT NULL CONSTRAINT product_observation_format_ck CHECK (btrim(format_label) <> ''),
    title           text NOT NULL CONSTRAINT product_observation_title_ck CHECK (btrim(title) <> ''),
    -- Série : « Livre n sur N » (rang et total) ou « Fait partie de la série » (sans rang)
    series_form     text CONSTRAINT product_observation_series_form_ck
                    CHECK (series_form IN ('livre_n_sur_n', 'fait_partie')),
    series_name     text CONSTRAINT product_observation_series_name_ck CHECK (btrim(series_name) <> ''),
    series_position smallint CONSTRAINT product_observation_series_position_ck CHECK (series_position >= 1),
    series_total    smallint CONSTRAINT product_observation_series_total_ck CHECK (series_total >= 1),
    publication_date date,
    language        text CONSTRAINT product_observation_language_ck CHECK (btrim(language) <> ''),
    print_pages     integer CONSTRAINT product_observation_print_pages_ck CHECK (print_pages >= 1),
    -- Taille du fichier telle qu'affichée, sans conversion (« 1.2 MB », « 850 KB »)
    file_size_value numeric(8,1) CONSTRAINT product_observation_file_size_value_ck CHECK (file_size_value > 0),
    file_size_unit  text CONSTRAINT product_observation_file_size_unit_ck CHECK (file_size_unit IN ('KB', 'MB')),
    isbn13          text CONSTRAINT product_observation_isbn13_ck CHECK (isbn13 ~ '^97[89]-[0-9]{10}$'),
    rating          numeric(2,1) CONSTRAINT product_observation_rating_ck CHECK (rating BETWEEN 0 AND 5),
    review_count    integer CONSTRAINT product_observation_review_count_ck CHECK (review_count >= 0),
    cover_url       text CONSTRAINT product_observation_cover_url_ck CHECK (cover_url LIKE 'https://%'),
    description_text          text CONSTRAINT product_observation_description_text_ck
                              CHECK (btrim(description_text) <> ''),
    description_text_sha256   text,
    description_markup        text CONSTRAINT product_observation_description_markup_ck
                              CHECK (btrim(description_markup) <> ''),
    description_markup_sha256 text,
    has_aplus       boolean,
    breadcrumb      text CONSTRAINT product_observation_breadcrumb_ck CHECK (btrim(breadcrumb) <> ''),
    CONSTRAINT product_observation_page_extraction_fk FOREIGN KEY (raw_page_id, extract_run_id)
        REFERENCES staging.page_extraction (raw_page_id, extract_run_id),
    CONSTRAINT product_observation_series_ck CHECK (
        (series_form IS NULL) = (series_name IS NULL)
        AND (series_position IS NULL) = (series_form IS DISTINCT FROM 'livre_n_sur_n')
        AND (series_total IS NULL) = (series_form IS DISTINCT FROM 'livre_n_sur_n')
        AND (series_position IS NULL OR series_position <= series_total)
    ),
    CONSTRAINT product_observation_file_size_ck CHECK ((file_size_value IS NULL) = (file_size_unit IS NULL)),
    -- Note absente si et seulement si aucun avis (0) ou compteur inconnu (NULL)
    CONSTRAINT product_observation_rating_reviews_ck CHECK (
        (rating IS NULL) = (review_count IS NULL OR review_count = 0)),
    -- Description : les deux colonnes et leurs empreintes ensemble ; l'empreinte est celle du texte stocké
    CONSTRAINT product_observation_description_ck CHECK (
        (description_text IS NULL) = (description_markup IS NULL)
        AND (description_text IS NULL) = (description_text_sha256 IS NULL)
        AND (description_markup IS NULL) = (description_markup_sha256 IS NULL)),
    CONSTRAINT product_observation_description_text_sha256_ck CHECK (
        description_text_sha256 = encode(sha256(convert_to(description_text, 'UTF8')), 'hex')),
    CONSTRAINT product_observation_description_markup_sha256_ck CHECK (
        description_markup_sha256 = encode(sha256(convert_to(description_markup, 'UTF8')), 'hex'))
);

-- Une ligne par onglet de format (#tmmSwatches), dans l'ordre de la page
CREATE TABLE staging.product_format (
    raw_page_id     bigint NOT NULL,
    extract_run_id  bigint NOT NULL,
    position        smallint NOT NULL CONSTRAINT product_format_position_ck CHECK (position >= 1),
    swatch_kind     text NOT NULL CONSTRAINT product_format_swatch_kind_ck CHECK (swatch_kind ~ '^[A-Z_]+$'),
    label           text NOT NULL CONSTRAINT product_format_label_ck CHECK (btrim(label) <> ''),
    is_selected     boolean NOT NULL,
    linked_asin     text CONSTRAINT product_format_linked_asin_ck CHECK (linked_asin ~ '^[A-Z0-9]{10}$'),
    price_amount    numeric(8,2) CONSTRAINT product_format_price_ck CHECK (price_amount >= 0),
    currency        text CONSTRAINT product_format_currency_ck CHECK (currency ~ '^[A-Z]{3}$'),
    price_qualifier text NOT NULL CONSTRAINT product_format_price_qualifier_ck
                    CHECK (price_qualifier IN ('exact', 'a_partir_de', 'avec_abonnement', 'avec_offre_essai',
                                               'non_affiche')),
    ku_borrow       boolean NOT NULL,
    CONSTRAINT product_format_pk PRIMARY KEY (raw_page_id, position),
    CONSTRAINT product_format_page_extraction_fk FOREIGN KEY (raw_page_id, extract_run_id)
        REFERENCES staging.page_extraction (raw_page_id, extract_run_id),
    -- L'onglet du format de la page n'a pas de lien ; tous les autres renvoient à leur fiche
    CONSTRAINT product_format_link_ck CHECK (is_selected = (linked_asin IS NULL)),
    -- « — » : aucun prix affiché ; sinon un prix et sa devise
    CONSTRAINT product_format_price_shown_ck CHECK ((price_qualifier = 'non_affiche') = (price_amount IS NULL)),
    CONSTRAINT product_format_price_currency_ck CHECK ((price_amount IS NULL) = (currency IS NULL)),
    -- « Emprunt » (Kindle Unlimited) : seulement sur l'onglet de l'ebook
    CONSTRAINT product_format_ku_borrow_ck CHECK (NOT ku_borrow OR swatch_kind IN ('KINDLE', 'OTHER'))
);
-- Un seul onglet sélectionné par fiche (index unique partiel : l'unicité ne porte que sur les lignes sélectionnées)
CREATE UNIQUE INDEX product_format_selected_uq ON staging.product_format (raw_page_id) WHERE is_selected;

COMMENT ON COLUMN staging.product_format.ku_borrow IS
    'Indice NON VÉRIFIÉ : prix affiché « Emprunt » (offre Kindle Unlimited) ; le prix d''achat est alors celui du message '
    '« ou … pour acheter ». Exclu de toute analyse avant vérification et décision (décision 015, note du 11 octobre 2026).';

-- Une ligne par rang de vente : le rang général (au plus un) et les rangs de catégorie (ul.zg_hrsr)
CREATE TABLE staging.product_sales_rank (
    raw_page_id     bigint NOT NULL,
    extract_run_id  bigint NOT NULL,
    position        smallint NOT NULL CONSTRAINT product_sales_rank_position_ck CHECK (position >= 1),
    is_general      boolean NOT NULL,
    rank            integer NOT NULL CONSTRAINT product_sales_rank_rank_ck CHECK (rank >= 1),
    store           text NOT NULL CONSTRAINT product_sales_rank_store_ck CHECK (store IN ('digital-text', 'books')),
    category_node   text CONSTRAINT product_sales_rank_category_node_ck CHECK (category_node ~ '^[0-9]+$'),
    list_type       text NOT NULL CONSTRAINT product_sales_rank_list_type_ck CHECK (list_type IN ('paid', 'free')),
    CONSTRAINT product_sales_rank_pk PRIMARY KEY (raw_page_id, position),
    CONSTRAINT product_sales_rank_page_extraction_fk FOREIGN KEY (raw_page_id, extract_run_id)
        REFERENCES staging.page_extraction (raw_page_id, extract_run_id),
    -- Un rang de catégorie a toujours son numéro ; le rang général en a un dans une forme rare (sous-boutique)
    CONSTRAINT product_sales_rank_node_ck CHECK (is_general OR category_node IS NOT NULL)
);
CREATE UNIQUE INDEX product_sales_rank_general_uq ON staging.product_sales_rank (raw_page_id) WHERE is_general;

-- Une ligne par niveau d'étoiles (#histogramTable) : pourcentage affiché
CREATE TABLE staging.product_rating_share (
    raw_page_id     bigint NOT NULL,
    extract_run_id  bigint NOT NULL,
    stars           smallint NOT NULL CONSTRAINT product_rating_share_stars_ck CHECK (stars BETWEEN 1 AND 5),
    percent         smallint NOT NULL CONSTRAINT product_rating_share_percent_ck CHECK (percent BETWEEN 0 AND 100),
    CONSTRAINT product_rating_share_pk PRIMARY KEY (raw_page_id, stars),
    CONSTRAINT product_rating_share_page_extraction_fk FOREIGN KEY (raw_page_id, extract_run_id)
        REFERENCES staging.page_extraction (raw_page_id, extract_run_id)
);

COMMENT ON COLUMN staging.product_observation.review_count IS
    'Nombre d''avis affiché ; 0 : compteur absent et répartition entièrement à 0 % ; NULL : inconnu. Avis communs aux '
    'formats d''un même livre : ne jamais les additionner entre formats (décision 015, section 6).';
COMMENT ON COLUMN staging.product_observation.has_aplus IS
    'Bloc A+ avec contenu (vrai) ou vide (faux) ; NULL : élément #aplus_feature_div absent. Le bloc est dans le DOM dès le '
    'chargement (recette du 10 octobre 2026).';
COMMENT ON COLUMN staging.product_observation.description_markup IS
    'Balises de sens seulement, sans attribut : b, i, u, h3 à h5, ul, li, p, br (décision 015, note du 11 octobre 2026).';

-- Réextraction d'une page : suppression de ses lignes, puis insertion des nouvelles (comme ranking_entry)
GRANT SELECT, INSERT, DELETE ON staging.product_observation, staging.product_format, staging.product_sales_rank,
    staging.product_rating_share TO books_transformer;
GRANT UPDATE (pages_skipped) ON staging.extract_run TO books_transformer;
-- books_collector ne reçoit aucun droit sur staging.

INSERT INTO public.schema_migration (version, description)
VALUES (7, 'Fiches produit dans STAGING');

COMMIT;
