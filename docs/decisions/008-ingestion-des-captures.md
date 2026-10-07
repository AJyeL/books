# 008 — Ingestion des captures

Date : 7 octobre 2026

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
| 1 | Au moins une anomalie : capture `blocked` ou `invalid`, quarantaine, page 2 manquante ; ou ingestion déjà en cours ; ou erreur d'exécution |
| 2 | Configuration invalide |

**Le code 3 (arrêt de sécurité) disparaît.** Chaque ingestion est enregistrée comme une tournée (`raw.collect_run`) :
statut `success` sans anomalie, `partial` avec anomalie, `failed` sur erreur d'exécution ; le statut `aborted`
n'est plus utilisé. Les notes de la tournée détaillent : captures déposées par statut, déjà ingérées,
mises en quarantaine (avec la raison), pages 2 manquantes. Le bilan affiché sur le PC reprend ces informations.

### 5. Doublons

- **Même fichier reçu deux fois** (même empreinte `content_sha256` déjà présente dans RAW) : la capture n'est pas
  redéposée, elle est retirée de `inbox/` et mentionnée « déjà ingérée », **sans anomalie**. L'ingestion est ainsi
  idempotente : la relancer sur les mêmes fichiers ne change rien.
  Cet usage de l'empreinte reconnaît un fichier identique à l'octet près ; il est compatible avec la décision 001,
  qui exclut seulement de s'en servir pour détecter un changement de données.
- **Même page capturée à des heures différentes** : deux observations distinctes (contenus différents, ne serait-ce
  que par les jetons propres à chaque affichage), **toutes deux conservées** dans RAW. Le choix d'une observation
  par jour relève de la couche d'analyse, plus tard.

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
