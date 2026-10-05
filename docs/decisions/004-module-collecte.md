# 004 — Module de collecte sans réseau

Date : 5 octobre 2026 · Migration : `sql/migrations/003_statut_invalid.sql`

## Contexte

Les décisions 001 (couche RAW), 002 (collecte responsable) et 003 (collecteur conteneurisé) posent le cadre.
Il faut maintenant un collecteur qui fonctionne de bout en bout : ouvrir une tournée, obtenir les pages
de classement, les valider, les déposer dans RAW, puis clore la tournée. En développement, aucune requête
vers Amazon n'est permise : le collecteur doit travailler sur des pages enregistrées à la main, avec le même code
qu'en production. Plusieurs points n'étaient pas tranchés : le sort d'une page reçue mais non conforme,
la reconnaissance d'un CAPTCHA, l'emplacement des fichiers bruts.

## Décision

### Sources de pages interchangeables

- Le collecteur obtient ses pages par une **source** (`books.collector.sources`), selon une interface unique :
  - **source locale** : pages enregistrées à la main dans `data/samples/` (développement) ;
  - **source réseau** : requêtes vers amazon.fr (production), pas encore écrite.
- **Fail closed** : la source est choisie d'après `BOOKS_ENV`, et chaque source vérifie elle-même
  l'environnement dans son constructeur. En `dev`, la source réseau ne peut pas être construite ;
  en `prod`, la source locale non plus. Toute autre valeur est refusée. Tant que la source réseau
  n'est pas écrite, le collecteur s'arrête en `prod` avec le code 2, sans ouvrir de tournée.
- **Pages enregistrées visibles en dev seulement** : `docker-compose.dev.yml` monte `data/samples` en lecture seule
  et fixe `BOOKS_SAMPLES_DIR`. Il n'est activé que par le `.env` du PC (`COMPOSE_FILE`, `COMPOSE_PATH_SEPARATOR`),
  jamais sur atlas : en production, le collecteur ne voit aucune page enregistrée. La commande de lancement
  reste la même partout. Vérifié le 5 octobre 2026 depuis Git Bash et PowerShell.
- La source locale prend, pour chaque page, le fichier `amazon_fr_bestsellers_{catégorie}_{paid|free}_p{n}_{AAAA-MM-JJ}.html`
  le plus récent. Tout nom qui ne respecte pas exactement cette convention est ignoré. Les pages doivent être
  enregistrées en « Page Web, HTML uniquement » (voir `docs/exploration-amazon.md`).

  > Correction du 5 octobre 2026 : la convention initiale (`…_{catégorie}_p{n}_{date}.html`) ne nommait pas
  > le type de liste. Son motif `…_p1_*.html` désignait aussi une page gratuite nommée `…_p1_gratuit_{date}.html`,
  > et la source locale la servait pour une demande de Top payant ; la validation l'aurait acceptée, le canonical
  > étant identique pour les deux listes. Le type de liste est désormais toujours explicite, comme dans le nommage RAW.

### Cibles

- Les catégories à collecter sont dans `config/targets.toml`, versionné et intégré à l'image
  (`BOOKS_TARGETS_FILE`, fixé dans le Dockerfile) : les modifier impose un passage par Git et une reconstruction.
- Le fichier est refusé s'il permet de dépasser le plafond de 200 requêtes par tournée (décision 002),
  en comptant 2 pages possibles par liste.
- **Périmètre actuel : page 1 du Top 100 payant uniquement.** La règle « page 2 si la page 1 contient 50 rangs »
  et le Top gratuit seront ajoutés quand des pages enregistrées correspondantes existeront.

### Validation d'une page : la structure décide, le mot ne fait que qualifier

Une page est **conforme** si son lien canonical vaut exactement
`https://www.amazon.fr/gp/bestsellers/digital-text/{catégorie demandée}` et si elle contient une, et une seule,
liste `data-client-recs-list` dont les éléments portent `render.zg.rank`.

| Situation | `fetch_status` |
|---|---|
| Structure conforme, que le mot « captcha » figure ou non dans la page (un titre de livre peut le contenir) | `ok` |
| Structure manquante, et le mot « captcha » présent (casse indifférente) | `blocked` |
| Structure manquante, sans le mot « captcha » | `invalid` |

Une liste de moins de 50 rangs reste conforme : c'est une information, consignée dans les notes de la tournée.
La structure supposée d'une page CAPTCHA (`tests/fixtures/bestsellers_captcha.html`) n'a jamais été observée :
elle sera remplacée par une structure vérifiée à la première vraie page rencontrée.

### Sort d'une page

- **Toute page reçue est déposée dans RAW**, même `blocked` ou `invalid` : fichier conservé, empreinte et taille
  enregistrées, raison dans `error_message`. C'est la trace de ce qui a réellement été reçu, utile au diagnostic.
  Seules les lignes `ok` seront lues comme des pages valides par les couches suivantes.
- Le statut **`invalid`** (migration 003) désigne une page reçue dont la structure ne correspond pas à la page demandée,
  sans signe de CAPTCHA. Il n'a pas été confondu avec `blocked` : un changement de mise en page chez Amazon
  (par exemple une clé renommée) ne doit pas être compté comme un blocage.
- Une page `blocked` ou `invalid` **arrête immédiatement la tournée** (disjoncteur de la décision 002) :
  les pages suivantes ne sont pas demandées. La logique de reprise des nuits suivantes n'est pas encore écrite.
- Une page non obtenue (par exemple un fichier local absent) est enregistrée en `network_error`, sans fichier ;
  la tournée continue.

### Statut de la tournée et code de sortie

| Statut | Situation | Code de sortie |
|---|---|---|
| `success` | toutes les pages sont conformes | 0 |
| `partial` | certaines pages non obtenues, aucune anomalie | 1 |
| `failed` | aucune page obtenue, ou erreur imprévue (la tournée est quand même close) | 1 |
| `aborted` | arrêt de sécurité sur une page `blocked` ou `invalid` | 3 |

Une configuration invalide (variables, cibles, source refusée) donne le code 2, sans ouvrir de tournée.
`notes` résume la source, les listes courtes, les pages non obtenues et la raison d'un arrêt.

### Fichiers bruts

- Emplacement : `BOOKS_RAW_DIR/amazon_fr/AAAA/MM/JJ/run-{id}/bestsellers_{catégorie}_{liste}_p{n}.html.gz`
  (date de début de la tournée, en UTC). `storage_path` est enregistré **relativement** à `BOOKS_RAW_DIR`,
  pour rester valable sur le PC comme sur atlas.
- Compression gzip, sans date dans l'en-tête (compression reproductible).
- **Jamais d'écrasement** : création exclusive du fichier (mode `xb`) ; un fichier existant provoque une erreur,
  et la tournée est close en `failed`. Le dossier racine n'est jamais créé par le collecteur.
- `content_sha256` et `content_bytes` portent sur le **HTML d'origine, non compressé**. Pour vérifier un fichier,
  on le décompresse et on recalcule l'empreinte. L'empreinte ne sert pas à dédoublonner : chaque réponse
  d'Amazon contient des jetons propres à la requête (constat du 5 octobre 2026, `docs/exploration-amazon.md`).
- Le fichier est écrit et synchronisé sur le disque **avant** l'insertion de sa ligne `raw_page`.
  En cas d'interruption entre les deux, il peut rester un fichier sans ligne, jamais une ligne sans fichier.

### Base de données

- Le collecteur se connecte en `books_collector` (migration 002) et n'utilise que ses droits :
  `INSERT` dans `collect_run` et `raw_page`, `UPDATE` des seules colonnes de clôture de `collect_run`.
- Connexion en **autocommit** : chaque page est enregistrée dès qu'elle est traitée, et une tournée interrompue
  garde la trace des pages déjà déposées. La tournée est close dans tous les cas (bloc `finally`).
- `requested_url` contient l'adresse Amazon que la page représente ; pour la source locale, `final_url`
  et `http_status` restent vides.

## Conséquences

- Le même code tourne en dev et en prod ; seule la source change, et elle ne peut pas être la mauvaise.
- En dev, chaque lancement crée une tournée et des lignes **définitives** dans RAW (ajout seul) : c'est voulu.
- Essai du 5 octobre 2026 en dev : tournée `success`, 2 pages `ok` de 50 rangs ; empreintes identiques en base,
  dans les fichiers décompressés et dans les pages d'origine ; `BOOKS_ENV=prod` refusé avec le code 2,
  sans tournée créée.
- Sur atlas, la migration 003 doit être appliquée ; le collecteur y restera arrêté (code 2) jusqu'à l'écriture
  de la source réseau, qui fera l'objet d'une décision : robots.txt, modération, disjoncteur complet, identité.
- Un fichier sans ligne `raw_page` est possible après une interruption ; un futur contrôle d'intégrité
  pourra les repérer.
