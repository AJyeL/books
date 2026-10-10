# 013 — Données personnelles des auteurs

Date : 10 octobre 2026

> Analyse réalisée par un non-juriste, sans valeur d'avis juridique. Chaque affirmation renvoie à une source primaire
> (section « Sources ») ; ce qui relève de l'interprétation est présenté comme une question pour les juristes.

## Contexte

La décision 002 (section 6) pose que les noms d'auteurs sont des données personnelles, traitées sur la base de
l'intérêt légitime pour la seule analyse de marché, et qu'une phase commerciale exigera un registre et une mention
d'information. Depuis, la décision 011 (section 9) interdit à l'extracteur de lire l'auteur, « décision RGPD en
attente ». La présente décision est cette décision : elle dit comment les auteurs pourront être traités, et ce qui
doit être confirmé par des juristes avant toute exploitation commerciale.

## Décision

### 1. Constat : où sont les données personnelles

- Une donnée à caractère personnel est « toute information se rapportant à une personne physique identifiée ou
  identifiable », directement ou indirectement, notamment par un nom ou un identifiant en ligne (RGPD, art. 4, 1)).
- Les pages de classement affichent pour chaque livre le nom d'un auteur et, le plus souvent, un lien vers sa page
  d'auteur portant un identifiant Amazon (`/{nom}/e/{id}`, `docs/exploration-amazon.md`). Ces noms et identifiants
  sont présents dans :
  - **RAW** sur atlas (HTML des captures, jamais modifié, décision 001) ;
  - les **sauvegardes** de RAW et de la base sur atlas (`~/books-backup`), et les **copies de la base sur le PC**
    (décision 009, conservées sans suppression automatique) ;
  - l'archive des captures sur le PC, **`envoyees\`** (décision 008, jamais vidée).
- **Pseudonymes compris** : un nom de plume renvoie à une personne physique ; il est traité ici comme une donnée
  personnelle, par prudence. Ce point est à confirmer par les juristes (section 4).
- STAGING n'en contient aucune à ce jour (décision 011, section 9 ; vérifié par le test RGPD de l'extracteur).

### 2. Pseudonymisation par séparation

- **STAGING ne portera qu'un code d'auteur** : un identifiant numérique interne, sans nom.
- La **correspondance** « code → nom affiché + identifiant d'auteur Amazon » vivra dans un **schéma séparé**,
  accessible par un **rôle dédié**, jamais utilisé pour l'analyse ni pour les tableaux de bord.
- **C'est une pseudonymisation, pas une anonymisation.** Le RGPD définit la pseudonymisation comme un traitement
  tel que les données « ne puissent plus être attribuées » à une personne sans informations supplémentaires,
  conservées séparément et protégées (art. 4, 5)). Les données pseudonymisées restent des données concernant une
  personne identifiable (considérant 26) : **elles restent soumises au RGPD**. Seules des informations réellement
  anonymes en sortent (considérant 26) ; la CNIL rappelle que la pseudonymisation est réversible et ne retire pas
  le caractère personnel des données.
- Fondement : le RGPD cite la pseudonymisation parmi les mesures de protection des données dès la conception
  (art. 25, 1)) et de sécurité (art. 32, 1), a)), et l'admet au sein d'un même responsable de traitement si les
  informations supplémentaires sont conservées séparément (considérant 29). Le CEPD décrit cette séparation comme
  un « domaine de pseudonymisation » dont les données ne sortent pas sans autorisation (lignes directrices 01/2025,
  version soumise à consultation).
- **Limite assumée** : RAW, ses sauvegardes et `envoyees\` restent nominatifs (section 1). La séparation protège
  les couches d'analyse, pas les couches de conservation, dont l'accès reste limité aux rôles et aux personnes
  qui en ont besoin.

### 3. Sorties

- Les **analyses** portent sur les codes et produisent des résultats **agrégés** (par catégorie, par période,
  par tranche), sans nom.
- **Un nom n'apparaît que dans une sortie couverte par une décision dédiée**, qui en précise la finalité et la
  nécessité. Exemple envisagé : les auteurs de livres concurrents cités dans un rapport d'audit commandé par un client.
- **Couvertures et descriptions** : ni affichage ni citation sans décision dédiée (la couverture porte en général le
  nom de l'auteur ; la description relève aussi du droit d'auteur). STAGING conserve l'adresse de la couverture
  (`cover_url`, décision 011), sans l'afficher.

### 4. Questions à faire confirmer par écrit, par des juristes, avant toute exploitation commerciale

1. **Base légale** : l'intérêt légitime (art. 6, 1, f)), avec une **mise en balance documentée**, plutôt que l'intérêt
   public (art. 6, 1, e)), qui suppose une mission d'intérêt public. Le CEPD exige trois conditions cumulatives
   (intérêt légitime, nécessité, mise en balance) et refuse que cette base serve « par défaut » (lignes directrices
   1/2024). Pour la réutilisation de données publiées sur internet, la CNIL indique que l'intérêt légitime s'apprécie
   au cas par cas, en tenant compte notamment des attentes raisonnables des personnes, et que le caractère public
   d'une donnée ne suffit pas (délibération n° 2024-041). Sa fiche sur le moissonnage, rédigée pour l'IA mais utile
   par analogie, recommande la minimisation, la pseudonymisation dès la collecte et une liste d'opposition.
2. **Portée de l'article 89** : les fins statistiques bénéficient de garanties et d'aménagements (art. 5, 1, e) ;
   art. 17, 3, d) ; art. 21, 6) ; art. 89), à condition de garanties appropriées, dont la pseudonymisation
   (art. 89, 1)). Ces aménagements couvrent-ils des **statistiques agrégées** ? Et quel régime s'applique aux
   **sorties nominatives commerciales** (section 3), qui ne sont plus des statistiques ? Les dérogations de
   l'art. 89, 2) supposent en outre un texte de droit de l'Union ou national : lequel, le cas échéant ?
3. **Durée de conservation** (art. 5, 1, e)) de RAW, des sauvegardes, des copies sur le PC (décision 009 : aucune
   suppression automatique) et de `envoyees\` (décision 008 : jamais vidé).
4. **Effacement dans RAW** : RAW n'est jamais modifié (décision 001). Face à une demande d'effacement (art. 17, 1, c),
   après une opposition), une **réécriture tracée** de RAW est-elle exigée, ou l'**exclusion** (section 6) suffit-elle ?
5. **Pseudonymes** : confirmer qu'un nom de plume est une donnée personnelle (section 1).

Question adressée par écrit à la CNIL le 9 octobre 2026, réponse attendue ; la décision sera révisée à réception.

### 5. Transparence

- Les données ne sont pas collectées auprès des auteurs : l'information relève de l'article 14. Son paragraphe 5, b)
  dispense de l'information individuelle lorsqu'elle « exigerait des efforts disproportionnés », à condition de prendre
  des mesures appropriées, « y compris en rendant les informations publiquement disponibles ».
- B.O.O.K.S. **invoquera l'article 14, 5, b)**, avec une **notice publique** (finalité, données traitées, durée de
  conservation, droits, contact), publiée **avant toute exploitation commerciale**.
- Cette exception s'interprète strictement, au cas par cas, et la charge de la preuve pèse sur le responsable
  (lignes directrices sur la transparence du G29, reprises par la CNIL ; délibération n° 2024-041). La justification
  sera écrite dans le registre (section 7) et soumise aux juristes avec les questions de la section 4.

### 6. Opposition et effacement

- Droit d'opposition (art. 21, 1)) et, à sa suite, droit à l'effacement (art. 17, 1, c)) : réponse en deux temps.
  1. **Suppression de la correspondance** de l'auteur dans le schéma séparé : ses codes restent dans STAGING, mais
     ne renvoient plus à personne dans les couches d'analyse.
  2. **Liste d'exclusion** appliquée par l'extracteur : l'identifiant d'auteur Amazon (ou, à défaut, le nom affiché)
     des personnes opposées ; l'extracteur ne leur attribue plus de code, et leurs lignes futures n'en portent aucun.
- La liste d'exclusion est elle-même une donnée personnelle, conservée pour la seule fin de respecter l'opposition,
  dans le schéma séparé.
- Le sort de RAW dépend de la réponse à la question 4 de la section 4.

### 7. Registre du traitement

- Un registre des activités de traitement (art. 30) est tenu **en privé, hors du dépôt public** (dossier `private/`,
  jamais commité). L'exception de l'article 30, 5) (moins de 250 employés) ne joue pas pour un traitement qui
  « n'est pas occasionnel » : la collecte est régulière.
- Contenu minimal selon l'art. 30, 1) et la CNIL : responsable, finalités, catégories de personnes et de données,
  destinataires, délais d'effacement, mesures de sécurité. Le registre reçoit aussi la mise en balance (section 4)
  et la justification de l'article 14, 5, b) (section 5).

## Conséquences et impact sur l'existant

- **Rien n'est modifié dans le code par cette décision.** La mise en œuvre de la section 2 sera une étape dédiée,
  décidée et testée à part. D'ici là, la règle de la décision 011 (section 9) reste en vigueur : l'extracteur ne lit
  aucun auteur.
- **Décision 011** : la section 9 sera remplacée lors de cette étape. L'extracteur lira le nom affiché et
  l'identifiant d'auteur Amazon, n'écrira dans `staging.ranking_entry` qu'un code, et remettra le nom au schéma
  séparé. Comme toute règle d'analyse modifiée, cela incrémentera `EXTRACTOR_VERSION`. Cas déjà observés à traiter :
  un seul auteur affiché par carte ; des cartes sans lien d'auteur (5 sur 210 le 7 octobre, nom sans identifiant).
- **Test RGPD de l'extracteur** (`tests/python/test_parsing.py`, auteur sentinelle) : il vérifie aujourd'hui que
  l'auteur n'apparaît nulle part. Il deviendra : le nom et l'identifiant n'apparaissent dans **aucun** champ de
  STAGING, ni dans les motifs d'échec ni dans les bilans ; ils n'apparaissent **que** dans le schéma séparé ; avec
  contre-épreuve.
- **Rôles** : un rôle dédié à la correspondance. `books_transformer` ne pourra pas lire la correspondance ; pour
  obtenir un code, il passera par une fonction qui ne rend que le code (piste à étudier, par exemple une fonction
  `SECURITY DEFINER` du rôle dédié). `books_collector` n'aura aucun accès. Les futurs rôles d'analyse et de tableau
  de bord n'y auront pas accès.
- **Sauvegardes et copies** : un `pg_dump` de la base contiendra le schéma séparé ; les copies sur le PC
  (décision 009) aussi. La durée de conservation (section 4, question 3) s'appliquera à ces copies.
- **Inventaires** : la règle des études hors ligne (`docs/exploration-amazon.md` : comptes seulement, auteur jamais
  lu) reste en vigueur.
- **Avis d'un juriste** : la décision 005 l'exigeait déjà avant toute exploitation commerciale ; les questions de la
  section 4 en précisent le contenu.

## Sources

Texte du règlement :
- Règlement (UE) 2016/679 (RGPD), texte officiel, EUR-Lex : considérants 26 et 29 —
  https://eur-lex.europa.eu/legal-content/FR/TXT/?uri=CELEX:32016R0679
- RGPD, texte reproduit par la CNIL, par chapitre :
  - chapitre I, art. 4 (définitions : 1) données à caractère personnel, 5) pseudonymisation) —
    https://www.cnil.fr/fr/reglement-europeen-protection-donnees/chapitre1
  - chapitre II, art. 5 (principes) et 6 (licéité) —
    https://www.cnil.fr/fr/reglement-europeen-protection-donnees/chapitre2
  - chapitre III, art. 14 (information en cas de collecte indirecte), 17 (effacement), 21 (opposition) —
    https://www.cnil.fr/fr/reglement-europeen-protection-donnees/chapitre3
  - chapitre IV, art. 25 (protection dès la conception), 30 (registre), 32 (sécurité) —
    https://www.cnil.fr/fr/reglement-europeen-protection-donnees/chapitre4
  - chapitre IX, art. 89 (fins archivistiques, de recherche ou statistiques) —
    https://www.cnil.fr/fr/reglement-europeen-protection-donnees/chapitre9

CNIL :
- L'anonymisation de données personnelles (anonymisation et pseudonymisation) —
  https://www.cnil.fr/fr/technologies/lanonymisation-de-donnees-personnelles
- Recherche scientifique (hors santé) : enjeux et avantages de l'anonymisation et de la pseudonymisation —
  https://www.cnil.fr/fr/recherche-scientifique-hors-sante-enjeux-et-avantages-de-lanonymisation-et-de-la-pseudonymisation
- Délibération n° 2024-041 du 25 janvier 2024 (ouverture et réutilisation de données publiées sur internet),
  Légifrance — https://www.legifrance.gouv.fr/jorf/id/JORFTEXT000049722937 ;
  présentation par la CNIL —
  https://www.cnil.fr/fr/ouverture-et-reutilisation-de-donnees-personnelles-sur-internet-la-cnil-publie-ses-recommandations
- La base légale de l'intérêt légitime : fiche focus sur la collecte par moissonnage (web scraping) —
  https://www.cnil.fr/fr/focus-interet-legitime-collecte-par-moissonnage
- Le registre des activités de traitement — https://www.cnil.fr/fr/RGPD-le-registre-des-activites-de-traitement
- Groupe de travail « Article 29 », lignes directrices sur la transparence (WP260), version française publiée par la
  CNIL — https://www.cnil.fr/sites/cnil/files/atoms/files/wp260_guidelines-transparence-fr.pdf

Comité européen de la protection des données (CEPD) :
- Lignes directrices 1/2024 sur le traitement fondé sur l'article 6, 1, f) (intérêt légitime), version 1.0 du
  8 octobre 2024 — https://www.edpb.europa.eu/system/files/2024-10/edpb_guidelines_202401_legitimateinterest_en.pdf
- Lignes directrices 01/2025 sur la pseudonymisation, **version soumise à consultation** (adoptée le 16 janvier 2025 ;
  aucune version finale trouvée le 10 octobre 2026) —
  https://www.edpb.europa.eu/system/files/2025-01/edpb_guidelines_202501_pseudonymisation_en.pdf

Sources consultées le 10 octobre 2026. Les fiches de la CNIL et les lignes directrices du CEPD évoluent : les vérifier
à nouveau avant la consultation des juristes.
