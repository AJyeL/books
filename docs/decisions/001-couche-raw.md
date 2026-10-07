# 001 — Couche RAW

Date : 4 octobre 2026 · Migration : `sql/migrations/001_couche_raw.sql`

> Note du 7 octobre 2026 : la migration 004 (décision 008) ajoute à `raw.raw_page` la méthode de capture
> (`capture_method` : `extension-dom` ou `manual-html`), l'emplacement du JSON de la capture déposé dans RAW
> (`metadata_path`) et son empreinte (`metadata_sha256`). Les lignes antérieures gardent une méthode `NULL`
> (« non enregistrée ») : aucune n'est modifiée. La méthode est obligatoire pour les nouvelles lignes par une
> contrainte `NOT VALID` ; ne jamais la valider (`VALIDATE CONSTRAINT`), ce qui échouerait sur les lignes antérieures.
> Un index unique partiel garantit qu'une capture de l'extension n'est déposée qu'une fois.

## Contexte

B.O.O.K.S. collecte des pages amazon.fr (listes de meilleures ventes et fiches produit)
pour en reconstruire l'historique. La donnée originale doit être conservée telle quelle,
traçable (source, horodatage, tournée de collecte) et protégée contre toute modification,
afin de pouvoir relancer les parsers à tout moment sur les pages d'origine.

## Décision

- **Stockage** : le HTML brut est stocké compressé sur disque, hors du dépôt (`~/books-data` sur atlas).
  PostgreSQL ne contient que ses métadonnées, dont le chemin du fichier (`storage_path`).
- **Deux tables** dans le schéma `raw` :
  - `collect_run` : registre des tournées de collecte (début, fin, version du collecteur, statut, compteurs) ;
  - `raw_page` : une ligne par page téléchargée, réussie ou non.
- **Ajout seul** : `raw_page` n'accepte que des insertions, ce qu'imposent deux déclencheurs
  qui appellent `raw.forbid_change()` :
  - `raw_page_append_only` bloque `UPDATE` et `DELETE` ;
  - `raw_page_no_truncate` bloque `TRUNCATE`.
- **Cohérence** : des contraintes `CHECK` garantissent que :
  - une page de liste a une catégorie, un type (payant/gratuit) et un numéro de page, et pas d'ASIN ;
    une fiche produit a un ASIN, et rien d'autre ;
  - une collecte réussie (`fetch_status = 'ok'`) a forcément un fichier stocké, son empreinte SHA-256 et sa taille ;
  - les valeurs autorisées sont limitées (format d'ASIN, numéro de catégorie, statuts, page 1 ou 2).
- **Horodatages** en UTC (`timestamptz`).
- **Identifiants** générés automatiquement (`GENERATED ALWAYS AS IDENTITY`) : uniques, mais pas
  forcément continus, car une transaction annulée consomme quand même un numéro.
- **Empreinte** : `content_sha256` sert à vérifier l'intégrité du fichier stocké.
  Elle ne sert pas à détecter les changements : la détection des vrais changements se fera plus tard,
  sur une empreinte des données extraites.
  Hypothèse à vérifier lors des premières collectes : le HTML d'Amazon varierait d'une requête à l'autre
  (publicités, jetons techniques) même quand les données n'ont pas changé, ce qui rendrait l'empreinte
  du HTML brut inutilisable pour cet usage.

## Conséquences

- Les pages brutes sont rejouables : un parser corrigé peut être relancé sur tout l'historique.
- La base reste légère ; en contrepartie, la sauvegarde doit couvrir à la fois PostgreSQL et `~/books-data`.
- Une erreur d'écriture dans `raw_page` ne se corrige pas : on insère une nouvelle ligne, et les couches
  suivantes (STAGING, CORE) décident quelle observation retenir.
- `collect_run` n'est pas en ajout seul, car le collecteur doit mettre à jour une tournée en cours
  (fin, statut, compteurs).
- Les trous dans la numérotation des identifiants sont normaux et ne signalent pas de données perdues.
