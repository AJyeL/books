# 014 — Périmètre dynamique des catégories

Date : 10 octobre 2026

## Contexte

Le périmètre des catégories est fixé dans `config/targets.toml` (décisions 004 et 008) : une liste de numéros de
catégorie, avec leur nom et leurs listes. L'ingestion met en quarantaine toute capture d'une catégorie absente de cette
liste (« hors périmètre »). Le fichier est intégré à l'image Docker : ajouter une catégorie impose une modification du
dépôt, une reconstruction de l'image et un déploiement. Il publie aussi, dans un dépôt public, les catégories suivies.

Depuis la décision 005, la collecte est semi-manuelle : le porteur du projet choisit lui-même, en naviguant, les pages
qu'il affiche ; l'extension n'enregistre que des pages de classement. Le choix des catégories est donc déjà fait par une
personne, au moment de la navigation. La liste de `targets.toml` ne fait que le répéter, avec un temps de retard.

## Décision

### 1. Règle générale

- **Toute page de classement Kindle d'amazon.fr est dans le périmètre** : adresse
  `https://www.amazon.fr/gp/bestsellers/digital-text/{node}` (numéro de catégorie en chiffres), Top payant ou Top
  gratuit (`tf=1`), page 1 ou page 2 (`pg=2`), quelle que soit la catégorie.
- Le **choix des catégories revient au porteur du projet**, qui navigue lui-même. La décision 005 est inchangée :
  navigation manuelle, aucune requête par un programme, capture des seules pages affichées.

### 2. Fin de `config/targets.toml`

- Le fichier est **supprimé**, ainsi que la variable `BOOKS_TARGETS_FILE` et sa copie dans l'image. Ajouter une
  catégorie ne demande plus ni modification du dépôt, ni reconstruction de l'image : il suffit de la consulter.
- **Plus aucun nom de catégorie dans le code ni dans la configuration** du dépôt public. Les noms observés vivent dans la
  base (section 3), sur atlas.
- **Règle : aucun nouveau nom réel de catégorie dans le dépôt public** (code, configuration, tests, documentation).
  Les exemples sont inventés ; une catégorie réelle se désigne au besoin par son numéro.
- Un **rôle non bloquant** remplace la liste : le bilan de l'ingestion signale, comme **information** (et non comme
  anomalie), toute catégorie **jamais vue auparavant** dans `raw.raw_page`. La croissance du périmètre reste ainsi
  visible à chaque envoi (voir la section 6 sur le volume).

### 3. Nom de la catégorie : une donnée observée

- Éléments identifiés le 10 octobre 2026 sur les captures réelles (structure seulement ; exemples inventés) :
  - **nom d'affichage** : le second `<h1>`, après le préfixe fixe « Les meilleures ventes en » (repris dans le
    `<title>`), par exemple « Catégorie d'exemple - ebooks ». Le suffixe « - ebooks » n'est **pas** systématique : il
    est conservé tel qu'affiché, sans retouche ;
  - **nom court** : l'élément sélectionné de l'arborescence des catégories (`aria-current="page"` hors de la rangée
    d'onglets et de la pagination), par exemple « Exemple ».
  - L'arborescence montre aussi les catégories parentes, chacune avec son numéro et son nom ; leur repérage dépend
    aujourd'hui de paramètres de navigation (`ref=`). Non retenu à ce stade.
- **Où** : dans **STAGING**, pas dans `raw.raw_page`.
  - RAW conserve ce qui a été capturé, sans rien en déduire (décision 001) ; le nom se lit dans le HTML déjà conservé.
  - Une colonne ajoutée à `raw.raw_page` ne serait remplie que pour les pages futures (RAW n'est jamais modifié) ;
    dans STAGING, l'extracteur la calcule pour toutes les pages, anciennes comprises, par réextraction.
  - Table proposée : `staging.category_observation`, une ligne par page RAW extraite : numéro de catégorie (celui de
    l'adresse, déjà dans `raw.raw_page`), nom d'affichage, nom court ; rattachée à `page_extraction` par la même clé
    composée que `ranking_entry` (jamais deux versions mélangées, décision 011).
- **Nom qui change** : rien n'est écrasé. Chaque page porte le nom observé **ce jour-là** ; l'historique des noms d'une
  catégorie est l'ensemble de ses observations. Le **numéro** reste l'identifiant stable
  (`docs/exploration-amazon.md`). Le « nom courant » d'une catégorie sera, dans une couche ultérieure, celui de son
  observation la plus récente ; un changement de nom se lit en comparant les observations, sans perte.
- **Nom absent ou de forme inconnue** : le nom reste vide (`NULL`) et le bilan le signale comme **information**. La page
  n'est pas mise en échec : le nom est une étiquette, alors que les rangs sont la donnée principale. Le **bilan de
  l'extraction compte les pages sans nom lu** (nom d'affichage et nom court, séparément), pour qu'une disparition de
  l'élément sur les pages d'Amazon se voie dès la première séance.

### 4. Une définition commune de la « page de classement acceptable »

- La règle de la section 1 est écrite **une seule fois**, dans un module commun `src/books/amazon/` (même principe que
  `ranked_list.py`, décision 011) : à partir d'une adresse, elle rend (catégorie, liste, page), ou un motif de refus.
  C'est la fonction déjà utilisée par l'ingestion pour l'adresse affichée (`request_from_url`, décision 007), déplacée
  et rendue publique.
- **Contrat commun** : `tests/fixtures/adresses_classement.json`, table d'exemples d'adresses acceptées (avec la
  catégorie, la liste et la page attendues) et refusées (avec le motif), versionnée dans ce dépôt, fait foi.
  - Les tests de ce dépôt la parcourent entièrement.
  - L'extension, dont le code est dans un dépôt privé (décision 006), en **garde une copie dans ses tests**, avec en
    en-tête le **commit d'origine** de ce dépôt.
  - **Toute modification de la table ici impose la mise à jour de la copie** dans le dépôt de l'extension.
- La **règle de l'extension** (liste blanche) sera modifiée dans son dépôt, d'après la présente décision.

### 5. Ce qui reste refusé

- **Autres boutiques** que `digital-text` (par exemple `books`, livres papier).
- **Autres types de listes** : nouveautés (`/gp/new-releases/`), meilleures progressions, listes d'envies, cadeaux,
  et toute adresse hors de `/gp/bestsellers/digital-text/{node}`.
- **Autres domaines** qu'`https://www.amazon.fr` (autres pays, sous-domaines, adresse non chiffrée).
- Valeurs de `tf` autres que `1`, de `pg` autres que `1` ou `2`, paramètres répétés (décision 007, inchangé).
- **Fiches produit** : toujours exclues (décisions 005 et 013).
- La page générale « Boutique Kindle » (`/gp/bestsellers/digital-text`, **sans** numéro de catégorie) : **refusée**
  (le numéro est obligatoire, et la validation compare le canonical à ce numéro). **Question ouverte, en attente** :
  l'accepter demanderait une décision dédiée.

### 6. Volume

- La décision 005 demande que toute extension du périmètre tienne compte de l'extraction substantielle ou répétée et
  systématique d'une base de données. Le garde-fou ne disparaît pas : il passe d'un fichier à la pratique du porteur
  du projet, éclairée par l'information « nouvelle catégorie » (section 2) et par le plafond de 200 captures par
  ingestion (décision 008), inchangé.

## Conséquences

- **Validation** (décision 004) : inchangée sur le fond. Le canonical est comparé au numéro de catégorie de
  l'**adresse affichée** de la capture, et non plus d'une liste : c'est déjà le cas.
- **Ingestion** (décision 008) : plus de mise en quarantaine « hors périmètre ». Les captures déjà mises en quarantaine
  pour ce seul motif, sur atlas, peuvent être replacées dans `inbox/` (procédure de la décision 008).
- **Tournée de développement** (`run.py`, pages enregistrées à la main) : ses demandes ne viennent plus de
  `targets.toml` ; elles se déduisent des noms des fichiers de `data/samples/`.
- **Extracteur** (décision 011) : lecture du nom de la catégorie, donc **`EXTRACTOR_VERSION` incrémentée**, et
  réextraction de toutes les pages ; nouvelle table, donc **migration 006**.
- **Documents** : les décisions 004 et 008 reçoivent une note datée. Les noms de catégories déjà publiés dans
  `docs/exploration-amazon.md` et dans des décisions restent tels quels : l'historique du dépôt public les conserve de
  toute façon. Aucun nouveau nom réel n'y est ajouté (section 2).
- **Avis juridique** : la décision 005 réservait déjà l'appréciation de l'extraction substantielle à un juriste ; un
  périmètre ouvert en fait partie.

> Note du 10 octobre 2026 (étape A du code : définition commune de l'adresse) :
> - Module commun `src/books/amazon/ranking_page.py` : `request_from_url` (déplacée de `inbox.py`, comportement
>   inchangé), `PageRequest`, `canonical_url` et les constantes d'adresse. `targets.py` les réexporte en attendant
>   l'étape B ; `inbox.py` importe la fonction commune.
> - **Contrat commun** `tests/fixtures/adresses_classement.json` : 9 adresses acceptées, 19 refusées, numéros de
>   catégorie inventés. Il contient les **quatre formes réellement observées** dans les 14 captures (relevé du
>   10 octobre 2026 sur leurs `displayed_url`) : adresse simple ; `/ref=zg_bs?ie=UTF8&tf=1` ;
>   `/ref=zg_bs_pg_2_digital-text?ie=UTF8&pg=2` ; `/ref=zg_bs_pg_2_digital-text?ie=UTF8&tf=1&pg=2` (page 2 du Top
>   gratuit, `tf` avant `pg`). Refus : autres domaines, pays et sous-domaines, `http`, autre boutique, nouveautés,
>   meilleures progressions, envies, cadeaux, page générale sans numéro, numéro non numérique, fiche produit,
>   paramètres répétés ou invalides.
> - `tests/python/test_ranking_page.py` parcourt toute la table (les anciens tests d'adresses de `test_inbox.py`, tous
>   repris dans la table, sont retirés). Suite complète contre PostgreSQL 17 jetable : 314 réussis.
>   Contre-épreuves : règle acceptant les nouveautés → échec sur « nouveautés » ; domaine accepté s'il finit par
>   `amazon.fr` → échecs sur « domaine sans www » et « autre sous-domaine ».
> - Prochaine étape côté extension : copier la table dans ses tests, avec en en-tête le commit d'origine de ce dépôt.
