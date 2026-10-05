-- Migration 002 : rôle dédié au collecteur (décision 003)
-- À appliquer par le propriétaire de la base. Aucun mot de passe ici (dépôt public) :
-- il est défini à la main avec \password, une fois par environnement (voir README).
BEGIN;

-- Rôle de connexion, sans aucun attribut particulier (ni superutilisateur,
-- ni création de base ou de rôle). Sans mot de passe, il ne peut pas se connecter par le réseau.
CREATE ROLE books_collector LOGIN;

-- Accès au schéma raw (voir ce qu'il contient), sans droit d'y créer quoi que ce soit
GRANT USAGE ON SCHEMA raw TO books_collector;

-- Lecture et ajout. Les colonnes d'identité n'exigent aucun droit sur leurs séquences :
-- le droit INSERT sur la table suffit.
GRANT SELECT, INSERT ON raw.collect_run, raw.raw_page TO books_collector;

-- Clôture d'une tournée : modification limitée à ces colonnes (privilège par colonne).
-- id, started_at et collector_version restent non modifiables.
GRANT UPDATE (finished_at, status, pages_ok, pages_failed, notes)
    ON raw.collect_run TO books_collector;

-- Par défaut, tout rôle (PUBLIC) peut créer des tables temporaires dans la base.
-- Retiré : le collecteur ne crée rien. Les superutilisateurs ne sont pas concernés.
DO $$
BEGIN
    EXECUTE format('REVOKE TEMPORARY ON DATABASE %I FROM PUBLIC', current_database());
END;
$$;

INSERT INTO public.schema_migration (version, description)
VALUES (2, 'Rôle books_collector : droits limités sur raw');

COMMIT;
