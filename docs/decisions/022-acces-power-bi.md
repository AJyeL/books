# 022 — Accès de Power BI à CORE

Date : 11 novembre 2026 · **Acceptée** · Migration : `sql/migrations/016_role_bi.sql`

> Statut : **acceptée** le 11 novembre 2026 par le porteur du projet, avec quatre réponses intégrées au texte :
> `statement_timeout` de 5 minutes ; `.pbix` dans `D:\Veille Litteraire\books-powerbi\`, hors de tout dossier
> synchronisé ; aucun `.pbit` dans le dépôt pour l'instant ; `core.build_run` lisible par `books_bi`. Précision ajoutée :
> Power BI Desktop est gratuit et suffit (section 5).

## Contexte

CORE (décisions 020 et 021) est la couche destinée à l'analyse : classements du jour, attributs versionnés et mesures
des fiches. Le porteur du projet veut l'explorer et en tirer des tableaux de bord avec **Power BI Desktop**, sur son PC.

La base de production est sur atlas, dans le conteneur `books-postgres`, publiée sur `127.0.0.1:5433` seulement.
Aucun port n'est ouvert sur le réseau, et le rôle `books_reader` (décision 016) n'a pas de mot de passe : il ne sert
qu'aux connexions faites dans le conteneur. La décision 016 (section 6) prévoyait qu'un tunnel ferait l'objet de sa
propre décision, avec son mot de passe : c'est celle-ci.

Règles tranchées par le porteur du projet (11 novembre 2026) :
1. Chemin : un tunnel SSH depuis le PC (`localhost:15433` vers `127.0.0.1:5433` sur atlas) ; aucun port ouvert sur le
   réseau.
2. Un nouveau rôle `books_bi`, qui ne lit que CORE (tables et vue). Il n'a aucun droit sur RAW, STAGING, guide, mapping
   ni sur les données Ads, et n'exécute aucune fonction. Il a les mêmes garde-fous que `books_reader` : lecture seule
   par défaut, `statement_timeout`, `idle_in_transaction_session_timeout`, `CONNECTION LIMIT 2`.
3. Le mot de passe reste hors du dépôt : la migration crée le rôle sans mot de passe, et le porteur du projet le
   définit lui-même sur atlas. Les connexions par mot de passe doivent utiliser `scram-sha-256`.
4. Power BI en mode Importation. Le `.pbix` contient des données réelles : `*.pbix` est ignoré par Git, et on ne fait
   **jamais « Publier sur le web »**.
5. Un modèle de menace explicite.

## Décision

### 1. Chemin de la connexion

```
Power BI Desktop (PC) ──► localhost:15433 (PC) ══ tunnel SSH ══► 127.0.0.1:5433 (atlas) ──► books-postgres:5432
```

- Le tunnel est ouvert à la main depuis PowerShell, avec l'alias SSH `atlas` existant, et refermé à la fin de la
  séance. Sur le PC, l'écoute se fait sur `127.0.0.1:15433` seulement, jamais sur une adresse du réseau local.
- Sur atlas, rien ne change : le port `5433` reste publié sur `127.0.0.1` seulement, et aucun port n'est ouvert.
- **Chiffrement** : le trajet sur le réseau est chiffré par SSH. Entre le service SSH d'atlas et PostgreSQL, la
  connexion passe par la boucle locale d'atlas, sans chiffrement : PostgreSQL a `ssl = off` (constat du 11 novembre
  2026 sur l'image `postgres:17`). Power BI doit donc se connecter **sans** chiffrement PostgreSQL. C'est voulu, et
  sans risque supplémentaire, puisque ce dernier trajet ne quitte pas atlas.

### 2. Authentification (constat sur l'image `postgres:17`, 11 novembre 2026)

| Règle de `pg_hba.conf` | Méthode |
|---|---|
| socket local, `127.0.0.1/32`, `::1/128` (dans le conteneur) | `trust` |
| toute autre adresse | `scram-sha-256` |

- `password_encryption = scram-sha-256` : le mot de passe défini avec `\password` est enregistré sous forme de condensé
  SCRAM, jamais en clair.
- Une connexion qui arrive par le port publié vient d'une autre adresse que `127.0.0.1` du conteneur. C'est la règle
  `scram-sha-256` qui s'applique : le mot de passe est vérifié par défi-réponse, sans jamais circuler. La recette de la
  décision 016 l'a constaté (mot de passe exigé, mauvais mot de passe refusé). La recette de cette décision le revérifie
  sur atlas.
- Les règles d'authentification de l'image ne sont pas modifiées.

### 3. Le rôle `books_bi` (migration 16)

- `CREATE ROLE books_bi LOGIN CONNECTION LIMIT 2`, sans aucun autre attribut, membre d'aucun rôle, **sans mot de
  passe** (il est défini à la main sur atlas, section 6).
- Garde-fous de session :

  | Réglage | Valeur | Pourquoi |
  |---|---|---|
  | `default_transaction_read_only` | `on` | comme `books_reader` |
  | `statement_timeout` | `5min` | une importation complète lit des tables entières (`books_reader` a `2min`) |
  | `idle_in_transaction_session_timeout` | `5min` | une transaction oubliée ne bloque pas une construction de CORE ni une migration |
  | `CONNECTION LIMIT` | `2` | pas d'accumulation de connexions oubliées |

- Droits, en liste blanche :
  - `USAGE` sur le schéma `core` ;
  - `SELECT` sur toutes ses tables (`build_run`, `book`, `category`, `category_name`, `list_day`, `ranking_day`, les dix
    `book_*_version`, `product_day`, `product_day_category_rank`) et sur la vue `core.book_current`.
- La vue est en `security_invoker` : elle lit les tables avec les droits de `books_bi`, qui les a. Elle ne lui donne
  donc rien de plus.
- **Rien d'autre** : aucun droit sur `raw`, `staging`, `guide` et `mapping`, et donc aucun sur les tables Ads, qui sont
  dans `raw` et `staging`. Aucune fonction : celles de `core` sont fermées à `PUBLIC`. Aucune écriture, aucune
  séquence, aucune création (`TEMPORARY` est retiré à `PUBLIC` depuis la migration 002, et PostgreSQL 17 n'accorde pas
  `CREATE` sur `public`).
- **Règle pour l'avenir**, comme pour `books_reader` : aucun privilège par défaut. Toute migration qui ajoute une table
  ou une colonne à `core` accorde explicitement `SELECT` à `books_bi`. Si elle l'oublie, le test 016 échoue (section 7).

### 4. Commentaire du rang général (avertissement reporté de la décision 021)

La migration 16 est la « prochaine migration » prévue par la note du 11 novembre 2026 de la décision 021. Elle remplace
le commentaire de `core.product_day.general_rank` par :

> Rang général de la fiche ; NULL : non affiché ce jour-là, le rang de la veille n'est jamais reporté. Trois portées :
> boutique entière payante, boutique entière gratuite, sous-boutique (general_rank_category_node renseigné). Ne comparer
> des rangs généraux qu'à portée égale (general_rank_store, general_rank_list_type, general_rank_category_node) ; le
> rang de la boutique entière est celui dont general_rank_category_node est NULL.

Le texte exact sera relu au commit. Le schéma ne change pas. L'avertissement sera visible dans Power BI pour qui lit
les descriptions des colonnes.

### 5. Power BI : mode Importation, fichiers, publication

- **Mode Importation** : Power BI copie les tables de CORE dans le `.pbix` et ne relit atlas qu'à l'actualisation,
  faite à la main, tunnel ouvert. Le mode DirectQuery est exclu : chaque visuel interrogerait atlas en permanence, et le
  tunnel devrait rester ouvert.
- **Le `.pbix` contient des données réelles** : titres, prix, rangs, noms de catégories et ASIN.
  - `*.pbix` est ajouté au `.gitignore` ;
  - le fichier est enregistré dans **`D:\Veille Litteraire\books-powerbi\`**, hors du dépôt et **hors de tout dossier
    synchronisé** (OneDrive compris) : une synchronisation copierait les données réelles dans un nuage tiers ;
  - il n'est ni envoyé ni partagé.
- **Jamais « Publier sur le web »** : cela rend un rapport public, sans authentification, et indexable.
- **Pas de publication vers le service Power BI** (le nuage de Microsoft) non plus : ce serait confier des données à un
  tiers, et il faudrait une passerelle pour actualiser depuis atlas. Une telle publication demanderait une décision
  dédiée.
- **Aucun modèle `.pbit` dans le dépôt** pour l'instant (requêtes et mise en page, sans données) : à décider au premier
  tableau de bord qui mériterait d'être versionné.
- **Power BI Desktop est gratuit et suffit** : aucune licence (Pro, Premium) n'est nécessaire, puisque rien n'est publié
  dans le service Power BI. Les licences ne concernent que le partage et l'actualisation dans le service.

### 6. Procédure pour le porteur du projet (après déploiement de la migration 16)

**Sur atlas, une fois : définir le mot de passe**

1. Ouvrir une session `psql` du propriétaire dans le conteneur (session interactive, d'où `-it`) :

   ```bash
   cd ~/books && docker compose exec -it postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
   ```

2. Dans `psql`, définir le mot de passe : `\password books_bi`. Le saisir deux fois. Il est condensé par `psql` avant
   l'envoi, et n'apparaît ni à l'écran ni dans l'historique. Le générer et le ranger dans le gestionnaire de mots de
   passe ; **jamais dans `.env`**, aucun programme du projet ne s'en servant.
3. Toujours dans `psql`, vérifier qu'il est bien enregistré en SCRAM : la requête rend `t`, sans montrer le condensé.

   ```sql
   SELECT rolpassword LIKE 'SCRAM-SHA-256$%' FROM pg_authid WHERE rolname = 'books_bi';
   ```

4. `\q` pour quitter.

**Sur le PC, à chaque séance : ouvrir le tunnel** dans une fenêtre PowerShell, laissée ouverte pendant la séance :

```powershell
& "$env:WINDIR\System32\OpenSSH\ssh.exe" -N -o ExitOnForwardFailure=yes -L 127.0.0.1:15433:127.0.0.1:5433 atlas
```

- `-N` : aucune commande à distance, seulement le tunnel. `-L 127.0.0.1:15433:127.0.0.1:5433` : le port 15433 du PC,
  sur la boucle locale seulement, mène au port 5433 de la boucle locale d'atlas. `ExitOnForwardFailure=yes` : si le
  port 15433 est déjà pris, la commande s'arrête au lieu de rester ouverte sans tunnel.
- Après la saisie du mot de passe SSH, la fenêtre semble « figée » : c'est normal, le tunnel est ouvert.
- Pour le fermer : `Ctrl+C` dans cette fenêtre.

**Dans Power BI Desktop : se connecter**

1. Accueil › Obtenir les données › Base de données PostgreSQL.
2. Serveur : `localhost:15433`. Base de données : le nom de la base d'atlas (valeur de `POSTGRES_DB` dans le `.env`
   d'atlas). Mode de connectivité : **Importer**. Ne rien saisir dans les options avancées.
3. Identifiants : onglet « Base de données ». Nom d'utilisateur `books_bi`, et son mot de passe. Niveau :
   `localhost:15433;{base}`.
4. Chiffrement : Power BI essaie d'abord une connexion chiffrée, que PostgreSQL refuse (`ssl = off`), puis propose de
   se connecter **sans chiffrement** : accepter (section 1). Si une case « Chiffrer les connexions » apparaît dans les
   paramètres de la source, la décocher.
5. Le navigateur ne doit montrer que les tables et la vue du schéma `core` (avec, au plus, les noms de schémas du
   catalogue). Choisir les tables, puis Charger.
6. Enregistrer le `.pbix` dans `D:\Veille Litteraire\books-powerbi\` (section 5).

**Vérifier qu'une requête hors de CORE est refusée** (une fois, à la recette) :

1. Obtenir les données › Base de données PostgreSQL › même serveur et même base › Options avancées › Instruction SQL :
   `SELECT count(*) FROM staging.ranking_entry`.
2. Attendu : un refus `permission denied for schema staging`.
3. Même essai avec `SELECT count(*) FROM raw.raw_page` (refus sur `raw`), puis avec `SELECT count(*) FROM core.book`
   (accepté : un nombre).

### 7. Tests (test 016)

Test SQL `tests/sql/test_016_role_bi.sql`, même principe que le test 008 : lancé par le propriétaire, il endosse
`books_bi` (`SET LOCAL ROLE`) ; tout est annulé à la fin.

1. **Attributs** : connexion permise, aucun autre attribut, membre d'aucun rôle (ni `books_reader`, ni
   `pg_read_all_data`), `CONNECTION LIMIT 2`, les trois réglages présents dans le catalogue.
2. **Liste blanche, par le catalogue** :
   - les colonnes lisibles par `books_bi` sont **exactement toutes les colonnes de toutes les tables et vues de `core`** ;
   - ni plus (aucune colonne d'un autre schéma), ni moins. Une table ajoutée à `core` sans `GRANT` à `books_bi` fait
     donc échouer le test ;
   - leur nombre est aussi écrit en dur : 236 aujourd'hui, mis à jour à chaque migration qui touche `core`, comme le
     test 008.
3. **Schémas visibles** : `core` et `public` (par `PUBLIC`) seulement. Aucun droit de création, ni de table temporaire.
4. **Fonctions et séquences** : aucune fonction exécutable hors du catalogue système, aucune séquence utilisable.
5. **Écritures refusées** sur chaque table de `core` (`INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`), même après
   `SET default_transaction_read_only = off`.
6. **Lectures refusées** : `raw.raw_page`, `raw.ads_report_file`, `staging.ranking_entry`, `staging.ads_product_day`,
   `guide.reference_entry`, la correspondance `mapping` ; `core.rebuild` non exécutable. **Lectures permises** : une
   table de `core`, et la vue `core.book_current`.
7. **Commentaire** : celui de `core.product_day.general_rank` mentionne les trois portées et le nœud `NULL`.

Les tests 005 à 015 sont relancés. Le test 008 est inchangé : `books_reader` ne gagne ni ne perd rien.

**Contre-épreuves** (mutation de la migration 16 dans un PostgreSQL 17 jetable), chacune doit faire échouer un test :
- `SELECT` sur une table de `staging` accordé à `books_bi` (2) ;
- `USAGE` sur `raw` accordé (3) ;
- une table de `core` oubliée dans le `GRANT` (2) ;
- `books_bi` membre de `books_reader` (1) ;
- `EXECUTE` sur `core.rebuild` accordé (4) ;
- `INSERT` sur une table de `core` (5) ;
- réglage `default_transaction_read_only` retiré (1) ;
- privilèges par défaut sur `core` (2 : la liste n'est plus tenue par la migration) ;
- commentaire non remplacé (7).

### 8. Restauration d'essai

- `pg_dump` ne sauvegarde ni les rôles ni leurs réglages. L'étape 2 de la procédure du README crée **`books_bi` avec
  ses réglages** avant `pg_restore`, à côté des quatre autres rôles ; sans cela, `--exit-on-error` arrêterait la
  restauration sur ses droits.
- Le mot de passe n'est pas dans la sauvegarde : après une restauration qui doit servir à Power BI, il est redéfini
  (`\password`), différent dans chaque environnement.
- Étape 6 : tests SQL **005 à 016**. Le test 016 contrôle les attributs, les réglages et la liste blanche de `books_bi`.

### 9. Modèle de menace

**Ce qui est protégé, et contre quoi :**
- **L'exposition réseau** : aucun port n'est ouvert, ni sur atlas ni sur le réseau local du PC (tunnel sur
  `127.0.0.1`). Atteindre PostgreSQL demande l'accès SSH à atlas, la même barrière qu'aujourd'hui.
- **L'interception** : le trajet sur le réseau est chiffré par SSH, et le mot de passe n'y circule jamais (SCRAM).
- **Les erreurs et les débordements depuis Power BI** : `books_bi` ne peut rien écrire, et il ne voit ni les adresses
  de RAW (identifiant de session), ni les textes de description, ni les noms d'auteurs (`mapping`), ni les données Ads.
  Une requête trop lourde est interrompue, une connexion oubliée est fermée, et il a au plus deux connexions.
- **La minimisation** : le `.pbix` ne peut contenir que ce que CORE contient. Cela exclut les textes de description
  (CORE n'en garde qu'une empreinte) et les noms d'auteurs.

**Ce qui n'est pas protégé :**
- **Un intrus qui a l'accès SSH à atlas** : il peut tout faire, avec le rôle propriétaire (connexion locale du
  conteneur en `trust`). `books_bi` n'y change rien (décision 016, section 1).
- **Le PC** :
  - le `.pbix` contient des données réelles en clair ;
  - Power BI garde les identifiants dans le profil Windows de l'utilisateur, chiffrés pour ce profil ;
  - tunnel ouvert, tout programme du PC peut se connecter à `localhost:15433`, avec le mot de passe ;
  - quiconque a accès à la session Windows, ou à une sauvegarde non chiffrée du PC, lit le `.pbix`.
- **Une erreur de publication** : « Publier sur le web », ou un `.pbix` envoyé par erreur, divulguerait les données.
  La règle de la section 5 est une discipline, pas un verrou technique.
- **Le contenu de CORE lui-même** : les titres et les noms de séries peuvent citer un nom d'auteur (accepté par la
  décision 015, section 6). Ils entrent dans le `.pbix`.
- **Le cadre juridique** : un tableau de bord privé reste soumis à la réserve de la décision 005. L'avis d'un juriste
  est requis avant toute exploitation commerciale, et donc avant tout partage d'un rapport.

## Conséquences

- Migration 16 : rôle, réglages, droits sur `core`, commentaire du rang général. Test 016 et ses contre-épreuves.
- `.gitignore` : `*.pbix`.
- README : section « Power BI (rôle books_bi) » reprenant la procédure de la section 6 ; restauration (rôle de plus,
  tests 005 à 016) ; tests.
- Décision 016 : note datée (second rôle de lecture, liste blanche propre, tunnel décidé ici).
- Aucune modification de `docker-compose.yml`, de `pg_hba.conf` ni des scripts d'envoi.
- Recette sur atlas, par le porteur du projet : mot de passe défini et en SCRAM ; tunnel ouvert ; Power BI connecté,
  tables de `core` importées ; requête sur `staging` et sur `raw` refusée ; mauvais mot de passe refusé.

## Risques

- **`.pbix` oublié dans un dossier synchronisé** (OneDrive, etc.) ou joint à un message : des données réelles sortent.
  Le `.gitignore` ne protège que du dépôt.
- **Tunnel laissé ouvert** : la porte reste entrebâillée sur le PC (protégée par le mot de passe). La fermer à la fin de
  la séance.
- **Importation pendant une construction de CORE** : Power BI lit l'ancien contenu, entier et cohérent (MVCC, décision
  020). Une actualisation pendant une migration pourrait en revanche attendre ou échouer.
- **Volume** : une importation complète de `core.ranking_day` grossira avec le temps ; `statement_timeout` à `5min`
  pourrait un jour être juste.
- **Changement de schéma** : une colonne renommée dans CORE casse les requêtes Power BI, qui doivent être adaptées
  (comme lors du renommage des jours au lot 2).

## Questions tranchées le 11 novembre 2026

1. `statement_timeout` de `books_bi` : `5min`.
2. Emplacement du `.pbix` : `D:\Veille Litteraire\books-powerbi\`, hors de tout dossier synchronisé (OneDrive compris).
3. Modèles `.pbit` : aucun dans le dépôt pour l'instant.
4. `core.build_run` : lisible par `books_bi` (fraîcheur et version de CORE dans les rapports).

> Note du 11 novembre 2026 (**mise en œuvre**) :
> - Migration 016 appliquée en développement ; test 016 conforme (21 contrôles) ; tests 005 à 015 inchangés et
>   conformes (test 008 : liste blanche de `books_reader` inchangée).
> - **Contre-épreuves** (mutation de la migration 016 dans un PostgreSQL 17 jetable, rôle supprimé entre deux cas) :
>   10 mutations, toutes refusées par le test prévu ; témoins (tests 016 et 008 sur la migration intacte) conformes.
>   `SELECT` sur une table de `staging` (2) ; `USAGE` sur `raw` (3) ; table de `core` oubliée dans le `GRANT` (2) ;
>   membre de `books_reader` (1) ; `EXECUTE` sur `core.rebuild` (4) ; `INSERT` sur `core` (5) ; lecture seule par défaut
>   retirée (1) ; privilèges par défaut sur un autre schéma (2) ; commentaire du rang général non remplacé (7) ; limite
>   de connexions retirée (1).
> - **Garde-fou** de la migration (relecture) : `IS DISTINCT FROM 15`, et non `<> 15`. Un registre vide donne un maximum
>   `NULL`, et « `NULL <> 15` » ne déclencherait pas l'exception. Contre-épreuve : registre vide et base à la version 14
>   refusés par la migration ; avec la mutation `<> 15`, le registre vide passe.
> - Commande de restauration du README (création des cinq rôles) exécutée dans un PostgreSQL jetable : rôles, limites et
>   réglages conformes.
> - `.gitignore` : `*.pbix`. Recette sur atlas à faire par le porteur du projet (section 6) : mot de passe en SCRAM,
>   tunnel, connexion de Power BI, refus d'une requête sur `staging` et sur `raw`, mauvais mot de passe refusé.

> Note du 11 novembre 2026 (**recette sur atlas**, rapportée par le porteur du projet) :
> - Recette réussie : tunnel, mot de passe en SCRAM, refus sur `staging` et sur `raw`, lecture de `core.book`.
> - **Erreur `53300` (« too many connections »)** : après trois requêtes enchaînées, une quatrième a été refusée. Cause :
>   le **réservoir de connexions** de Power BI, qui garde ouvertes quelques instants les connexions de ses requêtes
>   précédentes ; deux connexions inactives occupaient les deux places de `CONNECTION LIMIT 2`. Mesure : quelques
>   instants plus tard, une seule connexion `idle` restait (`pg_stat_activity`), et la requête est passée.
> - **Conduite retenue** : la limite reste à 2, sans migration. Deux réglages du fichier Power BI réduisent le nombre de
>   connexions simultanées (chargement en parallèle des tables sur « Un », aperçus en arrière-plan désactivés) ; en cas
>   d'erreur `53300`, attendre quelques instants puis réessayer (procédure du README, section « Power BI »).
> - **Règle de révision** : la limite n'est relevée, par une migration, que si une actualisation réelle s'y heurte
>   malgré ces réglages ; une requête d'essai refusée ne suffit pas.

> Note du 11 novembre 2026 (**règle de révision remplie : limite portée à 5**, migration 017) :
> - **Constat** : une actualisation réelle s'est heurtée à `CONNECTION LIMIT 2`, malgré les deux réglages du fichier
>   (chargement en parallèle sur « Un », aperçus en arrière-plan désactivés). Modèle : `core.ranking_day` fusionnée
>   (jointure interne) avec `core.list_day` dans Power Query. Erreur « 53300: too many connections for role books_bi »
>   sur `ranking_day`, puis chargement de `list_day` annulé.
> - **Cause** : une table fusionnée lit sa source de jointure en même temps qu'elle, d'où au moins deux connexions pour
>   une seule table, auxquelles s'ajoute le réservoir de connexions de l'éditeur.
> - **Nouvelle valeur** : `CONNECTION LIMIT 5` (migration 017, garde-fou `IS DISTINCT FROM 16`). Les droits et les autres
>   réglages de `books_bi` ne changent pas. Test 016 mis à jour (limite 5), commande de restauration du README aussi.
>   Contre-épreuves : migration 017 sans `ALTER`, ou avec une autre limite, refusée par le test 1 ; garde-fou : registre
>   vide et base à la version 15 refusés, et la mutation `<> 16` laisse passer le registre vide.
