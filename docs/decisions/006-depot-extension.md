# 006 — Dépôt du code de l'extension de capture

Date : 6 octobre 2026

## Contexte

La décision 005 prévoit une extension de navigateur qui enregistre les pages de classement affichées
par le porteur du projet. Ce dépôt est public et présente l'infrastructure de données de B.O.O.K.S.
L'extension est un outil personnel, installé dans le navigateur de veille du porteur du projet.

## Décision

- Le code de l'extension de capture est conservé dans un **dépôt privé séparé**. Il n'entre pas dans ce dépôt.
- Son comportement est **entièrement décrit par la décision 005**, qui reste publique : consultation manuelle,
  aucune page ouverte ni demandée par l'extension, aucune requête vers Amazon, navigateur dédié, mode enregistrement
  manuel signalé par un badge, liste blanche limitée aux pages de classement, capture du DOM sans nouvelle requête,
  traitement des pages de vérification.
- Le code peut être **communiqué sur demande**, par exemple à un juriste.
- Le dossier `extension/` est ajouté au `.gitignore` de ce dépôt, pour qu'un code placé par erreur dans ce dossier
  ne soit jamais publié.

## Conséquences

- Toute évolution du comportement de l'extension est d'abord consignée dans une décision publique
  (amendement de la décision 005 ou nouvelle décision), avant sa mise en service. La documentation publique reste
  ainsi conforme au code.
- Le format des fichiers produits par l'extension (nom, contenu, méthode de capture, horodatage) sera décrit
  dans ce dépôt, puisque le collecteur les lit et que ses tests en dépendent.
- Les tests du collecteur continuent d'utiliser des fausses pages aux valeurs inventées (`tests/fixtures/`),
  sans dépendre du dépôt privé.
