# 005 — Collecte semi-manuelle

Date : 6 octobre 2026

> Analyse réalisée par un non-juriste, sans valeur d'avis juridique.

## Contexte

La décision 002 prévoyait une collecte automatisée sobre. L'examen des conditions d'utilisation d'Amazon
a conduit à y renoncer :

- **Conditions d'utilisation d'amazon.fr** : la licence d'accès au site exclut l'usage de robots et d'outils
  d'extraction ou de collecte automatisée de données. Une collecte automatisée, même à faible volume,
  ne serait pas compatible avec ces conditions. Aucune collecte automatisée n'a été réalisée : la source réseau
  prévue par la décision 004 n'a jamais été écrite, et le collecteur n'a jamais lu que des pages enregistrées.
- **Droit du producteur de base de données** (articles L341-1 et suivants du Code de la propriété intellectuelle) :
  Amazon peut protéger le contenu de ses classements contre l'extraction d'une partie substantielle, et contre
  l'extraction répétée et systématique de parties non substantielles. Ce droit vaut quel que soit l'outil :
  il ne disparaît pas avec une collecte manuelle.
- **Enjeu personnel** : le porteur du projet publie ses livres via Kindle Direct Publishing et entend respecter
  les règles d'Amazon dans l'ensemble de ses activités.
- **robots.txt n'est pas une autorisation juridique** : c'est une convention technique adressée aux robots.
  Qu'une adresse y soit « autorisée » (décision 002, section 3) ne vaut ni accord d'Amazon, ni dérogation à ses
  conditions d'utilisation, ni licence sur ses données.

## Décision

### 1. Renoncement

B.O.O.K.S. renonce à toute collecte réseau automatisée sur Amazon, et à tout proxy ou moyen de changer d'adresse.
Aucun programme du projet n'envoie de requête à Amazon : ni le collecteur, ni atlas, ni l'extension décrite ci-dessous.

### 2. Principe : je navigue, l'extension enregistre

- Le porteur du projet consulte lui-même les pages de classement, à la main, dans son navigateur.
- Une extension de navigateur enregistre les pages **qu'il a affichées**.
- **Règle absolue : l'extension n'ouvre ni ne demande jamais une page elle-même.** Elle n'ouvre aucun onglet,
  ne recharge rien, ne suit aucun lien, n'envoie aucune requête vers Amazon et ne programme aucune visite.
  Elle ne fait que lire la page déjà affichée.
- Si une page de vérification (CAPTCHA) s'affiche, l'extension ne tente jamais de la résoudre ni de la contourner.
  Le porteur du projet peut y répondre lui-même, comme tout visiteur, puis poursuivre sa consultation.
  La page de vérification n'est jamais enregistrée comme classement (classée `blocked`).
- Une vérification est un signal, traité de façon graduée :
  - première vérification de la séance : réponse humaine, puis poursuite ;
  - deuxième vérification dans la même séance : arrêt de la séance pour la journée ;
  - vérifications plusieurs jours de suite : réexamen de la pratique (rythme, nombre de pages) avant de reprendre.

### 3. Navigateur dédié

- Google Chrome, avec un **profil dédié à la veille** (ou une installation dédiée).
- **Jamais connecté** : ni compte Google, ni compte Amazon. Aucune synchronisation.
- **Aucune autre extension** que celle de B.O.O.K.S.
- Raisons :
  - des pages **représentatives** de ce que voit un visiteur sans compte : pas de bloqueur de publicité ni d'extension
    qui modifierait la page, pas de personnalisation liée à un compte ;
  - la **séparation des activités** : le compte d'auteur KDP n'est jamais utilisé dans ce navigateur, et la veille
    ne se fait jamais depuis une session de ce compte. Les deux usages restent distincts.
- Cette séparation porte sur les comptes et les sessions, pas sur la connexion : la veille utilise la même connexion
  internet, et donc la même adresse IP, que la navigation personnelle du porteur du projet. Aucun moyen de modifier
  cette adresse n'est employé.

### 4. Extension

- **Mode enregistrement** activé et désactivé à la main. Désactivé par défaut, à chaque démarrage du navigateur.
- **Badge visible** sur l'icône de l'extension tant que le mode est actif.
- **Liste blanche d'adresses** : l'extension n'agit que sur les pages de classement Kindle
  (`https://www.amazon.fr/gp/bestsellers/digital-text/…`). Ses permissions se limitent à ces adresses. Sur toute
  autre page, elle ne lit rien et n'enregistre rien.
- Les **fiches produit** sont exclues. Elles contiennent des avis clients nominatifs : leur ajout attendra une
  décision RGPD dédiée (décision 002, section 6), puis un élargissement explicite de la liste blanche.

### 5. Capture

- La page est capturée **telle qu'elle est affichée** : le DOM du document, c'est-à-dire la page après son exécution
  par le navigateur. **Aucune nouvelle requête** n'est faite pour la capturer.
- Sont enregistrés avec chaque page : l'adresse affichée, l'horodatage UTC de la capture et la **méthode de capture**
  (par exemple `extension-dom` et sa version). La méthode figure dans RAW, à côté de chaque page : une page capturée
  dans le DOM et une réponse HTML du serveur ne sont pas des objets identiques. Le schéma RAW actuel n'a pas de
  colonne pour cela : une migration sera nécessaire.
- **La validation devra être vérifiée sur ces captures avant tout usage.** Elle a été mise au point sur le HTML
  du serveur. Dans le DOM, le navigateur peut avoir modifié la page : cartes chargées au défilement (plus de 30),
  attributs réordonnés ou ajoutés, éléments insérés par les scripts. Les quatre indices de la décision 004
  (canonical, onglet actif, pagination, rangs) devront être revérifiés sur de vraies captures.
- Point à vérifier, lié : la méthode d'enregistrement manuelle utilisée jusqu'ici (Ctrl+S, « HTML uniquement »)
  pourrait refaire une requête. Le 5 octobre 2026, deux enregistrements successifs de la même page différaient
  par leurs jetons propres à chaque requête (`docs/exploration-amazon.md`), sans qu'on sache lequel des deux
  avait provoqué la nouvelle requête. La capture par l'extension n'a pas cette incertitude.

## Conséquences

- **La source réseau est abandonnée** : elle ne sera pas écrite.
- **La source locale devient la source de production.** Elle refuse aujourd'hui de se construire en `prod`
  (fail closed de la décision 004) : à adapter. Le principe de fail closed demeure, sous une autre forme
  (en dev, des fixtures et des pages de test ; en prod, uniquement les captures de l'extension).
- **Avis d'un juriste requis avant toute exploitation commerciale** (service de veille, audits, abonnements).
  La collecte semi-manuelle repose sur une consultation humaine ordinaire du site. Son appréciation au regard
  des conditions d'utilisation d'Amazon et du droit du producteur de base de données relève de cet avis.
- Le volume reste modeste : toute extension du périmètre (catégories, fréquence) devra tenir compte de la notion
  d'extraction substantielle ou répétée et systématique.
- L'historique dépendra de la régularité des visites manuelles : séries temporelles irrégulières et trous à prévoir,
  à signaler dans les analyses.

### Parties des décisions précédentes rendues caduques ou modifiées

Des notes datées du 6 octobre 2026 ont été ajoutées dans ces décisions, sans réécrire leur texte d'origine.

| Décision | Partie | Effet |
|---|---|---|
| 002 | 1. Critère général | Maintenu et renforcé : aucune collecte automatisée, aucun proxy ; aucune résolution de CAPTCHA par un programme ; réponse humaine permise selon la règle graduée (section 2) |
| 002 | 2. Identité (User-Agent `books-collector`, adresse de contact) | Caduque : aucune requête automatisée |
| 002 | 3. robots.txt (relecture à chaque tournée, lecteur à jokers) | Caduque ; la vérification du 4 octobre reste un constat historique, et robots.txt n'est pas une autorisation (voir Contexte) |
| 002 | 4. Modération (pause, plafond de 200 requêtes, collecte de nuit) | Caduque pour les requêtes ; le plafond du collecteur ne compte plus des requêtes mais des pages lues |
| 002 | 5. Disjoncteur (HTTP 429/503, reprise sur plusieurs nuits) | Caduque pour le réseau ; comportement de l'ingestion face à une capture `blocked` ou `invalid` à redéfinir, voir questions ouvertes |
| 002 | 6. Données personnelles (RGPD) | Maintenue, et étendue à l'extension (fiches produit exclues) |
| 002 | Conséquences « risque assumé » et « adresse de contact à créer » | Remplacées par la présente décision |
| 003 | Prérequis avant la première collecte en production | Le rôle `books_collector` reste utile ; « collecte » se lit désormais « ingestion des captures » |
| 004 | Sources interchangeables, `NetworkSource`, fail closed par environnement | Modifié : plus de source réseau ; la source locale servira aussi en prod |
| 004 | Page 2 conditionnelle (« demander ») | Modifié : rien n'est demandé ; la règle des deux signaux sert à contrôler qu'une page 2 annoncée a bien été capturée |
| 004 | Ordre des pages, plafond pendant la tournée, `requested_url` | Modifiés : l'ordre est celui de la navigation ; `requested_url` devient l'adresse affichée |
| 004 | Validation (quatre indices), dépôt RAW, statuts | Maintenus, sous réserve de vérification sur les captures DOM |

## Questions ouvertes, non tranchées

- **Transfert des fichiers vers atlas** : les captures sont faites sur le PC ; comment, et par qui, rejoignent-elles
  `~/books-data` sur atlas ?
- **Déclenchement de l'ingestion sur atlas** : manuel, programmé, ou à l'arrivée des fichiers ?
- **Comportement de l'ingestion face à une capture `blocked` ou `invalid`** : arrêt, ou dépôt avec son statut
  puis poursuite ? L'arrêt protégeait le serveur dans une collecte automatisée ; à l'ingestion, il n'y a plus
  de serveur à ménager. Avec la règle graduée de la section 2, une page de vérification peut être suivie de captures
  valides, qu'un arrêt ferait perdre.
- **Sort des doublons** : la même page enregistrée deux fois (même catégorie, même liste, même page, à quelques minutes
  d'intervalle). Les deux sont-elles déposées dans RAW, et laquelle les couches suivantes retiennent-elles ?
  L'empreinte du HTML ne permet pas de les reconnaître (jetons propres à chaque requête, décision 001).
