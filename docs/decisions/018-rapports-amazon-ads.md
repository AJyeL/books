# 018 — Rapports Amazon Ads

Date : 4 novembre 2026 · **Acceptée**

## Contexte

La vision du projet prévoit d'importer les données des campagnes Amazon Ads du porteur du projet, pour les croiser plus
tard avec les classements organiques. Elle envisageait une ingestion automatique depuis une adresse e-mail dédiée.
Cette décision y renonce : le lien de téléchargement qu'Amazon envoie par e-mail est un **lien signé vers Amazon**.
Un programme qui le suivrait enverrait une requête à Amazon, ce que la décision 005 interdit.

Deux inventaires en lecture seule ont précédé cette décision, sur des rapports réels conservés hors du dépôt dans
`data/ads-inventaire/`. Ils n'ont produit que des comptes, des formes et des totaux. Leurs constats de structure sont
repris en annexe, sans aucune valeur :
- le 3 novembre 2026 : deux rapports Search term et un Advertised product, en dimension « Plage de dates » ;
- le 4 novembre 2026 : un Advertised product et un Search term, en dimension « Date », sur les 30 derniers jours.

Les rapports concernent les campagnes du porteur du projet. Ils contiennent cependant des **termes de recherche saisis
par des internautes**, qui peuvent contenir n'importe quel texte, y compris un nom de personne.

## Décision

### 1. Collecte

- **Le porteur du projet télécharge lui-même** chaque rapport, en cliquant sur le lien de l'e-mail d'Amazon.
- **Aucun programme ne suit ce lien ni n'ouvre la boîte mail.** Un lien signé vers Amazon tombe sous la décision 005,
  comme toute autre adresse d'Amazon.
- Les fichiers sont déposés dans un **dossier dédié du PC**, configuré dans le fichier local du script.
- Un **script d'envoi calqué sur `envoyer-captures`** (décision 008) les transmet à atlas :
  - une seule connexion SSH, mot de passe saisi à l'invite ;
  - une archive tar avec la liste des empreintes ;
  - un contrôle des empreintes avant le déplacement atomique de `attente/` vers `inbox/` ;
  - après le succès, une copie dans un sous-dossier `envoyes\AAAA-MM\` du PC ;
  - l'ingestion est lancée dans la même connexion, et son bilan s'affiche.
- Le script n'envoie que des fichiers `.csv`. Les autres sont signalés et restent sur place.

### 2. RAW

- **Chaque fichier est conservé intact**, octet pour octet, BOM compris.
- Il est inscrit dans RAW avec :
  - son **empreinte SHA-256** ;
  - son **type** ;
  - sa **date d'export** ;
  - l'horodatage UTC de son ingestion ;
  - son **statut** (`ok` ou `invalid`) et, le cas échéant, son **motif**.
- **Dédoublonnage** : un fichier dont l'empreinte est déjà dans RAW n'est pas redéposé. Il est mentionné « déjà ingéré »,
  sans anomalie, comme une capture (décision 008).
- **Type détecté par les en-têtes, jamais par le nom du fichier** :
  - Advertised product : présence de « Identifiant du produit promu » ;
  - Search term : présence de « Terme de recherche ».
  - Un fichier qui ne correspond à aucun type, ou aux deux, est `invalid`.
- **Date d'export lue dans le nom du fichier**, au format observé `{Type}_-_MM_JJ_AAAAThh_mm_ss.csv` :
  - mois puis jour, lus explicitement à leur position, jamais devinés ;
  - un nom qui ne suit pas ce format rend le fichier `invalid` ;
  - **contrôle** : la date d'export doit être strictement postérieure à la dernière date du fichier, sinon `invalid`.
  - Seul le **jour** est comparé, car le fuseau de l'heure du nom est inconnu (section « Inconnus »).
- La couche RAW n'est jamais modifiée après écriture (décision 001).

### 3. Acceptation

Un fichier n'est accepté (`ok`) que si toutes les conditions ci-dessous sont remplies. Sinon, il est conservé dans RAW
avec le statut `invalid` et son motif. **Il n'est jamais ignoré.**

- **Colonne « Date » présente.** Un rapport en « Plage de dates » ou en « Jour du mois » est `invalid`, avec le motif
  correspondant.
- **Colonnes requises présentes**, sous leur libellé exact :
  - **communes** : « Devise du budget », « Date », « Identifiant de la campagne », « Nom de la campagne »,
    « Identifiant du groupe de publicités », « Nom du groupe de publicités » ;
  - **mesures** : « Impressions », « Clics », « Coût total », « Achats », « Ventes », « Unités vendues »,
    « Lecture KENP », « Emprunts éligibles à l'abonnement Kindle »,
    « Estimation des redevances liées à l'abonnement Kindle » ;
  - **Advertised product** : en plus, « Identifiant du produit promu » et « Nom du produit promu » ;
  - **Search term** : en plus, « Terme de recherche », « Ciblage », « ID cible », « Type de cible » et
    « Type de correspondance associé au ciblage ».
- **Format conforme** : UTF-8 (BOM admis), virgule séparatrice, guillemets selon l'usage CSV, une ligne d'en-tête.
- **Devise `EUR`** sur toutes les lignes ; toute autre devise rend le fichier `invalid`.
- **Dates lisibles** : forme `J mmm. AAAA` ; un mot de mois hors de la liste connue rend le fichier `invalid`.
- **Mesures lisibles** : point décimal. Une cellule non numérique rend le fichier `invalid` ; une cellule vide est
  admise et reste une absence (section 4).
- **Grain respecté** : aucun doublon sur la clé du rapport (section 4), sinon `invalid`.
- **Colonne inconnue** (ni requise, ni connue) : le fichier reste accepté, la colonne est **signalée dans le bilan**.
  Sont connues, et ignorées, les colonnes de taux, celles du compte et du portefeuille, ainsi que les colonnes de
  produit et les colonnes vides ou toujours nulles relevées par l'inventaire (annexe).

> Note du 4 novembre 2026 (mise en œuvre, lot A) : **répartition des contrôles entre RAW et STAGING.** RAW ne juge que
> la **nature** du fichier, jamais son contenu : un verdict gravé dans une couche immuable, dédoublonnée par empreinte,
> ne pourrait jamais être corrigé si le validateur avait un défaut.
> - **RAW** (lot A, migration 011) : fichier vide ; encodage UTF-8 (BOM admis) ; type détecté par les en-têtes ;
>   rapport en « Plage de dates » ; rapport en « Jour du mois » ; colonne « Date » absente ; date et heure d'export
>   illisibles dans le nom. `raw.ads_report_file` conserve le type, la date et l'heure d'export, le statut et le motif ;
>   ni bornes de dates, ni nombre de lignes, ni contrainte sur la date d'export.
> - **STAGING** (lot B), en statuts d'extraction **recalculables**, retentés à chaque version de l'extracteur comme les
>   `parse_failed` : forme CSV, libellé en double, colonnes requises, devise, dates, mesures, doublons de grain, date
>   d'export postérieure à la dernière date du fichier, colonnes inconnues. Un fichier sans ligne de données n'y sera
>   pas une anomalie, mais un statut à part (« aucune activité rapportée »).

### 4. STAGING

- **Une table par type de rapport**, au grain vérifié par l'inventaire, pour un fichier RAW donné :
  - **Advertised product** : (date, campagne, groupe, produit) ;
  - **Search term** : (date, campagne, groupe, ID cible, type de correspondance, terme).
- **Chaque ligne est rattachée à son fichier RAW** : la clé complète est donc (fichier RAW, puis le grain ci-dessus).
- **Seules les quantités additives sont stockées** :
  - impressions, clics, achats, unités, KENP et emprunts, en entiers ;
  - coût, ventes et redevances estimées, en `numeric` à 5 décimales. Le coût a été exporté avec 2 décimales le
    12 octobre et 5 le 3 novembre : les deux sont lus sans perte.
- **Les taux d'Amazon ne sont jamais stockés** : taux de clics, taux d'achat, ROAS, coût par achat. Ils se recalculent
  à partir des quantités. L'inventaire a montré que le « Taux d'achat » d'Amazon est calculé sur les impressions et non
  sur les clics : un taux stocké sous ce nom serait trompeur.
- **Une absence n'est jamais remplie par un zéro.**
  - Une cellule vide devient `NULL`.
  - Un jour sans ligne dans un rapport reste sans ligne.
- **Identifiants** : la forme Excel `="…"` est retirée à la lecture, et l'identifiant est conservé en texte.
- **Dates** : type `date`, jamais d'horodatage, car un jour de rapport n'a pas de fuseau connu (section « Inconnus »).

### 5. Textes sensibles

- **Suivent le mécanisme de la décision 013** : terme de recherche, ciblage, noms de campagne et de groupe, titre du
  produit (« Nom du produit promu »).
- **STAGING ne contient que des identifiants et des codes** : identifiants d'Amazon (campagne, groupe, produit,
  ID cible), énumérations d'Amazon (« Type de cible », « Type de correspondance associé au ciblage ») et codes internes
  pour les textes.
- La correspondance « code → texte » vit dans le schéma séparé de la décision 013, accessible au seul rôle dédié.
- RAW reste nominatif, comme pour les captures (décision 013, section 2, « Limite assumée ») : cela vaut pour les
  fichiers sur atlas, leurs sauvegardes et la copie `envoyes\` du PC.

> Note du 4 novembre 2026 : le mécanisme est décrit par la décision 019 (natures `search_term`, `targeting`,
> `campaign`, `ad_group` et `product_title` ; étape 1 mise en œuvre par la migration 010, sans utilisateur). Son
> utilisation par les rapports Ads sera l'étape 3.

### 6. Chevauchement des rapports

- Des rapports successifs couvrent les mêmes jours. **Tous sont gardés**, en observations datées par leur date d'export.
- Ce choix est justifié par l'inventaire : entre deux exports, les impressions d'un même jour ont été **révisées après
  coup** par Amazon.
- La **meilleure estimation** d'un jour est calculée dans une **vue**, sans jamais écraser une donnée.
  - Pour chaque type de rapport et chaque jour, elle retient **l'export le plus récent qui couvre ce jour**. Ordre :
    date d'export, puis heure lue dans le nom, puis ordre d'ingestion.
  - **Toutes les lignes de ce jour viennent de ce seul export.** Une ligne présente dans un export plus ancien et
    absente du plus récent n'est pas reprise : on ne mélange pas deux exports pour un même jour.

> Note du 5 novembre 2026 (mise en œuvre, lot B, migration 012), **corrigée le même jour après l'audit** : la
> couverture se décide **par export**, le gagnant **par jour et par type**.
> - Un export, ce sont les fichiers de même date d'export ; sa **couverture** est la réunion des bornes (première et
>   dernière date) de ses fichiers extraits `ok`. Un fichier « aucune activité rapportée » n'a pas de bornes : il ne
>   couvre aucun jour à lui seul.
> - Pour chaque jour et chaque type, l'emporte l'**export le plus récent qui contient un fichier de ce type**, au
>   statut `ok` ou `no_activity`, et dont la couverture inclut ce jour.
> - Un fichier `no_activity` est une **observation d'absence** : il l'emporte, sans ligne. Un jour couvert sans ligne
>   dans le fichier retenu a pour meilleure estimation l'absence ; un export plus ancien n'est jamais repris pour ce
>   type et ce jour.
> - Un export **sans fichier d'un type** n'observe rien de ce type : il ne masque jamais un export plus ancien qui en
>   avait un. Défaut corrigé : la première version désignait un seul export gagnant par jour pour les deux types ;
>   un export récent sans Search term effaçait alors la meilleure estimation des termes (une absence d'observation lue
>   comme une observation d'absence).
> - Deux fichiers du même type et de même date d'export : le plus récent par l'heure l'emporte, avec une information
>   au bilan.
> - Vues : `staging.ads_day_source` (une ligne par jour et par type : export et fichier retenus),
>   `staging.ads_product_day_best`, `staging.ads_search_term_day_best`.

### 7. Contrôles dans le bilan

- **Réconciliation Advertised product / Search term**, jour par jour, pour un même export.
  - Deux fichiers forment un même export s'ils ont la même date d'export et couvrent exactement les mêmes jours.
  - Mesures comparées : coût, clics, impressions, achats, ventes, KENP, emprunts.
  - **Chaque écart est une anomalie**, avec le jour et l'écart.
  - Un fichier sans partenaire est signalé en information.
- **Fraîcheur** : « Aucun rapport Amazon Ads de moins de 10 jours ».
  - Signalé quand le dernier fichier `ok` a plus de 10 jours, à compter de sa date d'export.
  - Le contrôle est fait pour chaque type de rapport.
- **Colonnes jamais vues non nulles** : « Emprunts éligibles à l'abonnement Kindle » et « Estimation des redevances
  liées à l'abonnement Kindle » sont signalées tant qu'aucune valeur non nulle n'a été observée dans un fichier `ok`.
- **Colonne inconnue** : signalée (section 3).

> Note du 5 novembre 2026 (mise en œuvre, lot B) :
> - **Fraîcheur** : l'extraction des rapports ne tourne que lorsqu'un rapport arrive ; elle ne peut donc pas dire
>   qu'aucun n'est arrivé. Le contrôle vit dans le **bilan de l'extraction des captures**, qui tourne après chaque
>   envoi de captures, en **information**, sans effet sur le code de sortie ; d'après la date d'export du dernier
>   rapport RAW `ok` de chaque type.
> - **Réconciliation** : les deux fichiers retenus d'un export (même date d'export seulement), comparés jour par jour
>   sur la réunion de leurs jours ; un jour présent d'un seul côté est un écart (anomalie) ; une mesure dont une
>   cellule est vide n'est pas comparée (information). Seuls les exports dont un fichier vient d'être extrait sont
>   réconciliés ; `--force` les réconcilie tous.
> - **Statuts d'extraction** : `ok`, `no_activity` (ni succès ni anomalie), `parse_failed`, `integrity_failed`. Un
>   fichier déjà extrait par la même version n'est pas réextrait ; ses échecs restent signalés au bilan (anomalie)
>   jusqu'à la version suivante, qui les retente. Deux cas de contenu s'ajoutent aux motifs de la section 3 : une
>   cellule vide dans une colonne du grain (« clé du grain incomplète ») et un texte de plus de 2 000 octets (refusé
>   par `mapping.code_for`).
> - **Version propre** : `ADS_EXTRACTOR_VERSION`, distincte de celle de l'extracteur des pages ; toute modification
>   des règles d'analyse des rapports l'incrémente, dans le même commit.

### 8. Tests

- **Uniquement sur des fichiers inventés**, jamais dérivés d'un vrai rapport.
- Ils reproduisent la forme réelle :
  - BOM UTF-8 et fins de ligne CRLF ;
  - identifiants en `="…"` ;
  - dates en mois abrégés français, jour sans zéro initial ;
  - point décimal et coût à 2 ou 5 décimales ;
  - une virgule dans un champ entre guillemets.
- **Contre-épreuves**, chacune devant aboutir à `invalid` avec le bon motif :
  - un rapport en « Plage de dates », un autre en « Jour du mois » ;
  - une colonne requise absente ;
  - un mot de mois inconnu ;
  - une devise autre que `EUR` ;
  - une valeur non numérique ;
  - un doublon de clé ;
  - un nom de fichier hors format ;
  - une date d'export antérieure ou égale à la dernière date du fichier.
- **Autres vérifications** :
  - une colonne inconnue est signalée et le fichier reste accepté ;
  - un fichier déjà reçu est dédoublonné ;
  - une cellule vide devient `NULL`, jamais 0 ;
  - la vue de meilleure estimation retient l'export le plus récent sans écraser l'ancien ;
  - un écart de réconciliation inventé est signalé.

## Inconnus

- **Sens de « Plage de dates »** : dans les rapports cumulés, la plage varie d'une ligne à l'autre.
  - Le 3 novembre, l'hypothèse d'une plage égale à la période d'activité de la ligne semblait confirmée : les lignes
    terminées avant le 12 octobre avaient un coût, des clics et des ventes identiques dans deux exports successifs.
  - Le 4 novembre, elle a été contredite : la grande majorité des clés dont la plage se termine dans la fenêtre du
    5 octobre au 3 novembre n'apparaissent pas dans le rapport journalier de cette fenêtre.
  - Sens inconnu : rien ne s'appuie sur cette colonne, d'où le refus de ces rapports (section 3).
- **Lignes absentes et lignes à zéro** :
  - l'Advertised product journalier a donné une ligne chaque jour pour chaque couple (groupe, produit), mais chaque
    couple a eu des impressions chaque jour : aucun jour sans impression n'a été observé, on ne sait donc pas si Amazon
    écrirait une ligne à zéro ;
  - le Search term journalier n'a que quelques lignes à zéro impression, et omet toutes les autres combinaisons ;
  - on ne sait pas si une ligne absente du Search term signifie « aucune impression » ou « non rapportée ». Elle n'est
    donc jamais lue comme un zéro (section 4).
- **Emprunts et redevances estimées** : toujours nuls dans les rapports observés, alors que la lecture KENP ne l'est pas
  toujours. On ne sait pas si ces colonnes sont alimentées : d'où le signalement de la section 7.
- **Fuseaux horaires** :
  - celui des jours des rapports (heure de Paris, UTC ou autre) n'est pas documenté dans les fichiers ;
  - celui de l'heure qui figure dans le nom du fichier n'est pas connu non plus.
  - Les jours sont stockés en `date` et la date d'export est contrôlée au jour près, sans conversion en UTC.
- **Révisions** : on ne sait pas pendant combien de jours Amazon révise les chiffres d'un jour passé.
- **Mois de décembre** : son abréviation n'a pas été observée. « déc. » est attendu par analogie ; une autre forme
  rendrait le fichier `invalid`, ce qui est une erreur visible.
- **Rapports non inventoriés** : la forme exacte d'un rapport en « Jour du mois » n'a pas été relevée ; il est refusé
  par la seule absence de la colonne « Date ».

## Hors périmètre

- **Rapports Targeting et Placement** : non traités ; une décision dédiée sera nécessaire, après inventaire.
- **Accès de `books_reader` aux tables Ads**, ainsi qu'aux vues de meilleure estimation : à décider plus tard. D'ici
  là, `books_reader` n'y a aucun droit (liste blanche de la décision 016).
- **Croisement avec les classements organiques** : à traiter dans une décision d'analyse, avec les précautions habituelles
  (une corrélation n'est pas une causalité).

## Conséquences

- Nouveau script d'envoi sur le PC, calqué sur `envoyer-captures`, et son pendant de réception sur atlas.
- Migration à prévoir : une table RAW pour les fichiers de rapports, une table STAGING par type de rapport, la vue de
  meilleure estimation, et les droits des rôles existants (`books_collector` pour RAW, `books_transformer` pour STAGING).
- Le test de liste blanche de `books_reader` (décision 016) devra être mis à jour pour confirmer l'absence de droits sur
  ces nouvelles tables.
- La mise en œuvre de la décision 013 (schéma séparé, rôle dédié) devient un préalable à STAGING pour les textes.

## Annexe : constats de structure des inventaires (3 et 4 novembre 2026)

Formes seulement, aucune valeur. Échantillon : les rapports d'un seul compte, exportés entre le 12 octobre et le
4 novembre 2026.

- **Fichier** : CSV en UTF-8 avec BOM, virgule séparatrice, guillemets doubles si besoin, fins de ligne CRLF (dernière
  ligne comprise), une seule ligne d'en-tête, libellés en français.
- **Identifiants** de campagne et de groupe sous la forme Excel `="999…"` ; identifiant de portefeuille et
  identifiant parent sous la forme `-9`.
- **Dates** : colonne « Date » (rapports journaliers) ou « Plage de dates » (`J mmm. AAAA - J mmm. AAAA`). Mois
  observés : `janv.`, `févr.`, `mars`, `avr.`, `mai`, `juin`, `juil.`, `août`, `sept.`, `oct.`, `nov.`.
- **Nombres** : point décimal, aucun séparateur de milliers ; taux suffixés par `%`, à 4 décimales ; coût à 2 ou
  5 décimales selon l'export ; devise dans la colonne « Devise du budget » (`EUR`), aucun symbole dans les cellules.
- **Formules d'Amazon**, vérifiées à l'arrondi près :
  - taux de clics = clics ÷ impressions × 100 ;
  - taux d'achat = achats ÷ **impressions** × 100 ;
  - ROAS = ventes ÷ coût ;
  - coût par achat = coût ÷ achats.
- **Colonnes redondantes ou vides** :
  - les variantes « (promus) » et « (sponsorisé(e)s) » sont identiques, cellule par cellule, aux colonnes sans suffixe ;
  - les colonnes « (halo) » sont toujours à 0 ;
  - les colonnes « (premier achat de la marque) » et « vues de la page produit » sont toujours vides.
- **Grain des rapports journaliers** : aucun doublon sur les clés de la section 4.
  - L'Advertised product a une ligne par jour pour chaque couple (groupe, produit) ; chaque couple a eu des impressions
    chaque jour, si bien qu'aucun jour sans impression n'a été observé ;
  - le Search term n'a de lignes que pour les combinaisons rapportées.
- **Réconciliation** : les deux rapports journaliers d'un même export concordent jour par jour sur toutes les mesures
  additives. Dans les rapports cumulés, les impressions différaient légèrement ; le coût, les clics et les ventes
  concordaient.
- **Ciblage** :
  - de la forme `mot="…"` ;
  - « Type de cible » : `rsf` ; « Type de correspondance associé au ciblage » : `TARGETING_EXPRESSION` ;
  - un même ciblage a un ID cible distinct dans chaque groupe ;
  - pour un ciblage produit (valeur de forme ASIN), le terme de recherche n'est jamais égal à l'ASIN ciblé.
- **Limites** : un seul compte, deux campagnes, un mois et demi d'exports, une seule langue d'interface. Toute forme
  non observée doit produire un refus visible, jamais une lecture silencieuse.
