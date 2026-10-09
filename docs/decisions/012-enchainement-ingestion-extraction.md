# 012 — Enchaînement de l'extraction après l'ingestion

Date : 9 octobre 2026

## Contexte

Après chaque séance, le porteur du projet envoie les captures depuis le PC (`envoyer-captures.cmd`). Dans une seule
connexion SSH, atlas reçoit le lot, le vérifie, le place dans `inbox/` et lance l'ingestion (décision 008).
L'extraction vers STAGING (décision 011) est une commande séparée, lancée à la main sur atlas. Depuis son déploiement
le 9 octobre 2026, elle fonctionne en production : il reste à l'enchaîner, pour qu'un envoi suffise à rendre les
nouvelles captures disponibles dans STAGING.

## Décision

### 1. L'extraction suit toujours l'ingestion

- Dans la même connexion SSH, `scripts/recevoir-captures.sh` lance l'extraction (service `transformer`)
  **chaque fois que le lot a été reçu et que l'ingestion a été lancée, quel que soit le résultat de l'ingestion**.
- Si le lot n'a pas été reçu (transfert échoué : archive refusée, empreinte fausse, lot déjà présent…), rien ne change :
  ni ingestion, ni extraction.
- Aucun mot de passe supplémentaire : l'extracteur prend le sien dans le `.env` d'atlas, comme le collecteur.

### 2. Pourquoi sans condition sur le résultat de l'ingestion

Une condition (« n'extraire que si l'ingestion a déposé quelque chose ») demanderait au collecteur un nouveau repère,
et au script de réception d'analyser sa sortie : du code et des cas de plus, sans rien protéger. L'extracteur n'a pas
besoin de cette protection :

- il est **idempotent** : relancé sans nouvelle page, il répond « déjà à jour » ;
- il est **verrouillé** : jamais deux extractions à la fois (verrou consultatif) ;
- il ne lit **que ce qui est enregistré dans `raw.raw_page`** : une ingestion en échec n'y laisse que des pages
  complètes (fichiers écrits et ligne validée, décision 008, section 3), ou rien ;
- il **signale lui-même ses erreurs** : configuration invalide (code 2), base injoignable, page en échec (code 1).

Une extraction lancée après une ingestion en échec traite donc ce qui a été déposé avant l'erreur, reprend les pages
en échec (décision 011), ou ne fait rien ; dans tous les cas, son bilan dit ce qu'il en est.

### 3. Repères et code final

- Repères lus par le PC : `BOOKS:INGESTION:CODE n` (existant) et `BOOKS:EXTRACTION:CODE n` (nouveau).
  Le collecteur n'est pas modifié. Le bilan de l'extraction s'affiche sur le PC à la suite de celui de l'ingestion.
- `recevoir-captures.sh` sort avec le plus élevé des deux codes.
- **Code final du script d'envoi, le plus grave l'emporte** :

| Code | Situation |
|---|---|
| 0 | transfert réussi, ingestion **et** extraction sans anomalie |
| 1 | transfert réussi, mais ingestion ou extraction avec anomalies, non effectuée, en échec, déjà en cours, ou configuration invalide **sur atlas** ; ou repère d'extraction absent |
| 2 | réglage, dossier ou outil invalide **sur le PC**, ou collision dans `envoyees\` : rien n'a été envoyé (inchangé) |
| 3 | transfert échoué : rien n'a été déplacé sur le PC (inchangé) |

- Un repère d'extraction absent (par exemple, atlas pas encore mis à jour) donne le code 1 et un message explicite :
  l'absence d'information n'est jamais lue comme un succès.
- Le rangement des captures dans `envoyees\` dépend du seul transfert, comme avant.

## Conséquences

- Les décisions 008 (déclenchement, codes du script d'envoi) et 011 (exécution « à la main ») sont précisées par
  des notes datées. L'extracteur reste lançable seul, à la main.
- Tant qu'une page reste en échec d'extraction (règle de reprise de la décision 011), **chaque envoi se termine par
  le code 1**, même si les nouvelles captures sont toutes extraites. C'est voulu.
- Le PC et atlas doivent être à jour du même commit : atlas d'abord (`git pull`), puis l'envoi. Dans l'ordre inverse,
  le repère d'extraction manque, et l'envoi se termine par le code 1, sans perte.
- La durée d'un envoi augmente de celle de l'extraction (quelques secondes pour une séance).

> Note du 9 octobre 2026 (code) :
> - `scripts/recevoir-captures.sh` : après l'ingestion et son repère, extraction
>   (`docker compose --profile transformer run --rm -T transformer`, entrée fermée), repère `BOOKS:EXTRACTION:CODE`,
>   code de sortie = le plus élevé des deux. `scripts/envoyer-captures.ps1` : lecture du second repère, une ligne par
>   étape, code final 0 seulement si les deux codes valent 0. Le collecteur n'est pas modifié.
> - Vérifié le 9 octobre 2026 : `test_recevoir_captures.sh` (conteneur Debian) : ingestion puis extraction, repères
>   dans l'ordre, extraction lancée après une ingestion en anomalie (code 1) ou en échec (code 2), extraction en échec
>   remontée dans le code, aucune ingestion ni extraction si le lot n'est pas reçu ; `Test-EnvoyerCaptures.ps1` (faux
>   atlas, vrais outils de Windows) : code 0 si les deux sont sans anomalie, extraction lancée malgré une ingestion
>   non effectuée, extraction en échec → code 1, configuration invalide de l'extracteur sur atlas → code 1, repère
>   d'extraction absent (atlas pas à jour) → code 1, transfert échoué → ni ingestion ni extraction.
>   Contre-épreuves : extraction conditionnée à une ingestion réussie → 2 échecs ; code final tiré de l'ingestion
>   seule → 3 échecs ; repère absent lu comme un succès → 2 échecs.

> Note du 9 octobre 2026 (premier envoi réel, rapporté par le porteur du projet) :
> - Premier envoi avec extraction enchaînée : **réussi**. Ingestion 14 : 7 captures `ok` (information : liste courte,
>   Top gratuit de Fantasy épique, 48 rangs) ; extraction : 7 pages, 348 lignes, 348 avec carte, 37 pages déjà à jour ;
>   codes 0 et 0 ; résultat affiché par étape sur le PC.
> - Correction de la consigne de déploiement : la vérification `grep -c "BOOKS:EXTRACTION:CODE"` sur
>   `recevoir-captures.sh` renvoie **2** et non 1 (le repère figure dans le commentaire d'en-tête et dans l'`echo`) ;
>   l'attendu annoncé était faux, le script était correct.
