# Fausses pages de test

Pages HTML utilisées par les tests Python. Elles reproduisent la **structure** des pages de classement
amazon.fr (balises, classes, attributs observés le 5 octobre 2026, voir `docs/exploration-amazon.md`), et depuis
le 10 octobre 2026 celle des fiches produit (décision 015, section « Fiches produit » ci-dessous),
mais **toutes leurs valeurs sont inventées** : catégories, ASIN, titres, auteurs, éditeurs, identifiants, prix.

Règle absolue : aucune vraie page Amazon, ni aucun extrait contenant de vraies données,
n'entre dans ce dossier. Les vraies pages restent dans `data/samples/` et `data/fiches/`, hors du dépôt
(décision 015, section 8 : une page dérivée d'une vraie capture n'est jamais commitée sans nettoyage complet).

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
| `bestsellers_page1_complete.html` | 50 rangs, pagination annonçant la page 2 | paid p1 | ok ; page 2 demandée |
| `bestsellers_page1_complete_sans_pagination.html` | 50 rangs sans pagination (signaux divergents) | paid p1 | ok ; page 2 non demandée, divergence signalée |
| `bestsellers_rang_decale.html` | premier rang 2 | paid p1 | `invalid` |
| `bestsellers_rang_hors_plage.html` | un rang à 51 en page 1 | paid p1 | `invalid` |
| `bestsellers_rang_trou.html` | rangs 1, 2, 3, 4, 7 | paid p1 | ok, trou signalé |
| `bestsellers_rang_double.html` | rangs 1, 2, 3, 4, 4 | paid p1 | `invalid` (décision 011) |
| `bestsellers_asin_double.html` | cinquième ASIN égal au quatrième | paid p1 | `invalid` (décision 011) |
| `bestsellers_sans_rang.html` | aucun `render.zg.rank` | paid p1 | `invalid` |
| `bestsellers_autre_categorie.html` | canonical vers `10000000002` | paid p1 | `invalid` |
| `bestsellers_captcha.html` | page CAPTCHA | paid p1 | `blocked` |

## Captures de l'extension (`captures/`)

Paires `.html` + `.json` conformes à la décision 007 (format des captures), générées par `generer_captures.py`
à partir des fausses pages ci-dessus : HTML commençant par `<!DOCTYPE html>`, sans séparateur ; JSON au schéma
version 1, avec empreinte et taille exactes. Après toute modification des fausses pages, les régénérer :
`python tests/fixtures/generer_captures.py`.

| Capture (catégorie, liste, page, horodatage) | Fausse page d'origine | Résultat attendu |
|---|---|---|
| `10000000001` paid p1 `2026-10-06T200000Z` | `bestsellers_page1_complete.html` | intègre, `ok` (50 rangs) |
| `10000000001` paid p2 `2026-10-06T200010Z` | `bestsellers_page2.html` | intègre, `ok` |
| `10000000001` free p1 `2026-10-06T200020Z` | `bestsellers_gratuit.html` | intègre, `ok` |
| `10000000001` paid p1 `2026-10-06T200030Z` | `bestsellers_captcha.html` | intègre, `blocked` |
| `10000000009` paid p1 `2026-10-06T200040Z` | `bestsellers_exemple.html` | autre catégorie : acceptée depuis la décision 014 (autrefois « hors périmètre ») |
| `B0FAUX0001` `2026-10-06T200050Z` (fiche) | `fiche_exemple.html` | intègre, `ok` (ebook Kindle) |
| `B0FAUX0001` `2026-10-06T200100Z` (fiche) | `fiche_audio.html` | intègre, `invalid` (format non accepté) |
| `B0FAUX0001` `2026-10-06T200110Z` (fiche) | `bestsellers_captcha.html` | intègre, `blocked` |

Les captures non intègres (JSON altéré, empreinte fausse, orphelins, noms hors format) sont fabriquées dans les tests,
sur une copie, à partir de ces paires.

## Pages de l'extracteur (`extraction_*.html`, décision 011)

Générées par `generer_pages_extraction.py` à partir de la tête et de la fin de `bestsellers_exemple.html`
(`python tests/fixtures/generer_pages_extraction.py`). Contrairement à l'exemple, leurs cartes reprennent les formes
**réelles** de l'inventaire du 8 octobre 2026 : espace insécable écrite `&nbsp;`, note toujours avec une décimale.
Un auteur inventé et reconnaissable, `Quentin Sentinelle-Rgpd` (identifiant `B0SENTINL1`), signe plusieurs cartes :
le test RGPD vérifie qu'il n'apparaît dans aucun résultat de l'extracteur.

| Fichier | Contenu | Validation |
|---|---|---|
| `extraction_page1_complete.html` | Top payant p1, 50 rangs, 50 cartes ; rangs 1 à 7 : une forme acceptée chacun (carte complète, sans évaluation, titre à entités et espaces, milliers et prix > 999 €, insécables en caractères, une évaluation, sans couverture) | paid p1 : ok |
| `extraction_page1_30_cartes.html` | Top payant p1, 50 rangs, 30 cartes (capture sans défilement) | paid p1 : ok |
| `extraction_gratuit.html` | Top gratuit p1, 50 rangs, 50 cartes à `0,00 €` | free p1 : ok |

Depuis le 9 octobre 2026, `bestsellers_exemple.html` (et donc ses variantes et les captures de test qui en dérivent)
écrit aussi les formes observées : `4,99&nbsp;€`, `4,0 sur 5&nbsp;étoiles`, `1&nbsp;234&nbsp;évaluations`.
Toute fausse page conforme à la validation passe l'extracteur (testé dans `test_parsing.py`).

## Fiches produit (`fiche_*.html`, décision 015)

`fiche_exemple.html` est écrite à la main : fiche ebook Kindle, ASIN `B0FAUX0001`, structure relevée le 10 octobre 2026
(`docs/exploration-amazon.md`, « Repères de validation d'une fiche ») : canonical `/{libellé}/dp/{ASIN}`, un seul
`#productTitle`, ligne d'auteur `div#bylineInfo` avec « Format&nbsp;: Format Kindle », liste des détails dans deux
`div#detailBullets_feature_div` imbriquées, libellés encadrés de `&rlm;` et `&lrm;`. Elle contient exprès un **piège** :
une carte de recommandation, hors de la ligne d'auteur, avec « Format&nbsp;: Broché ».

Quatre **sentinelles RGPD**, inventées et reconnaissables, vérifiées absentes de tout motif, bilan et journal :
l'auteur `Camille Sentinelle-Rgpd` (identifiant `B0SENTAUT1`), la commentatrice `Renée Sentinelle-Commentatrice`,
la mention de livraison `00000 Exempleville-Sentinelle` et l'éditeur `Maison Sentinelle-Editrice`.

Toutes les autres sont des **variantes générées** à partir de l'exemple par `generer_fiches.py`, et n'en diffèrent que par
le point testé. Après toute modification de l'exemple, les régénérer depuis la racine du dépôt :
`python tests/fixtures/generer_fiches.py`. Demande : la fiche `B0FAUX0001`.

| Fichier | Point testé | Résultat attendu |
|---|---|---|
| `fiche_exemple.html` | référence (ebook Kindle, piège de la recommandation) | ok |
| `fiche_broche.html`, `fiche_relie.html` | formats papier observés | ok |
| `fiche_audio.html` | « Livre audio » (libellé inventé) | `invalid` |
| `fiche_poche.html` | « Poche » : jamais observé, refusé jusqu'à observation | `invalid` |
| `fiche_sans_canonical.html` | aucun canonical | `invalid` |
| `fiche_deux_canonicals.html` | deux canonicals différents | `invalid` |
| `fiche_canonical_autre_asin.html` | canonical d'un autre ASIN | `invalid` |
| `fiche_canonical_hors_fiches.html` | canonical d'une page de classement | `invalid` |
| `fiche_sans_titre.html`, `fiche_titre_vide.html`, `fiche_deux_titres.html` | titre absent, vide, double | `invalid` |
| `fiche_titre_captcha.html` | « Captcha » dans le titre | ok |
| `fiche_sans_details.html` | aucune liste des détails | `invalid` |
| `fiche_sans_asin_details.html` | aucune ligne ASIN dans les détails | `invalid` |
| `fiche_asin_details_different.html` | ASIN des détails différent | `invalid` |
| `fiche_deux_lignes_asin.html` | deux lignes ASIN | `invalid` |
| `fiche_asin_sans_marques.html` | libellés sans `&rlm;` ni `&lrm;` | ok |
| `fiche_insecable_caractere.html` | espace insécable en caractère U+00A0 (forme des enregistrements Ctrl+S) | ok |
| `fiche_sans_ligne_auteur.html` | aucune ligne d'auteur | `invalid` |
| `fiche_format_hors_ligne_auteur.html` | format seulement dans la recommandation (piège) | `invalid` |
| `fiche_deux_formats.html` | deux formats dans la ligne d'auteur | `invalid` |

La page de vérification `bestsellers_captcha.html`, demandée comme fiche, est classée `blocked`.
