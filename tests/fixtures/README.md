# Fausses pages de test

Pages HTML utilisées par les tests Python. Elles reproduisent la **structure** des pages de classement
amazon.fr (balises, classes, attributs observés le 5 octobre 2026, voir `docs/exploration-amazon.md`),
mais **toutes leurs valeurs sont inventées** : catégories, ASIN, titres, auteurs, identifiants, prix.

Règle absolue : aucune vraie page Amazon, ni aucun extrait contenant de vraies données,
n'entre dans ce dossier. Les vraies pages restent dans `data/samples/`, hors du dépôt.

| Fichier | Contenu | Résultat attendu |
|---|---|---|
| `bestsellers_exemple.html` | Catégorie `10000000001`, 5 livres classés, 3 cartes détaillées (complète ; sans évaluation ; milliers avec espace insécable) | valide |
| `bestsellers_titre_captcha.html` | Comme l'exemple, mais un titre contient le mot « Captcha » | valide |
| `bestsellers_sans_rang.html` | Comme l'exemple, sans aucun `render.zg.rank` (liste de type « nouveautés ») | `invalid` |
| `bestsellers_autre_categorie.html` | Comme l'exemple, canonical vers la catégorie `10000000002` | `invalid` |
| `bestsellers_captcha.html` | Page CAPTCHA, structure **supposée** (aucune vraie page encore observée) | `blocked` |

Les trois variantes dérivées de l'exemple n'en diffèrent que par le point testé.
