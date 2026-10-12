# 017 — Guide de veille

Date : 11 octobre 2026

> Statut : **adoptée** le 11 octobre 2026 par le porteur du projet, avec quatre ajouts intégrés au texte (le guide
> renseigne sans commander, biais de sélection, rythme d'usage, usage scripté de `books_reader`).

## Contexte

Pendant une séance, le porteur du projet affiche à la main le Top d'une liste (pages 1 et 2, payant ou gratuit) et
décide lui-même quelles pages capturer (décision 005). Trois informations l'aideraient à choisir, sans rien
automatiser :
1. les **nouveaux entrants** de la liste depuis sa dernière observation ;
2. les livres classés dont la **fiche Kindle** n'est pas encore en base ;
3. les **changements de rang**, même d'une place.

Ces informations dépendent de la base (atlas). L'extension, elle, lit déjà la liste classée affichée (décision 010)
et n'a aucun accès réseau (décision 005).

## Décision

### 1. Principe

- Atlas calcule une **référence** (dernière observation de chaque liste, ASIN des fiches Kindle en base). Un script la
  rapatrie sur le PC. Le porteur du projet l'importe dans l'extension. L'extension compare la liste affichée à cette
  référence et montre le résultat dans un **panneau latéral** de l'extension.
- **Rien n'est écrit dans la page Amazon** : le panneau est une page de l'extension, hors de la page.
- **Aucun accès réseau** n'est ajouté à l'extension ; aucune lecture libre du disque (section 5).
- **Le guide renseigne, il ne commande pas.** Ce n'est pas une liste de tâches à vider : le porteur du projet juge
  seul de ce qu'il consulte et capture. Aucun seuil, aucun ordre de priorité, aucun lien ni bouton qui ouvrirait une
  page.

### 2. Ce que montre le panneau

Pour la page de classement affichée (une liste : catégorie, payant ou gratuit ; une page : 1 ou 2) :
1. **Nouveaux entrants** : ASIN affichés absents de **toute** la référence de la liste (pages 1 et 2). Un livre passé
   de la page 2 à la page 1 n'est pas un entrant : c'est un changement de rang.
2. **Fiches Kindle manquantes** : ASIN affichés absents de la liste des fiches Kindle en base (section 3). Les fiches
   papier et les fiches refusées ne comptent pas.
3. **Changements de rang** : tout écart, même d'une place, avec la date de l'observation de référence de ce livre.
   Convention : **écart = rang de référence − rang affiché** ; **+N = N places gagnées, −N = N places perdues**. Aucun
   seuil. Un rang inchangé n'est pas affiché.

Liste jamais observée : « aucune observation de référence » ; ni entrants ni changements (rien à comparer) ; les
fiches manquantes restent calculées. Les livres sortis de la liste ne sont pas montrés (ajout possible plus tard).
Le titre affiché dans le panneau est lu dans la page affichée, jamais transmis par atlas.

### 3. Calcul sur atlas : schéma `guide` (migration 009)

Un schéma `guide`, distinct de STAGING (couche recalculable de l'extracteur), porte trois vues créées avec
**`security_invoker = true`** : elles lisent les tables avec les droits du rôle qui les interroge, et ne peuvent donc
jamais montrer plus que ce qu'il lit déjà.

- **`guide.reference_entry`** (`category_node`, `list_type`, `asin`, `rank`, `observed_at`) :
  - pour chaque liste (catégorie et type) et chaque page (1, 2), la **dernière page extraite `ok`** (date :
    `raw.raw_page.fetched_at`, UTC). Une page plus récente en échec d'extraction est ignorée ; la précédente sert ;
  - les lignes des deux pages sont réunies. Les deux pages peuvent dater de séances différentes : **chaque ligne
    porte sa propre date**. Un ASIN présent dans les deux pages de référence ne garde que sa ligne la plus récente ;
  - STAGING ne contient que des captures `extension-dom` (décision 011, section 1) : les pages `manual-html`, bloquées
    ou refusées n'y entrent jamais.
- **`guide.kindle_product`** (`asin`, `last_observed_at`) : ASIN dont une fiche a le statut `ok` dans
  `staging.page_extraction`, c'est-à-dire une fiche Kindle extraite. Exclues : fiches papier (`skipped`), fiches en
  échec d'extraction, fiches refusées (absentes de STAGING). Une fiche Kindle capturée mais en échec d'extraction
  apparaît donc comme manquante ; elle est par ailleurs visible comme anomalie dans le bilan d'extraction.
- **`guide.export_document`** (`document`) : une ligne, le document JSON de la section 4, construit par PostgreSQL à
  partir des deux vues précédentes.

**Rôle** : `books_reader` (décision 016), qui reçoit `USAGE` sur `guide` et `SELECT` sur les trois vues. Il reste en
lecture seule ; les vues ne lui donnent aucune donnée de plus (`security_invoker`). Le test de liste blanche de la
décision 016 est mis à jour dans la même migration.

### 4. Format du fichier (contrat, version 1)

Fichier JSON en UTF-8, sans BOM, nommé `guide_{AAAA-MM-JJ}T{HHMMSS}Z.json` d'après `generated_at`. Toutes les dates
sont en UTC, au format `AAAA-MM-JJTHH:MM:SSZ`. Valeurs ci-dessous inventées.

```json
{"schema_version": 1,
 "generated_at": "2026-10-11T18:00:00Z",
 "lists": [
   {"category_node": "10000000001", "list_type": "paid",
    "entries": [{"asin": "B0FAUX0001", "rank": 1, "observed_at": "2026-10-10T19:00:00Z"}]}],
 "kindle_asins": ["B0FAUX0001"]}
```

| Champ | Règle |
|---|---|
| `schema_version` | entier, exactement `1` |
| `generated_at` | date UTC de l'export ; le nom du fichier en dérive |
| `lists` | tableau, trié par `category_node` puis `list_type` ; une seule entrée par couple ; peut être vide |
| `category_node` | chaîne de chiffres |
| `list_type` | `paid` ou `free` |
| `entries` | tableau non vide, trié par `rank` ; ASIN et rangs uniques dans la liste |
| `asin` | 10 caractères `[A-Z0-9]` |
| `rank` | entier de 1 à 100 |
| `observed_at` | date de la page de référence de cette ligne, au plus `generated_at` |
| `kindle_asins` | tableau d'ASIN uniques, triés ; peut être vide |

Aucun autre champ, à aucun niveau : un champ inconnu fait refuser le fichier (par la réception sur le PC, puis par
l'extension). Le fichier ne contient aucune donnée personnelle : des ASIN, des rangs, des dates et des numéros de
catégorie. Il contient des **numéros de catégorie réels** : il n'entre jamais dans le dépôt public (décision 014).

**Règles de comparaison** (section 2), rendues exactes :
- la référence d'une page affichée est l'entrée de `lists` de même `category_node` **et** même `list_type` ;
- les trois listes du résultat sont triées par rang affiché croissant ;
- un changement porte : ASIN, rang affiché, rang de référence, écart, `observed_at` de la ligne de référence.

Le contrat est fixé par des fichiers de ce dépôt : `tests/fixtures/guide_exemple.json` (document valide, valeurs
inventées) et `tests/fixtures/guide_vecteurs.json` (cas de comparaison et résultats attendus), vérifiés par
`tests/python/test_guide_contrat.py`. Ils sont copiés dans le dépôt de l'extension avec le commit d'origine, comme
`adresses_fiches.json` (décision 015).

### 5. Transport et lecture par l'extension

- **Sur atlas, `scripts/exporter-guide.sh`** : une requête sous `books_reader` (connexion locale du conteneur,
  décision 016) lit `guide.export_document` ; le script écrit sur sa sortie une archive tar (le fichier JSON et
  `MANIFEST.sha256`), sans créer de fichier durable sur atlas. Même structure que `exporter-sauvegarde.sh`
  (décision 009).
- **Sur le PC, `scripts\recevoir-guide.cmd`** (et `recevoir-guide.ps1`) : `ssh -n atlas`, puis les contrôles du
  rapatriement (code de ssh nul, archive composée exactement des deux fichiers, empreinte exacte), puis le contrôle du
  format (section 4). Le fichier est rangé dans un **dossier dédié**, désigné par un réglage local ignoré par Git.
  Ce n'est jamais le dossier des captures, où l'envoi le signalerait comme fichier hors format (décision 007).
  Rien n'est écrasé.
- **Dans l'extension** (dépôt privé, décision 006) :
  - une page d'options porte un sélecteur de fichier : l'extension ne lit **que le fichier choisi** par le porteur du
    projet, sans permission d'accès aux fichiers, sans `file://`, sans programme du PC ni serveur local ;
  - elle contrôle le format (section 4), puis range le contenu dans `chrome.storage.local`, espace privé de
    l'extension, invisible des pages web ;
  - le panneau latéral (permission `sidePanel`, aucune permission d'hôte ajoutée) n'est actif qu'**en mode
    enregistrement** : hors de ce mode, l'extension ne lit rien (décision 005, section 4) ;
  - il lit la liste classée définie par la décision 010 (ASIN et rangs, disponibles avant le chargement des cartes) ;
    la liste est identifiée par l'adresse affichée, comme pour le nom des captures (décision 007) ;
  - aucun lien cliquable vers une fiche : le porteur du projet clique lui-même la carte dans la page Amazon.

### 6. Rythme d'usage

**Envoyer** les captures de la séance (décision 008), **puis exporter** le guide (`recevoir-guide.cmd`), **puis
l'importer** dans l'extension avant la séance suivante. Le guide reflète la base au moment de l'export. Une page
réouverte juste après son envoi montre des écarts nuls : sa propre observation est devenue la référence ; c'est normal.

### 7. Biais de sélection

- Les **classements** restent des listes complètes, capturées en entier (décision 010) : ils ne sont pas biaisés par
  le guide.
- Les **fiches** sont capturées selon les signaux du guide (entrant, changement de rang, fiche manquante) : leur
  échantillon n'est ni aléatoire ni stable dans le temps. **Toute analyse des fiches doit le préciser** (période,
  population, mode de sélection).

### 8. Collecte « répétée et systématique »

Le guide rend la collecte plus systématique : il signale, liste après liste, chaque fiche Kindle manquante. La
décision 005 (Conséquences) rappelle le droit du producteur de base de données sur l'extraction répétée et
systématique de parties non substantielles. Cette question rejoint la **liste destinée au juriste**, avec les
**volumes réels** (pages de classement et fiches par séance et par mois, relevés dans RAW). La règle graduée des
vérifications (CAPTCHA, décision 005, section 2) reste inchangée ; le guide n'est pas une incitation à enchaîner les
pages.

### 9. Tests et contre-épreuves

- **SQL** (`tests/sql/test_009_guide.sql`, base de test, valeurs inventées) : dernière page par liste et par page ;
  dates différentes entre pages 1 et 2 ; ASIN présent dans les deux pages ; page récente en échec ignorée ; listes
  payante et gratuite séparées ; `kindle_product` sans fiches papier, en échec ni refusées ; document conforme ;
  `security_invoker` vérifié dans le catalogue ; lecture par `books_reader`, refus pour `books_collector` et
  `books_transformer`. Liste blanche du test 008 mise à jour.
- **Contrat** (Python) : l'exemple respecte le format ; les vecteurs sont rejoués par une implémentation de référence
  de la section 2, écrite dans le test ; un export réel, construit par l'extracteur à partir de fausses pages, respecte
  le format.
- **Export** (`tests/shell/test_exporter_guide.sh`, conteneur Debian jetable, faux PostgreSQL) et **réception**
  (`tests/powershell/Test-RecevoirGuide.ps1`, faux atlas) : archive, empreinte, nom, format, aucun écrasement, rien de
  rangé en cas d'échec.
- **Contre-épreuves**, chacune doit faire échouer un test : vue qui garde la page la plus ancienne ; `kindle_product`
  qui inclut les fiches `skipped` ; vue sans `security_invoker` ; droit sur une vue sans mise à jour de la liste
  blanche ; signe de l'écart inversé ; montée de la page 2 à la page 1 comptée comme entrant ; réception qui accepte un
  champ inconnu ; export qui garde un fichier sur atlas.
- **Extension** (dépôt privé) : vecteurs rejoués ; DOM d'une page de test identique avant et après l'ouverture du
  panneau ; aucun `fetch` ni `XMLHttpRequest` ; fichier mal formé refusé à l'import ; rien n'est lu hors du mode
  enregistrement.

## Conséquences

- **Décision 005** : note ajoutée (rôle de l'extension étendu à un panneau de renseignement ; interdits inchangés).
- **Décision 016** : note ajoutée (`books_reader` sert aussi au script d'export).
- **Décision 006** : l'évolution de l'extension est décrite ici avant sa mise en service, comme elle l'exige.
- Le panneau sera réalisé dans le dépôt privé de l'extension, à partir du contrat de la section 4.

> Note du 11 octobre 2026 (**déploiement sur atlas**, commit `e209e9e`, rapporté par le porteur du projet) :
> - Sauvegarde de la base ; `git pull --ff-only` jusqu'à `e209e9e` ; **migration 009 appliquée** ; image non
>   reconstruite (aucun changement du code de l'image). Aucun test SQL en production.
> - **Observation en lecture seule conforme** (session forcée en lecture seule) : les 3 vues du schéma `guide` en
>   `security_invoker` ; `books_reader` lit 114 colonnes, n'exécute aucune fonction hors du catalogue système et ne peut
>   modifier aucune table ni vue ; aucun autre rôle n'a accès au schéma `guide`.
> - Sauvegarde rapatriée sur le PC (décision 009).

> Note du 11 octobre 2026 (**premier guide réel**, rapporté par le porteur du projet) :
> - Export par `recevoir-guide.cmd` depuis le PC : **10 listes, 699 livres de référence, 255 fiches Kindle** ; empreinte
>   SHA-256 et format version 1 vérifiés par la réception ; **mêmes nombres sur atlas** (observation en lecture seule)
>   **et sur le PC** (bilan de la réception).
> - 255 ASIN de fiches Kindle pour 256 fiches Kindle extraites à l'étape D (décision 015) : la vue compte des ASIN
>   distincts ; l'écart correspond au cas prévu lors du déploiement (une même fiche observée deux fois), non vérifié
>   ligne à ligne.

> Note du 12 octobre 2026 (**recette de l'extension 0.4.0**, dépôt privé, rapportée par le porteur du projet) :
> - 11 octobre : import du guide réel par la page d'options ; **refus d'un fichier renommé** (nom différent de sa date
>   d'export) ; fiches Kindle manquantes affichées dans le panneau latéral.
> - 12 octobre : avec une référence d'un jour, **nouveaux entrants et évolutions de rang observés en séance réelle**.
> - Le guide est en service : décision mise en œuvre de bout en bout (atlas, PC, extension).
