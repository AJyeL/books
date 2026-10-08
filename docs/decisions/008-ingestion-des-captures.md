# 008 — Ingestion des captures

Date : 7 octobre 2026 · Migration : `sql/migrations/004_methode_de_capture.sql` (étape 1 du code)

## Contexte

La décision 005 a remplacé la collecte réseau par une collecte semi-manuelle : le porteur du projet consulte les pages,
l'extension les capture sur le PC (format de la décision 007). Il reste à acheminer ces captures jusqu'à atlas,
à les ingérer dans RAW, et à trancher les quatre questions ouvertes de la décision 005 : transfert, déclenchement,
comportement face à une capture anormale, doublons. Le 7 octobre 2026, la validation de la décision 004 a été vérifiée
sur une première séance de 7 captures DOM, toutes conformes (`docs/exploration-amazon.md`).

## Décision

### 1. Transfert du PC vers atlas

- Un **script PowerShell** sur le PC envoie les captures du dossier de dépôt de l'extension.
- **Paires complètes seulement** : une capture n'est envoyée que si ses deux fichiers (`.html` et `.json`) sont présents.
  Un fichier orphelin, ou hors format (décision 007, section 6), est signalé et reste sur place.
- **Une seule connexion SSH**, vers l'alias `atlas` de la configuration SSH du PC, authentifiée par mot de passe,
  saisi à l'invite. Le mot de passe n'est jamais enregistré, ni dans le script, ni dans un fichier.
- Les paires partent dans une **archive tar** transmise par cette connexion. Sur atlas, l'archive est déballée dans un
  sous-dossier propre au lot, `~/books-data/captures/attente/{lot}/`, puis ce sous-dossier est **déplacé en une seule
  opération** dans `~/books-data/captures/inbox/{lot}/`. Un renommage dans un même système de fichiers est atomique :
  l'ingestion ne voit jamais un lot à moitié arrivé. `{lot}` est l'horodatage UTC du transfert
  (`AAAA-MM-JJTHHMMSSZ`).
- Avant ce déplacement, l'empreinte SHA-256 de chaque fichier reçu est comparée à celle calculée sur le PC
  (liste jointe à l'archive). En cas d'écart, le lot reste dans `attente/` et le transfert échoue.
- **Après le succès du transfert** (lot arrivé dans `inbox/`), les captures envoyées sont déplacées sur le PC dans
  `books-captures\envoyees\AAAA-MM\`, mois de la capture : c'est une copie de sauvegarde. Aucun fichier n'y est écrasé.
  En cas d'échec du transfert, rien n'est déplacé sur le PC.
- Outils : `ssh` et `tar` fournis avec Windows 10 et 11 ; aucune installation supplémentaire.

### 2. Déclenchement

- Le script lance l'**ingestion dans la même connexion SSH**, juste après le transfert, et affiche son bilan.
  Pas de tâche programmée (cron).
- Un **verrou** interdit deux ingestions simultanées. Il est pris par le collecteur lui-même, quel que soit
  le mode de lancement, et libéré automatiquement à la fin du processus, même en cas d'interruption.
  Si le verrou est déjà pris, l'ingestion ne démarre pas (code de sortie 1, message « ingestion déjà en cours ») ;
  les captures restent dans `inbox/`.
- Ce qui n'est pas ingéré reste dans `inbox/` et sera repris à l'ingestion suivante. Les captures sont traitées
  dans l'ordre chronologique de leur nom, lot par lot.
- Au plus **200 captures par ingestion** : au-delà, les suivantes restent dans `inbox/` (le plafond de la décision 002
  compte désormais des pages lues, décision 005).

### 3. Traitement de chaque capture

1. **Intégrité d'abord** (décision 007, section 6) : jumeaux présents, schéma du JSON, horodatage, adresse,
   empreinte et taille. Une capture dont la catégorie ne figure pas dans `config/targets.toml` est également refusée
   (périmètre de la décision 005).
   - En cas d'échec : la capture (ses deux fichiers, ou le fichier orphelin) est déplacée dans
     `~/books-data/captures/quarantaine/{lot}/`, avec un fichier texte `{nom}.raison.txt` qui donne la raison.
     **Rien n'est déposé dans RAW.** L'anomalie est signalée dans le bilan et dans les notes de l'ingestion.
   - Une capture **hors périmètre** est intègre et n'est pas modifiée par sa mise en quarantaine. Après l'ajout de sa
     catégorie à `config/targets.toml`, il suffit de replacer ses deux fichiers (sans le fichier `.raison.txt`)
     dans un sous-dossier de `inbox/` pour qu'elle soit ingérée normalement à l'ingestion suivante.
2. **Validation ensuite** (décision 004, quatre indices), avec la demande déduite du nom.
   - `ok`, `blocked` et `invalid` sont **toutes déposées dans RAW avec leur statut**, et l'ingestion **se poursuit**.
     L'arrêt de sécurité protégeait un serveur dans une collecte automatisée ; à l'ingestion, il n'y a plus de serveur
     à ménager, et un arrêt ferait perdre les captures valides suivantes.
   - **Page 2 annoncée mais non capturée** : si une page 1 `ok` compte 50 rangs et annonce une page 2 (les deux signaux
     de la décision 004), et que **le même lot** ne contient aucune page 2 de la même catégorie et de la même liste,
     l'absence est signalée. Rien n'est demandé à Amazon. Le transfert se fait à la fin de chaque séance :
     une séance donne un lot. La vérification ne dépend donc d'aucun fuseau horaire, et l'alerte tombe à la fin
     de la séance concernée.
3. **Dépôt dans RAW** : le HTML et le JSON sont déposés côte à côte, compressés, jamais écrasés (décision 004) ;
   une ligne `raw.raw_page` est insérée. Correspondances : `captured_at` → `fetched_at`, `displayed_url` →
   `requested_url` ; `final_url` et `http_status` restent vides. La méthode de capture et l'emplacement du JSON
   seront enregistrés par une migration (décision 005).
4. **Retrait de `inbox/`** : une capture n'est retirée de `inbox/` qu'une fois ses fichiers écrits et synchronisés
   sur le disque, et sa ligne `raw_page` validée en base. Une interruption entre ces étapes laisse la capture dans
   `inbox/` ; elle est alors reconnue comme « déjà ingérée » à l'ingestion suivante (section 5).

### 4. Bilan et codes de sortie

| Code | Situation |
|---|---|
| 0 | Toutes les captures traitées sont `ok` (ou déjà ingérées), aucune anomalie ; `inbox/` vide compris |
| 1 | Au moins une anomalie : capture `blocked` ou `invalid`, quarantaine, page 2 manquante, élément laissé en place, plafond de captures atteint ; ou ingestion déjà en cours ; ou erreur d'exécution |
| 2 | Configuration invalide |

**Le code 3 (arrêt de sécurité) disparaît.** Chaque ingestion est enregistrée comme une tournée (`raw.collect_run`),
avec un statut défini par sa règle (précisé le 7 octobre 2026) :

| Statut | Règle | Code |
|---|---|---|
| `success` | Aucune anomalie | 0 |
| `partial` | Le programme a fonctionné, mais il y a au moins une anomalie | 1 |
| `failed` | Erreur d'exécution | 1 |

Le statut `aborted` n'est plus utilisé. Les informations (capture déjà ingérée, liste courte, trou dans les rangs,
divergence entre les deux signaux de page 2) ne sont pas des anomalies. Les notes de la tournée contiennent le bilan :
captures déposées par statut, déjà ingérées, pages anormales, mises en quarantaine (avec la raison), éléments laissés
en place, pages 2 manquantes, informations. Le bilan affiché sur le PC reprend ces informations.

### 5. Doublons

- **Même fichier reçu deux fois** (même empreinte `content_sha256` déjà présente dans RAW) : la capture n'est pas
  redéposée, elle est retirée de `inbox/` et mentionnée « déjà ingérée », **sans anomalie**. L'ingestion est ainsi
  idempotente : la relancer sur les mêmes fichiers ne change rien.
  Cet usage de l'empreinte reconnaît un fichier identique à l'octet près ; il est compatible avec la décision 001,
  qui exclut seulement de s'en servir pour détecter un changement de données.
- **Même page capturée à des heures différentes** : deux observations distinctes (contenus différents, ne serait-ce
  que par les jetons propres à chaque affichage), **toutes deux conservées** dans RAW. Le choix d'une observation
  par jour relève de la couche d'analyse, plus tard.

> Note du 7 octobre 2026 (étape 2 du code : `books.collector.inbox` et `books.collector.ingestion`) :
> - **Nom des fichiers dans RAW** : l'horodatage de la capture y est ajouté,
>   `amazon_fr/AAAA/MM/JJ/run-{id}/bestsellers_{catégorie}_{liste}_p{n}_{AAAA-MM-JJTHHMMSSZ}.html.gz` et `….json.gz`,
>   pour que deux observations de la même page dans une même ingestion ne se confondent pas.
> - **Retrait de `inbox/`** : le JSON d'abord, le HTML ensuite. Un HTML resté seul après une interruption est reconnu
>   « déjà ingéré » par son empreinte ; sinon, c'est un orphelin, mis en quarantaine.
> - **Éléments laissés en place** : un fichier hors de tout lot, un dossier de lot au nom hors format ou un sous-dossier
>   dans un lot sont signalés sans être déplacés (sans lot valide, pas de dossier de quarantaine).
> - **Quarantaine sans écrasement** : déplacement par lien physique puis suppression de l'ancien nom ; si la destination
>   existe déjà, la capture reste dans `inbox/` et l'anomalie est signalée.
> - **Périmètre** : le couple catégorie et liste doit figurer dans `config/targets.toml`.
> - `requested_url` reçoit l'adresse affichée telle quelle ; `fetched_at` l'horodatage de la capture.
> - **Provisoire jusqu'à l'étape 3** : une capture `blocked` ou `invalid` est déposée avec son statut, puis l'ingestion
>   s'arrête ; les suivantes restent dans `inbox/`. La page 2 manquante n'est pas encore signalée.
> - Vérifié le 7 octobre 2026 sur des copies des 7 captures réelles, dans un PostgreSQL jetable (migrations 001 à 004) :
>   7 captures déposées, empreintes du HTML et du JSON exactes ; une seconde ingestion des mêmes fichiers donne
>   « déjà ingérées 7 » et aucune nouvelle ligne.

> Note du 7 octobre 2026 (étape 3 du code) : la mesure provisoire de l'étape 2 est levée.
> - Une capture `blocked` ou `invalid` est déposée avec son statut, et l'ingestion continue.
> - Anomalies : capture `blocked` ou `invalid`, quarantaine, page 2 manquante, **élément laissé en place** et
>   **plafond de captures atteint** (des captures restent alors dans `inbox/` : le code 0 doit signifier
>   « tout est fait »).
> - Page 2 manquante : vérifiée en fin d'ingestion, pour chaque page 1 déposée `ok` dont les deux signaux concordent,
>   contre l'inventaire des noms du lot. Une page 2 présente dans le lot mais mise en quarantaine n'est pas comptée
>   comme manquante (l'anomalie est déjà signalée par la quarantaine) ; une page 1 « déjà ingérée » n'est pas
>   revérifiée. La règle des deux signaux est commune à l'ingestion et à la tournée de développement.
> - La contrainte de `raw.collect_run` accepte encore la valeur `aborted` : elle n'est plus produite, et la retirer
>   demanderait une migration sans utilité (aucune tournée ne la porte).
> - La tournée de développement (`run.py`) est alignée sur ces règles : poursuite sans arrêt, mêmes statuts,
>   mêmes codes ; une page non obtenue y est une anomalie (`partial`), même si aucune page n'est obtenue.
> - Vérifié le 7 octobre 2026 dans un PostgreSQL jetable, sur des copies des 7 captures réelles dont la page 2 gratuite
>   de Romance sportive retirée, plus une capture CAPTCHA inventée : 6 `ok` et 1 `blocked` déposées, page 2 manquante
>   signalée, `partial`, 2 anomalies, code de sortie 1.

> Note du 7 octobre 2026 (étape 4 du code : verrou et montage Docker) :
> - **Verrou** : verrou consultatif du noyau (`flock`) sur `~/books-data/captures/ingestion.lock`, pris par le
>   collecteur avant toute connexion à la base. Le fichier est sur le disque de l'hôte, car chaque lancement crée
>   un nouveau conteneur : un verrou interne au conteneur ne serait vu par aucun autre. Il est placé à côté de
>   `inbox/`, et non dedans, où il serait pris pour un fichier hors format. Le noyau le libère à la fin du processus,
>   même après un arrêt brutal ; le fichier n'est jamais supprimé. Verrou occupé : message, code 1, aucune tournée.
> - **Montage** : `BOOKS_CAPTURES_DIR` (chemin de l'hôte, dans `.env`) est monté en lecture et écriture sur
>   `/data/captures`, avec les garde-fous de `BOOKS_RAW_DIR` (décision 003) : valeur de repli inexistante au nom
>   explicite et `create_host_path: false`. Une variable absente ne rend pas `docker-compose.yml` invalide et
>   n'empêche ni PostgreSQL ni la sauvegarde ; Docker ne crée jamais le dossier au nom de root.
>   En développement, le dossier est `./data/ingestion`, distinct de `data/captures/` (captures réelles de référence).
> - **Sauvegarde** : `~/books-data/captures/` n'entre pas dans la sauvegarde nocturne. `inbox/` et `attente/` sont
>   transitoires ; une capture ingérée est dans RAW (HTML et JSON), qui est sauvegardé ; une capture non ingérée
>   ou en quarantaine a son original sur le PC, dans `envoyees\`. `scripts/backup.sh` n'est pas modifié.
> - **`envoyees\` n'est jamais vidé** : c'est une archive permanente, la seule copie des captures hors d'atlas,
>   dont les sauvegardes sont sur le même disque.
> - La base de données reste concernée par la copie externe prévue (copie mensuelle vers le PC, puis vers un NAS),
>   qui n'est pas encore en place. (Note du 8 octobre 2026 : copie vers le PC définie par la décision 009.)
> - Vérifié le 7 octobre 2026 : `docker compose config` valide avec un `.env` de type atlas, avec ou sans
>   `BOOKS_CAPTURES_DIR`, et avec les seules variables PostgreSQL ; verrou refusé à un second conteneur puis rendu
>   après l'arrêt brutal du premier, sur un volume Linux ; ingestion de bout en bout dans le conteneur, en dev,
>   sur des captures inventées.

> Note du 7 octobre 2026 (étape 5 du code : transfert) :
> - **Deux scripts** : `scripts/envoyer-captures.ps1` sur le PC, et `scripts/recevoir-captures.sh` sur atlas,
>   versionné et appelé par la connexion SSH (`ssh atlas bash books/scripts/recevoir-captures.sh {lot}`).
> - **Manifeste** : `MANIFEST.sha256` (format de `sha256sum`), calculé sur les originaux et placé dans l'archive :
>   un seul flux, donc une seule connexion. Sur atlas : fichiers ordinaires seulement, exactement ceux du
>   manifeste, empreintes vérifiées ; nom de lot strictement contrôlé (aucune injection de commande).
> - **Octets préservés** : copie des paires dans un dossier de préparation, archive `tar` au format ustar,
>   transmise par une redirection de `cmd.exe`, jamais par un tuyau PowerShell (qui traite les données comme du
>   texte). Outils de Windows appelés par leur chemin complet (`System32\OpenSSH\ssh.exe`, `System32\tar.exe`).
> - **Repères** lus par le PC : `BOOKS:TRANSFERT:OK {lot} {n}`, puis `BOOKS:INGESTION:CODE {code}` ;
>   `BOOKS:TRANSFERT:ECHEC {raison}` en cas d'échec (le lot reste alors dans `attente/`).
> - **Codes du script d'envoi** : 0 transfert réussi et ingestion sans anomalie (ou rien à envoyer) ;
>   1 transfert réussi, ingestion avec anomalies ou non effectuée ; 2 réglage, dossier ou outil invalide, ou
>   collision dans `envoyees\` (rien envoyé) ; 3 transfert échoué (rien déplacé sur le PC).
> - **Réglage local** non versionné (`scripts/envoyer-captures.local.psd1`) : le chemin personnel des captures
>   n'entre jamais dans le dépôt. **Lanceur** `scripts/envoyer-captures.cmd` pour un double-clic
>   (`-ExecutionPolicy Bypass` pour ce seul lancement, sans modifier les réglages du système).
> - Vérifié le 7 octobre 2026 : script de réception dans un conteneur Debian (lot valide, empreinte fausse,
>   fichier en trop ou manquant, manifeste absent, sous-dossier, membre « .. », entrée non tar, nom de lot invalide,
>   lot déjà présent, inbox/ absent) ; script d'envoi contre un faux atlas en conteneur, avec les vrais outils de
>   Windows (trois issues, octets identiques à l'arrivée, mauvais mot de passe, orphelin et fichier hors format,
>   rien à envoyer, collision). Le mot de passe y est fourni par `SSH_ASKPASS` : la saisie au clavier reste à vérifier
>   lors du premier envoi réel ; un échec y serait sans danger (transfert échoué, rien déplacé).

> Correction du 7 octobre 2026 : le premier envoi réel, lancé par `envoyer-captures.cmd`, a échoué avant toute
> connexion (rien envoyé, rien déplacé). Sous PowerShell 5.1, `$PSScriptRoot` est vide dans les valeurs par défaut
> de `param()` quand le script est lancé par `powershell -File` ; les tests passaient toujours les paramètres
> explicitement, si bien que cette ligne n'avait jamais été exécutée.
> - Les valeurs par défaut (réglage local, dossier de travail) sont désormais calculées dans le corps du script.
> - Nouveau test : lancement par le `.cmd`, **sans aucun paramètre**, avec un réglage local de test ; contre-épreuve :
>   il échoue avec l'ancienne version, sur l'erreur observée.
> - Inventaire des valeurs par défaut que les tests ne traversaient pas : réglage local, alias `atlas`, configuration
>   SSH de l'utilisateur, dossier de travail (TEMP), lanceur `.cmd`, vraie commande d'ingestion sur atlas.
>   Toutes sont maintenant exécutées par un test, sauf la commande `ssh` sans `-F` (configuration SSH de
>   l'utilisateur), vérifiée lors de l'envoi réel. La commande d'ingestion (`docker compose … run --rm -T collector`)
>   a été exécutée telle quelle en développement.
> - Le réglage local accepte une clé facultative `ConfigSsh`, et refuse toute clé inconnue (une faute de frappe
>   dans une clé était auparavant ignorée en silence).

## Conséquences

- Les quatre questions ouvertes de la décision 005 sont tranchées ; des notes datées l'indiquent dans les décisions
  004 et 005.
- **Code à écrire**, par étapes : migration (méthode de capture, emplacement du JSON, index sur `content_sha256`),
  lecture des lots de `inbox/` par la source locale en production, quarantaine, verrou, nouveaux codes de sortie,
  script PowerShell de transfert.
- **Montage Docker** : le collecteur devra accéder en lecture et écriture à `~/books-data/captures/` sur atlas
  (lecture de `inbox/`, déplacements vers `quarantaine/`), en plus de `~/books-data/raw/`.
- `config/targets.toml` ne planifie plus de requêtes : il définit le **périmètre** des catégories acceptées.
- Les captures restent aussi sur le PC (`envoyees\`), en plus de RAW et de sa sauvegarde sur atlas.
- En développement, le même traitement s'applique à un dossier `inbox/` local, alimenté par des captures inventées
  ou recopiées à la main ; aucune connexion à atlas.

> Note du 8 octobre 2026 : la validation appliquée à la section 3 est durcie par la décision 011 (section 5 bis) :
> un rang ou un ASIN en double dans la liste classée rend la capture `invalid` (déposée avec son statut, anomalie
> au bilan) ; un trou dans les rangs reste une information.
