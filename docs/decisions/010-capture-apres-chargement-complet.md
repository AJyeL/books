# 010 — Capture après chargement complet

Date : 8 octobre 2026

## Contexte

L'extension (décisions 005 à 007) capture la page de classement dès son affichage. L'inventaire du 8 octobre 2026
des 7 captures de la séance du 7 octobre (`docs/exploration-amazon.md`) montre la conséquence : chaque page ne contient
que **30 cartes détaillées** (rangs 1 à 30, ou 51 à 80), alors que la liste classée en compte 50 (ou 46 pour un Top
gratuit court). Les livres suivants n'ont que leur ASIN et leur rang : sur 346 livres, **136 (39 %)** n'ont ni titre,
ni prix, ni note, ni nombre d'évaluations.

Le même jour, une page Top payant p1 de Fantasy épique, **défilée à la main jusqu'en bas**, contenait **50 cartes
détaillées sur 50**, de même structure : les cartes manquantes sont chargées par la page elle-même, au défilement.
Cette page avait été enregistrée par Ctrl+S, méthode exclue (adresses des couvertures réécrites, pas de JSON, question
d'une nouvelle requête laissée ouverte par la décision 005). Il faut donc que **l'extension** capture la page une fois
toutes les cartes chargées, sans rien faire elle-même pour les charger.

## Décision

### 1. Repères du DOM

Constatés le 8 octobre 2026 sur trois pages (deux captures de l'extension, une page défilée) :

- **Liste classée** : définie **exactement comme dans `src/books/collector/validation.py`**, référence commune
  à l'extension, à la validation et à l'extracteur (une seule définition de la liste classée) :
  - un élément portant l'attribut `data-client-recs-list` dont la valeur est un tableau JSON, et dont au moins un
    élément porte la clé `render.zg.rank` dans `metadataMap` (`_ranked_items`) ;
  - il doit y avoir **exactement une** liste classée dans la page (`_check_ranks`) ;
  - le nombre de rangs attendus, **m**, est le nombre d'éléments de cette liste qui portent cette clé
    (50 ; 46 pour le Top gratuit court observé). Chaque élément porte aussi un ASIN (`id`).
  - La liste n'est **pas** repérée par la classe de l'élément qui la porte (`div.p13n-desktop-grid` dans les pages
    observées) : une classe de présentation peut changer sans que la liste change.
- **Cartes détaillées** : les éléments `[id="gridItemRoot"]` situés **à l'intérieur** de l'élément qui porte la liste
  classée. L'identifiant `gridItemRoot` est répété sur chaque carte (contraire à la norme HTML) : il faut ce sélecteur
  d'attribut, et non `getElementById`, qui n'en renverrait qu'une. Chaque carte contient un élément `[data-asin]`.
  Le nombre de cartes chargées, **n**, est le nombre d'ASIN distincts de la liste classée qui ont une carte
  (ASIN de `[data-asin]` dans une carte, présent dans la liste).
- Ces repères sont des noms d'Amazon, susceptibles de changer. Selon le repère renommé :
  - **attribut `data-client-recs-list` ou clé `render.zg.rank`** : la page est « sans liste classée » (section 2),
    capturée telle quelle, puis classée `invalid` à l'ingestion ;
  - **repère des cartes (`gridItemRoot`, `data-asin`)** : n reste inférieur à m, la page reste en **attente visible**
    (section 3), et rien n'est capturé.

  Dans aucun cas une capture incomplète ne peut être classée `ok`.

### 2. Capture unique, après chargement complet

- L'extension **ne capture plus à l'ouverture de la page**. Quand le mode enregistrement est actif et qu'une page
  de la liste blanche est affichée, elle **observe passivement** le DOM (`MutationObserver`) et recompte n et m
  à chaque modification.
- **Dès que n = m**, et m > 0, elle fait **une seule capture** de la page, au format de la décision 007, puis cesse
  d'observer. Une page déjà complète au début de l'observation est capturée aussitôt.
- **Une capture par chargement** : la même page n'est pas recapturée, même si le DOM change encore. Une nouvelle
  capture demande un nouveau chargement de la page, par le porteur du projet lui-même.
- Le chargement des cartes vient **uniquement du défilement fait à la main** par le porteur du projet.
- **Page sans liste classée unique** (aucune liste classée au sens de la section 1, ou plusieurs ; par exemple une page
  de vérification) : rien n'est à attendre. Elle est capturée telle quelle, une fois le document chargé (`document.readyState`
  à `complete`), comme aujourd'hui. L'ingestion la classe alors `blocked` ou `invalid` (décisions 004 et 008),
  ce qui garde la trace de l'incident dans RAW.

### 3. Attente visible, page quittée incomplète

- Tant que n < m, l'extension affiche un **badge d'attente distinct** du badge du mode enregistrement (autre texte,
  autre couleur), avec en info-bulle **« n/m »** cartes chargées. Après la capture, le badge du mode enregistrement
  revient.
- **Page quittée incomplète** (onglet fermé, autre adresse, rechargement avant n = m) : **rien n'est capturé**.
  L'extension compte ces pages pour la séance et affiche ce compte, avec le n/m de la dernière, dans sa fenêtre.
  Ce compte reste dans le navigateur : il n'est ni enregistré dans un fichier ni transmis à atlas.

### 4. Interdits rappelés (décision 005)

L'extension n'agit jamais sur la page pour la compléter :

- **aucun défilement** (ni `scrollTo`, ni `scrollIntoView`, ni modification de la position de défilement) ;
- **aucun clic**, aucun événement simulé, aucune prise de focus ;
- **aucune requête** (ni `fetch`, ni `XMLHttpRequest`, ni rechargement, ni ouverture d'onglet).

Elle ne fait qu'observer et lire le DOM, comme aujourd'hui. Le seul changement porte sur **le moment** de la capture.

### 5. Inchangés

- **Format des captures** (décision 007) : même schéma, version 1, même `capture_method` (`extension-dom`).
  Seul `extension_version` change, ce qui permet de distinguer dans RAW les captures faites avant et après
  cette décision. La complétude d'une capture se mesure dans le HTML lui-même (n et m) : aucun champ n'est ajouté.
- **Transfert et ingestion** (décision 008) et **validation** (quatre indices de la décision 004) : inchangés.
- **Captures existantes** : elles restent valides et conservées. L'extracteur (à venir) traitera les champs des
  livres sans carte détaillée comme **inconnus** (`NULL`), jamais comme une absence d'évaluation ou un prix nul.
  Il devra distinguer « pas de carte » (champs inconnus) de « carte sans note ni évaluations » (livre sans évaluation),
  point à trancher avec la conception de l'extracteur.

## Recette

1. **Une séance réelle** après modification de l'extension, avec défilement à la main de chaque page jusqu'en bas,
   comprenant au moins une **page 2** et un **Top gratuit** ; puis une page quittée volontairement sans défilement
   (attendu : rien capturé, compteur à 1, n/m affiché).
   Avant cette séance, un **test de l'extension sur une page de test** (valeurs inventées) où l'élément qui porte
   `data-client-recs-list` n'a **pas** la classe `p13n-desktop-grid` : attendu, la liste est reconnue, la page passe
   en attente (n/m affiché) et **n'est pas capturée immédiatement** ; elle l'est seulement quand n = m.
2. **Inventaire par Claude Code** des captures de cette séance, selon la méthode du 8 octobre (lecture seule,
   comptes et formes seulement) : **n = m sur chaque capture** (50/50, ou m/m pour une liste courte), rangs continus,
   cartes concordantes avec la liste ; présence des champs sur les rangs 31 à 50 et 81 à 100.
3. **Revalidation des quatre indices** (décision 004) sur ces pages de 50 cartes : `ok` pour leur propre demande,
   refus pour les demandes croisées, comme le 7 octobre sur des pages de 30 cartes.
4. Résultats consignés dans `docs/exploration-amazon.md`, et note datée ajoutée à cette décision.

## Conséquences

- Le code de l'extension, dans son dépôt privé (décision 006), est à modifier ; sa version est incrémentée.
- Une séance demande plus de gestes : chaque page doit être défilée jusqu'en bas. Le badge d'attente indique quand
  la page est complète ; une page quittée trop tôt est signalée, mais perdue jusqu'à la prochaine visite.
- **Limite** : une page quittée incomplète ne laisse aucune trace sur atlas. L'ingestion signale déjà une page 2
  annoncée mais absente du lot (décision 008) ; une page 1 jamais capturée n'est signalée que par le compteur de
  l'extension, pendant la séance.
- Le volume reste celui de la décision 005 : mêmes pages, même nombre de visites. Seuls les livres déjà affichés
  à l'écran sont désormais enregistrés en entier.

> Note du 8 octobre 2026 :
> - **Recette, test de la page sans `p13n-desktop-grid`** : assuré par un **test automatique de l'extension**, et non
>   par une page de test ouverte dans le navigateur. La liste blanche (décision 005, section 4) n'autorise l'extension
>   que sur les pages de classement d'amazon.fr : elle ne s'exécute sur aucune page locale.
> - **Définition commune de la liste classée** : `validation.py` ne retient un élément comme classé que si son
>   `metadataMap` est un objet JSON portant la clé `render.zg.rank`. Un `metadataMap` nombre, booléen, liste ou texte
>   vaut « pas de rang » : la page est déposée `invalid`, jamais un plantage. Avant cette correction, un nombre ou un
>   booléen faisait échouer l'ingestion (`TypeError`), et la capture, restée dans `inbox/`, l'aurait fait échouer
>   à chaque ingestion suivante. L'extension 0.2.0 applique la même règle.

> Note du 8 octobre 2026 (recette) :
> - **Séance réelle** du 8 octobre vers 18 h 20 UTC avec l'extension 0.2.0, chaque page défilée à la main :
>   7 captures, dont deux pages 2 de Top payant, une page 2 de Top gratuit et un Top gratuit court.
>   Rapporté par le porteur du projet : badge d'attente « ATT » affiché tant que la page n'était pas complète ;
>   une page quittée avant la fin du chargement a été comptée par l'extension, et rien n'a été capturé.
> - **Ingestion 12** sur atlas : 7 captures `ok`, aucune anomalie.
> - **Inventaire par Claude Code** (`docs/exploration-amazon.md`, « Recette de la décision 010 ») : **n = m sur les
>   7 captures** (50/50, et 44/44 pour le Top gratuit court), contre 30 cartes par page le 7 octobre ; les 134 cartes
>   des rangs 31-50 et 81-100 ont toutes un prix et une couverture, 123 une note et un nombre d'évaluations.
> - **Quatre indices** revalidés sur ces pages : `ok` pour leur propre demande, `invalid` pour les 21 demandes
>   croisées.
> - Le test automatique de la page sans `p13n-desktop-grid` appartient au dépôt de l'extension ; il n'est pas
>   examiné ici.
