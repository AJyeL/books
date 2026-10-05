# Fausses pages de test

Pages HTML utilisées par les tests Python. Elles reproduisent la **structure** des pages de classement
amazon.fr (balises, classes, attributs observés le 5 octobre 2026, voir `docs/exploration-amazon.md`),
mais **toutes leurs valeurs sont inventées** : catégories, ASIN, titres, auteurs, identifiants, prix.

Règle absolue : aucune vraie page Amazon, ni aucun extrait contenant de vraies données,
n'entre dans ce dossier. Les vraies pages restent dans `data/samples/`, hors du dépôt.

## Pages

`bestsellers_exemple.html` est écrite à la main : Top payant, page 1, catégorie `10000000001`, 5 livres classés,
3 cartes détaillées (complète ; sans évaluation ; milliers avec espace insécable). Comme les vraies pages,
elle contient deux `span aria-current="page"` : l'onglet actif et, hors de la rangée d'onglets,
la catégorie courante de l'arborescence (structure simplifiée).

`bestsellers_captcha.html` est écrite à la main : page CAPTCHA, structure **supposée** (aucune vraie page encore observée).

Toutes les autres sont des **variantes générées** à partir de l'exemple par `generer_variantes.py`, et n'en diffèrent
que par le point testé. Après toute modification de l'exemple, les régénérer depuis la racine du dépôt :
`python tests/fixtures/generer_variantes.py`.

| Fichier | Point testé | Demande | Résultat attendu |
|---|---|---|---|
| `bestsellers_exemple.html` | référence | paid p1 | ok |
| | | free p1 | `invalid` (onglet payant) |
| | | paid p2 | `invalid` (page active 1, rangs 1 à 5) |
| `bestsellers_titre_captcha.html` | « Captcha » dans un titre | paid p1 | ok |
| `bestsellers_gratuit.html` | onglet actif « Top 100 gratuits » (prix non nuls laissés exprès) | free p1 | ok |
| | | paid p1 | `invalid` |
| `bestsellers_page2.html` | page 2 : rangs 51 à 55, pagination « Page 2 » active | paid p2 | ok |
| | | paid p1 | `invalid` |
| `bestsellers_sans_onglet.html` | aucun onglet actif dans la rangée d'onglets | paid p1 | `invalid` |
| `bestsellers_sans_pagination.html` | aucun bloc de pagination | paid p1 | ok |
| | | paid p2 | `invalid` |
| `bestsellers_liste_courte.html` | 45 rangs, sans pagination | paid p1 | ok (liste courte) |
| `bestsellers_rang_decale.html` | premier rang 2 | paid p1 | `invalid` |
| `bestsellers_rang_hors_plage.html` | un rang à 51 en page 1 | paid p1 | `invalid` |
| `bestsellers_rang_trou.html` | rangs 1, 2, 3, 4, 7 | paid p1 | ok, trou signalé |
| `bestsellers_sans_rang.html` | aucun `render.zg.rank` | paid p1 | `invalid` |
| `bestsellers_autre_categorie.html` | canonical vers `10000000002` | paid p1 | `invalid` |
| `bestsellers_captcha.html` | page CAPTCHA | paid p1 | `blocked` |
