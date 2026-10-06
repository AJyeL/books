# 007 — Format des captures

Date : 6 octobre 2026

## Contexte

L'extension de capture (décision 005, code dans un dépôt privé selon la décision 006) produit des fichiers
que le collecteur de ce dépôt lit et dépose dans RAW. Ce format est le contrat entre les deux : il doit permettre
au collecteur de lire chaque capture sans ambiguïté, et de refuser toute capture incomplète ou incohérente.

## Décision

### 1. Une capture = deux fichiers jumeaux

| Fichier | Contenu |
|---|---|
| `{nom}.html` | La page capturée, telle qu'affichée |
| `{nom}.json` | Les métadonnées de la capture |

Les deux fichiers portent le même nom, à l'extension près. Une capture n'existe que si les deux fichiers sont présents.

### 2. Nom

```
amazon_fr_bestsellers_{catégorie}_{paid|free}_p{n}_{AAAA-MM-JJTHHMMSSZ}
```

- `{catégorie}` : numéro de catégorie Amazon (browse node), chiffres uniquement.
- `{paid|free}` : `paid` pour le Top 100 payant, `free` pour le Top 100 gratuit.
- `{n}` : `1` ou `2`.
- `{AAAA-MM-JJTHHMMSSZ}` : horodatage UTC de la capture, à la seconde, sans deux-points (caractère interdit
  dans les noms de fichiers sous Windows). Deux captures du même jour ne se confondent pas, et l'ordre alphabétique
  des noms est l'ordre chronologique.
- Expression régulière complète du nom du fichier HTML :
  `amazon_fr_bestsellers_[0-9]+_(paid|free)_p[12]_[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z\.html`
- Exemple (catégorie inventée) : `amazon_fr_bestsellers_10000000001_free_p2_2026-10-06T140327Z.html`
  et `amazon_fr_bestsellers_10000000001_free_p2_2026-10-06T140327Z.json`.

**Catégorie, liste et page sont déduites de l'adresse affichée uniquement**, jamais du contenu de la page :
catégorie = segment qui suit `/gp/bestsellers/digital-text/` ; liste = `free` si l'adresse contient le paramètre
`tf=1`, sinon `paid` ; page = valeur du paramètre `pg` (2), sinon 1. Le nom déclare ainsi ce que l'adresse annonce,
et la validation du collecteur (quatre indices, décision 004) le confronte au contenu, de façon indépendante.
Une adresse dont on ne peut pas déduire ces trois éléments n'est pas capturée (elle sort de la liste blanche
de la décision 005).

### 3. Fichier HTML

- Contenu : la sérialisation du DOM de la page affichée, précédée de sa déclaration de type de document
  (`<!DOCTYPE html>` reconstruit à partir du document), puis `document.documentElement.outerHTML`.
- Encodage : **UTF-8, sans BOM**, quel que soit l'encodage annoncé par la page.
- Ni compression, ni retouche, ni conversion des fins de ligne : le fichier contient exactement la sérialisation
  obtenue. **Le HTML capturé n'est jamais modifié**, ni par l'extension après écriture, ni par le collecteur
  (qui le compresse seulement en le déposant dans RAW, sans altérer son contenu, décision 004).
- L'extension ne juge pas le contenu : une page de vérification (CAPTCHA) affichée à une adresse de la liste blanche
  peut être capturée ; c'est la validation du collecteur qui la classe `blocked` (décision 005).

### 4. Fichier JSON

- Encodage : UTF-8, sans BOM. Un seul objet JSON. Noms de champs en minuscules.
- Champs, tous obligatoires, version 1 du schéma :

| Champ | Type | Contenu |
|---|---|---|
| `schema_version` | entier | `1` |
| `displayed_url` | texte | Adresse affichée au moment de la capture (`location.href`), complète, telle quelle |
| `captured_at` | texte | Horodatage UTC de la capture, ISO 8601 à la seconde : `2026-10-06T14:03:27Z` |
| `capture_method` | texte | `extension-dom` |
| `extension_version` | texte | Version de l'extension, par exemple `0.1.0` |
| `user_agent` | texte | Chaîne d'identification du navigateur (`navigator.userAgent`) : la version de Chrome peut influer sur le DOM |
| `html_sha256` | texte | Empreinte SHA-256 du fichier HTML, en 64 caractères hexadécimaux minuscules |
| `html_bytes` | entier | Taille du fichier HTML, en octets |

Exemple (valeurs inventées) :

```json
{
  "schema_version": 1,
  "displayed_url": "https://www.amazon.fr/gp/bestsellers/digital-text/10000000001/ref=zg_bs_pg_2_digital-text?ie=UTF8&pg=2&tf=1",
  "captured_at": "2026-10-06T14:03:27Z",
  "capture_method": "extension-dom",
  "extension_version": "0.1.0",
  "user_agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
  "html_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
  "html_bytes": 512345
}
```

- Un champ inconnu ou manquant, ou une autre valeur de `schema_version`, rend la capture illisible :
  toute évolution du format passe par une nouvelle version du schéma, et par un amendement de cette décision.

### 5. Écriture par l'extension

- Le fichier HTML est écrit en premier, le fichier JSON en dernier : **la présence du JSON signale une capture
  complète**.
- Aucun fichier n'est jamais écrasé. Si un fichier du même nom existe déjà (deux captures dans la même seconde),
  la nouvelle capture est abandonnée et signalée à l'utilisateur.
- Les fichiers ne sont jamais modifiés après écriture ; une capture erronée est remplacée par une nouvelle capture,
  jamais corrigée.

### 6. Lecture par le collecteur

Une capture n'est lue que si tous ces contrôles réussissent ; sinon, elle n'est pas déposée comme page
et l'anomalie est signalée :

- les deux fichiers jumeaux existent (un HTML sans JSON est considéré comme une capture en cours ou incomplète) ;
- le JSON respecte le schéma de la version annoncée ;
- `captured_at` correspond exactement à l'horodatage du nom ;
- catégorie, liste et page déduites de `displayed_url` (règle de la section 2) correspondent au nom ;
- `html_sha256` et `html_bytes` correspondent au fichier HTML.

Tout fichier présent dans le dossier de dépôt qui ne respecte pas le format (nom hors expression régulière,
jumeau orphelin) est signalé, jamais ignoré en silence. Exemple : Chrome peut renommer un fichier en
« nom (1).html » en cas de conflit.

Ces contrôles portent sur l'intégrité de la capture. La conformité de la page elle-même reste vérifiée ensuite
par la validation de la décision 004, qui confronte le contenu au nom.

Deux points ne sont pas tranchés ici et sont rattachés aux questions ouvertes de la décision 005 :
l'emplacement du dossier de dépôt des captures sur le PC (question du transfert vers atlas), et le sort d'une capture
refusée par ces contrôles (question du comportement de l'ingestion).

## Conséquences

- La source locale devra reconnaître ce format (étape ultérieure), avec les contrôles de la section 6.
- Les échantillons actuels de `data/samples/` (nom à la date seule, sans JSON, enregistrés par Ctrl+S) restent
  des pages de développement. Ils ne sont pas des captures au sens de cette décision et ne seront jamais acceptés
  en production.
- La migration prévue par la décision 005 (méthode de capture dans RAW) devra conserver aussi les métadonnées
  du JSON : `captured_at` alimentera `fetched_at`, `displayed_url` alimentera `requested_url`, et le JSON lui-même
  pourra être déposé dans RAW à côté du HTML.
- L'extension et le collecteur évoluent dans deux dépôts différents : ce document est leur seule référence commune.
  Les tests du collecteur reposeront sur des captures inventées conformes à ce format (`tests/fixtures/`).
