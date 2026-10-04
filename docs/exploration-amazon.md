# Exploration des pages de classement Kindle (amazon.fr)

Observations manuelles du 3 octobre 2026, en navigation privée, sans connexion.

## Boutique
- Les ebooks Kindle sont dans la boutique `digital-text`.
- La boutique `books` correspond aux livres papier : arborescence et classements distincts.

## Adresses
- Format retenu : `https://www.amazon.fr/gp/bestsellers/digital-text/{categorie}?pg={1|2}`
- Top gratuit : ajouter `&tf=1`.
- Le paramètre `ref=` est un traceur de navigation, ignoré.
- Le numéro de catégorie (browse node) est l'identifiant externe stable ; le nom peut changer.

## Structure d'une page
- 50 livres par page au maximum, 2 pages au maximum.
- Le HTML initial contient les cartes détaillées d'environ 33 livres seulement ;
  les suivants sont chargés par le navigateur au défilement.
- L'attribut `data-client-recs-list` contient les ASIN de toute la page,
  chacun accompagné de son rang (`zg.rank`).

## Règles de collecte et de parsing
- Chaque catégorie a deux classements : payant et gratuit.
- Une liste peut compter moins de 100 livres (ex. : 48 gratuits en Fantasy épique).
- La page 2 n'est demandée que si la page 1 contient 50 rangs.
- `data-client-recs-list` peut contenir une autre liste (ex. : nouveautés) :
  une liste n'est acceptée comme classement que si elle contient des `zg.rank`.
- Trois situations distinguées : liste normale, liste courte (information), page anormale (alerte, arrêt).

## Catégories identifiées
| Catégorie | Chemin | Identifiant |
|---|---|---|
| Fantasy épique | Ebooks Kindle › SF, fantasy et horreur › Fantasy › Épique | 12363082031 |
