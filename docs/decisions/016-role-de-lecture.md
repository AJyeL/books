# 016 — Rôle de lecture pour les explorations SQL

Date : 11 octobre 2026

> Statut : **adoptée** le 11 octobre 2026 par le porteur du projet, avec trois précisions intégrées au texte (modèle de
> menace, numérotation, identifiant de session ajouté aux données personnelles de la décision 015).

## Contexte

Le porteur du projet veut explorer les données en SQL, sur atlas comme en développement. Aujourd'hui, seuls trois rôles
existent :
- le **propriétaire** de la base (`POSTGRES_USER`), qui peut tout faire, y compris supprimer des tables ;
- `books_collector` (décision 003, migration 002), qui écrit dans RAW ;
- `books_transformer` (décision 011, migration 005), qui écrit dans STAGING.

Explorer avec l'un d'eux exposerait la base de production à une erreur de frappe (`DELETE` sans `WHERE`, `DROP` dans le
mauvais terminal). Une requête trop lourde, ou une transaction laissée ouverte, pourrait aussi gêner l'ingestion,
l'extraction ou une migration.

La décision 013 prévoit en outre un **schéma séparé** pour la correspondance « code → nom affiché et identifiant d'auteur
Amazon », que les rôles d'analyse ne doivent jamais lire.

## Décision

### 1. Modèle de menace

Le rôle `books_reader` protège contre les **erreurs humaines** :
- écriture accidentelle ;
- requête trop lourde ;
- transaction oubliée.

Il **ne protège pas contre un intrus**.
- La connexion locale du conteneur `books-postgres` ne demande pas de mot de passe (section 6). Quiconque peut lancer
  `docker compose exec` sur atlas peut se connecter sous n'importe quel rôle, propriétaire compris.
- La barrière contre un intrus reste l'**accès SSH à atlas**, avec PostgreSQL publié sur `127.0.0.1` seulement.

Le rôle n'est donc pas une frontière de sécurité. C'est un garde-fou pour le travail quotidien, et un moyen de garantir
qu'une exploration ordinaire ne voit jamais certaines données (section 4).

### 2. Le rôle

- `books_reader`, avec le droit de connexion (`LOGIN`), sans aucun autre attribut : ni superutilisateur, ni création de
  base ou de rôle, ni réplication, ni contournement des règles de lignes. Il n'est **membre d'aucun rôle**, ni des rôles
  prédéfinis `pg_read_all_data` et `pg_read_server_files`.
- Créé par la **migration 008**, donc en développement et en production, comme les autres rôles.
- **Mot de passe** : défini à la main (`\password`), différent dans chaque environnement, gardé dans le gestionnaire de
  mots de passe du porteur du projet. **Il n'est pas dans `.env`** : aucun programme du projet ne s'en sert. Il ne sert
  qu'aux connexions par le port publié (section 6).

### 3. Droits exacts (liste blanche)

| Objet | Droit |
|---|---|
| Schéma `staging` | `USAGE` |
| `staging.extract_run`, `page_extraction`, `ranking_entry`, `category_observation`, `product_observation`, `product_format`, `product_sales_rank`, `product_rating_share` | `SELECT` |
| Schéma `raw` | `USAGE` |
| `raw.collect_run` | `SELECT` |
| `raw.raw_page` | `SELECT` sur **toutes les colonnes sauf `requested_url` et `final_url`** (droit par colonne) |
| `public.schema_migration` | `SELECT` |

Rien d'autre :
- aucun droit d'écriture ;
- aucun droit sur les séquences ;
- aucune fonction hors du catalogue système ;
- aucune création d'objet.

Le droit `TEMPORARY` est retiré à `PUBLIC` depuis la migration 002. PostgreSQL 17 n'accorde plus `CREATE` sur le schéma
`public`. Les requêtes avec `WITH` remplacent les tables temporaires.

Un droit par colonne interdit `SELECT * FROM raw.raw_page` : il faut nommer les colonnes permises.

### 4. Ce que le rôle ne voit jamais

1. **La correspondance de la décision 013** (noms d'auteurs, identifiants d'auteur Amazon) :
   - aucun droit sur son schéma ni sur ses tables ;
   - **toute fonction de ce schéma est fermée à `PUBLIC`** (`REVOKE EXECUTE … FROM PUBLIC`, dans la migration qui la
     crée), car PostgreSQL accorde par défaut l'exécution de toute nouvelle fonction à tous les rôles. Règle inscrite
     dans la décision 013.
2. **Les adresses affichées** (`requested_url`, `final_url`) : le paramètre `ref=` peut y porter l'**identifiant de
   session** Amazon du navigateur de veille, une donnée personnelle du porteur du projet (décision 015, section 2).
   - Relevé du 11 octobre 2026 : il est présent dans l'adresse affichée de 256 des 431 fiches de l'inventaire.
   - L'ASIN, la catégorie, la liste et la page suffisent à l'analyse.
3. **Les pages HTML** : elles ne sont pas dans la base mais sur disque (`~/books-data/raw`). Elles contiennent la mention
   de livraison, les avis et l'identifiant de session. Le rôle n'a aucun moyen de lire un fichier du serveur.

Il voit, et c'est accepté :
- les titres et descriptions de STAGING, qui peuvent citer un nom d'auteur (règle de la décision 015, section 6) ;
- la **structure** de la base (noms des schémas, tables et colonnes, lisibles par tous dans le catalogue), jamais le
  contenu d'une table hors de sa liste.

### 5. Réglages du rôle (garde-fous)

| Réglage | Valeur | Rôle |
|---|---|---|
| `default_transaction_read_only` | `on` | chaque transaction est en lecture seule par défaut |
| `statement_timeout` | `2min` | une requête trop lourde est interrompue |
| `idle_in_transaction_session_timeout` | `5min` | une transaction oubliée est fermée, et ne bloque plus une migration |
| `CONNECTION LIMIT` | `2` | pas d'accumulation de connexions oubliées |

Ces réglages ne sont pas la sécurité du rôle : `default_transaction_read_only` peut être désactivé dans une session.
La lecture seule vient de l'**absence de droits d'écriture** ; le test 8 le prouve.

### 6. Connexion

Constat du 11 octobre 2026, sur le conteneur de développement (image officielle `postgres:17`, même `docker-compose.yml`
qu'en production) : les règles d'authentification (`pg_hba.conf`) sont `trust` pour le socket local **et pour
`127.0.0.1`** dans le conteneur, `scram-sha-256` pour toute autre adresse. Une connexion faite dans le conteneur, même
avec `-h 127.0.0.1`, ne demande donc aucun mot de passe.

- **Connexion retenue**, sur atlas (ssh, puis) comme en développement :

  ```bash
  cd ~/books && docker compose exec postgres sh -c 'psql -U books_reader -d "$POSTGRES_DB"'
  ```

  Aucun mot de passe n'est demandé (section 1). Ce qui compte : la session est celle de `books_reader`, avec ses seuls
  droits et ses garde-fous.
- **Par le port publié** (`127.0.0.1:5433` de l'hôte, par exemple plus tard un outil graphique sur le PC via un tunnel
  SSH) : la connexion arrive d'une autre adresse que `127.0.0.1` du conteneur, donc avec mot de passe vérifié (SCRAM).
  C'est le seul usage du mot de passe. Le tunnel n'est pas mis en place par cette décision.
- Les règles d'authentification de l'image ne sont pas modifiées : le modèle de menace (section 1) ne le demande pas.

### 7. Règles pour l'avenir

- **Aucun privilège par défaut** (`ALTER DEFAULT PRIVILEGES`). Chaque migration qui crée une table ou une fonction
  décide explicitement si `books_reader` y a accès. Un oubli laisse l'objet fermé : l'échec est sûr.
- La liste attendue du test de liste blanche (test 6) est mise à jour **dans la même migration**. Un droit accordé sans
  mise à jour du test le fait échouer.
- Les colonnes d'adresse de RAW restent fermées tant qu'elles peuvent porter un identifiant de session.

### 8. Tests et contre-épreuves

Test SQL `tests/sql/test_008_role_lecture.sql`, même principe que les tests 005 à 007 :
- lancé par le propriétaire, il prépare des lignes, endosse `books_reader` (`SET LOCAL ROLE`) ;
- tout est annulé à la fin, puis il vérifie qu'aucune ligne de test n'est restée.

1. Lecture permise sur chaque table de la liste, et sur les colonnes permises de `raw.raw_page`.
2. Lecture refusée de `requested_url` et de `final_url`, et de `SELECT * FROM raw.raw_page`.
3. `INSERT`, `UPDATE`, `DELETE` et `TRUNCATE` refusés sur chaque table.
4. `CREATE TABLE` refusé dans `public`, `raw` et `staging` ; `CREATE TEMP TABLE` refusé.
5. Le rôle peut se connecter, sans aucun autre attribut. Il n'est membre d'aucun rôle, en particulier ni de
   `books_transformer`, ni de `books_collector`, ni de `pg_read_all_data`, ni de `pg_read_server_files`.
6. **Liste blanche** :
   - toutes les colonnes lisibles par `books_reader`, dans tous les schémas hors catalogue système, sont égales à la
     liste attendue ;
   - aucune fonction exécutable hors du catalogue système ;
   - une correspondance de la décision 013 est simulée dans la transaction (schéma, table, fonction
     `SECURITY DEFINER` fermée à `PUBLIC`) : rien n'en est lisible ni exécutable.
7. Réglages présents : lecture seule par défaut, délais, limite de connexions.
8. Lecture seule désactivée dans la session (`SET default_transaction_read_only = off`) : un `INSERT` reste refusé.

Les tests 005 à 007 sont relancés : les droits des deux autres rôles ne changent pas. L'extracteur refuse
`books_reader` comme tout autre rôle que le sien (test Python). Le collecteur n'a pas ce contrôle : avec ce rôle, sa
première écriture serait refusée par la base.

Contre-épreuves, chacune doit faire échouer le test indiqué :

| Mutation de la migration | Test en échec |
|---|---|
| `SELECT` sur toute la table `raw.raw_page` | 2 |
| `INSERT` sur une table de STAGING | 3 |
| `books_reader` membre de `books_transformer` | 5 |
| Privilèges par défaut accordant `SELECT` à `books_reader` sur les nouvelles tables | 6 |
| Fonction simulée de la correspondance sans `REVOKE EXECUTE … FROM PUBLIC` | 6 |
| Réglage `default_transaction_read_only` retiré | 7 |

Recette en développement :
- migration appliquée, tests 005 à 008 conformes ;
- connexion `docker compose exec` sans mot de passe, sous `books_reader` ;
- une requête d'exploration réelle répond ;
- une écriture est refusée ;
- par le port publié : mot de passe exigé, mauvais mot de passe refusé.

## Conséquences

- **Restauration** : une sauvegarde `pg_dump` ne contient ni les rôles ni leurs réglages. La procédure du README crée
  `books_reader` avec ses réglages avant le `pg_restore`, puis le test 008 le vérifie.
- **Copies sur le PC** (décision 009) : restaurées en développement, elles s'explorent avec le même rôle, sans risque
  pour la production.
- **Décision 013** : note ajoutée (règle du `REVOKE EXECUTE … FROM PUBLIC`).
- **Décision 015** : l'identifiant de session est ajouté aux données personnelles relevées (section 2).
- Un futur rôle de tableau de bord suivra le même modèle (liste blanche explicite, test de liste blanche) ; il fera
  l'objet de sa propre décision.
