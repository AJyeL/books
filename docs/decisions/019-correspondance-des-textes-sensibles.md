# 019 — Correspondance des textes sensibles

Date : 4 novembre 2026 · Migration : `sql/migrations/010_correspondance.sql`

## Contexte

La décision 013 (section 2) prévoit une **pseudonymisation par séparation** : STAGING ne porte qu'un code, et la
correspondance « code → texte » vit dans un schéma séparé, accessible à un rôle dédié. La décision 018 (section 5)
applique le même mécanisme aux textes des rapports Amazon Ads : terme de recherche, ciblage, noms de campagne et de
groupe, titre du produit promu.

Cette décision décrit la **mise en œuvre technique**, découpée en étapes :
- **étape 1**, objet de cette décision : le mécanisme seul, **sans aucun utilisateur**. Ni l'extracteur ni les rapports
  Ads ne l'appellent encore ;
- **étape 2** : les auteurs (extracteur), précédés de la liste d'exclusion (section 7) ;
- **étape 3** : les rapports Amazon Ads (décision 018).

> Note du 4 novembre 2026 : **ordre des étapes.** Les étapes 2 et 3 sont indépendantes : la liste d'exclusion protège
> les auteurs et ne concerne pas les rapports Ads, qui ne dépendent que de l'étape 1. L'étape 3 est donc mise en œuvre
> la première. La liste d'exclusion reste la **première tâche avant tout code d'auteur** (section 7).

L'analyse juridique reste dans la décision 013 ; celle-ci ne traite que de la conception.

## Décision

### 1. Un mécanisme générique

- **Une seule table de correspondance**, `mapping.text_code`, dans le schéma séparé `mapping`.
- Chaque ligne a une **nature**, prise dans la table de référence `mapping.nature`. Natures prévues :

| Nature | Texte | Décision |
|---|---|---|
| `author` | nom d'auteur affiché | 013 |
| `search_term` | terme de recherche | 018 |
| `targeting` | ciblage | 018 |
| `campaign` | nom de campagne | 018 |
| `ad_group` | nom de groupe de publicités | 018 |
| `product_title` | titre du produit promu | 018 |

- **Unicité sur (nature, clé)** : un même texte a un code par nature, et deux natures différentes donnent deux codes.
- La nature n'est vérifiée qu'à un endroit, la table `mapping.nature`, lue par la clé étrangère et par la fonction.
  Ajouter une nature revient à insérer une ligne dans une migration.

### 2. Le code

- **Tiré d'une séquence** (`bigint`, colonne d'identité), **jamais une empreinte du texte** : un texte court se
  devinerait par dictionnaire à partir de son empreinte.
- **Une séquence commune à toutes les natures** : le code ne contient rien du texte, ni même sa nature.
- **Jamais réattribué** : une séquence ne revient pas en arrière, même après une suppression ou une transaction annulée.
- Il révèle l'**ordre d'apparition** des textes, pas leur contenu (risque accepté, section 9).

### 3. La clé

- **Stockée telle que l'appelant la donne.** Les règles de normalisation (casse, espaces, forme Unicode) appartiennent à
  chaque utilisateur et seront décidées aux étapes 2 et 3. « Camille Exemple » et « camille exemple » sont deux clés.
- **Refusée**, jamais corrigée :
  - `NULL` ;
  - vide, ou faite seulement de séparateurs déjà rencontrés (espace, tabulation, retour chariot, saut de ligne,
    U+00A0, U+202F) ;
  - **plus de 2 000 octets** : un index ordinaire ne peut pas contenir une valeur de plus de 2 700 octets environ ; la
    limite remplace l'erreur obscure de l'index par un refus clair. Les titres et les termes observés sont très en deçà.
- Les mêmes règles sont des contraintes de la table : une insertion directe par le propriétaire ne peut pas les
  contourner.
- **Identifiant d'auteur Amazon** : colonne `amazon_author_id`, prévue dès maintenant, réservée à la nature `author`,
  unique quand elle est remplie. Elle n'est **pas remplie à l'étape 1** ; la manière d'identifier un auteur (par cet
  identifiant ou par le nom affiché) relève de l'étape 2.
- **Aucune clé étrangère** ne pointera vers `mapping.text_code` depuis STAGING : la suppression d'une correspondance
  (décision 013, section 6) doit laisser les codes en place.

### 4. La fonction `mapping.code_for(nature, clé)`

- Elle **rend le code** du texte, et le **crée** s'il n'existe pas.
- **Idempotente** : deux appels avec le même texte et la même nature rendent le même code, y compris entre deux
  transactions concurrentes. `INSERT … ON CONFLICT DO NOTHING` fait attendre la seconde transaction jusqu'à la fin de
  la première ; la fonction relit alors la ligne validée.
- **Isolation** : ce comportement suppose l'isolation par défaut (`READ COMMITTED`). En `REPEATABLE READ` ou au-delà,
  la ligne créée par l'autre transaction reste invisible : l'appel échoue avec une erreur de sérialisation (`40001`),
  explicite, sans jamais rendre un code faux.
- **Refus explicites** : nature `NULL` ou inconnue (`22023`), clé `NULL` (`22004`), clé vide ou blanche (`22023`),
  clé trop longue (`22023`, avec le seul nombre d'octets).
- **Aucun message d'erreur ne contient la clé, ni la nature reçue** (un texte passé par erreur à la place de la nature
  ne doit pas apparaître non plus). `ON CONFLICT` évite l'erreur d'unicité de PostgreSQL, dont le message recopierait
  la valeur.

### 5. Sécurité

- **Rôle dédié `books_mapping`** : sans connexion (`NOLOGIN`), sans aucun attribut, sans membre, membre d'aucun rôle.
  Il possède le schéma `mapping`, ses deux tables, la séquence et la fonction.
- **`SECURITY DEFINER`** : la fonction s'exécute avec les droits de `books_mapping`, seul à lire la table. Comme un
  guichet : l'appelant tend un texte et reçoit un numéro, sans jamais voir le registre.
- **`search_path` figé** à `pg_catalog, pg_temp`, et **tous les noms qualifiés** par leur schéma : un appelant ne peut pas
  substituer une table ou une fonction en plaçant un schéma piège en tête de son `search_path`. `pg_temp` est nommé en
  **dernier** : s'il n'était pas cité, PostgreSQL le chercherait en premier pour les tables.
- **Droits**, dans la même migration que la création :
  - `REVOKE EXECUTE … FROM PUBLIC` sur la fonction (règle de la décision 013, note du 11 octobre 2026) ;
  - `USAGE` sur le schéma et `EXECUTE` sur la fonction, accordés nommément au **seul `books_transformer`** ;
  - **aucun droit** sur les tables ni sur la séquence, pour aucun rôle : `books_transformer` obtient un code, jamais un
    texte ; `books_collector` et `books_reader` n'ont rien (liste blanche de la décision 016).
- Le propriétaire de la base, superutilisateur, lit tout : c'est conforme au modèle de menace de la décision 016
  (erreurs humaines, pas un intrus).

### 6. Règle pour les utilisateurs de la fonction (étapes 2 et 3)

- **Toujours passer la clé en paramètre lié**, jamais écrite dans le texte de la requête. Un appel qui échoue peut être
  recopié dans le journal du serveur avec sa requête : un texte écrit en clair y apparaîtrait. Avec un paramètre lié,
  le journal ne montre que `$2` (PostgreSQL 17 ne journalise pas les paramètres en cas d'erreur, par défaut).
- Appeler la fonction dans la même transaction que l'écriture dans STAGING : une transaction annulée n'abandonne aucune
  correspondance.
- Ne jamais copier un texte reçu dans STAGING, dans un motif d'échec ou dans un bilan : seulement le code.

### 7. Liste d'exclusion : première tâche de l'étape 2

- La liste d'exclusion (décision 013, section 6) est **hors de l'étape 1**, mais le schéma ne l'empêche pas : elle sera
  une table du schéma `mapping`, consultée par la fonction avant toute création de code.
- **Elle sera la première tâche de l'étape 2, avant que l'extracteur appelle la fonction.** Sans elle, la suppression
  d'une correspondance après une opposition ne suffit pas : au passage suivant de l'extracteur, le même texte recevrait
  un **nouveau** code (section 2 : un code n'est jamais réattribué), et ses données futures seraient de nouveau reliées
  à une personne.

### 8. Tests et contre-épreuves

- **Tests SQL** (`tests/sql/test_010_correspondance.sql`), en tant que propriétaire, dans une transaction annulée :
  - catalogue : propriété des objets, rôle sans connexion ni membre, fonction `SECURITY DEFINER` à `search_path` figé,
    non `STRICT`, exécution réservée à `books_transformer`, aucun droit sur les tables, six natures ;
  - idempotence ; natures distinctes ; clé stockée telle quelle (casse et espace initiale distinguées) ; code entier ;
  - refus des entrées invalides, sans création de ligne et sans clé dans le message ; limite exacte de 2 000 octets ;
  - droits : `books_transformer` ne lit, n'écrit ni n'utilise la séquence ; `books_reader` et `books_collector` n'ont
    ni lecture ni exécution ;
  - détournement par `search_path` : fausses tables dans un schéma en tête du `search_path` et dans `pg_temp` ignorées ;
    **contre-épreuve** : deux copies fautives de la fonction (sans `search_path` figé ; sans `pg_temp` en dernier) sont
    détournées, ce qui prouve que le piège fonctionne ;
  - après suppression d'une correspondance, un code neuf.
- **Concurrence** (`tests/python/test_correspondance_concurrence.py`, PostgreSQL jetable, deux connexions
  `books_transformer`) : la seconde attend la première et rend le même code ; si la première annule, la seconde crée
  sa propre ligne ; en `REPEATABLE READ`, erreur `40001` sans clé dans le message.
- **Liste blanche de `books_reader`** (`tests/sql/test_008_role_lecture.sql`) : la correspondance simulée est remplacée
  par la vraie ; liste des colonnes lisibles et des schémas visibles inchangée.
- **Contre-épreuves de la migration** (4 novembre 2026, PostgreSQL jetables) : quatre variantes fautives de la
  migration 010 (sans `REVOKE … FROM PUBLIC` ; sans `search_path` figé ; fonction `STRICT` ; `USAGE` du schéma accordé
  aussi à `books_reader`) sont toutes refusées par le test 010.
- **Contrôle de restauration** (décision 009) : `books_reader` ne voit pas `mapping`. Une requête lancée par le
  propriétaire, `sql/observations/comptes_correspondance.sql`, ne rend que le nombre de lignes par nature, sans aucune
  clé ; elle est citée à l'étape 6 de la restauration (README).

### 9. Risques

- **Ordre d'apparition** : un code séquentiel révèle l'ordre de création des textes, pas leur contenu. Accepté.
- **Copies** : la correspondance entre dans les sauvegardes `pg_dump` et les copies sur le PC (décision 013,
  section 2, « Limite assumée »). La restauration exige que `books_mapping` existe avant `pg_restore` (README, étape 2).
- **Unicode** : un même texte peut s'écrire sous deux formes Unicode (lettre accentuée composée ou décomposée), qui font
  deux clés. La normalisation reviendra à chaque utilisateur.

## Conséquences

- Migration 010 : rôle `books_mapping`, schéma `mapping`, tables `mapping.nature` et `mapping.text_code`, fonction
  `mapping.code_for`.
- Décision 013 : section 2 mise en œuvre pour l'étape 1 (note datée). La règle de la décision 011 (section 9) reste en
  vigueur : l'extracteur ne lit toujours aucun auteur.
- Décision 016 : nouveau schéma sans droit pour `books_reader` ; test de liste blanche mis à jour (note datée).
- Décision 018 : section 5 renvoie à cette décision (note datée).
- README : test 010, rôle `books_mapping` dans la restauration, comptes de la correspondance.
- Aucun déploiement sur atlas dans cette étape.
