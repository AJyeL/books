# 009 — Copie externe de la base

Date : 8 octobre 2026 · Étape 1 : copie vers le PC

## Contexte

`scripts/backup.sh` sauvegarde chaque nuit la base (`pg_dump`, 14 copies) et les fichiers bruts dans `~/books-backup`,
**sur le même disque qu'atlas** : une panne du disque, un vol ou une erreur de manipulation emporterait à la fois
les données et leurs sauvegardes. La décision 008 (note de l'étape 4) a prévu une copie externe de la base :
d'abord vers le PC, puis vers un NAS. La présente décision traite la première étape.

Les captures ne sont pas concernées : leurs originaux restent sur le PC, dans `envoyees\` (décision 008).

## Décision

### 1. Une sauvegarde neuve, exportée par une seule connexion

- Sur le PC, `scripts/rapatrier-sauvegarde.ps1` (lanceur `rapatrier-sauvegarde.cmd`, pour un double-clic) ouvre
  **une seule connexion SSH** vers l'alias `atlas`, authentifiée par mot de passe saisi à l'invite, comme l'envoi
  des captures. Il y lance `scripts/exporter-sauvegarde.sh`, versionné dans le dépôt.
- Sur atlas, `exporter-sauvegarde.sh` fait un **`pg_dump` neuf**, par la même commande que `backup.sh`
  (`docker compose exec -T postgres … pg_dump -Fc`), plutôt que de reprendre la dernière sauvegarde nocturne :
  la copie est datée du moment du rapatriement, elle ne dépend pas du bon fonctionnement de la tâche nocturne,
  et `pg_dump` en donne une image cohérente même pendant une ingestion. `backup.sh` n'est pas modifié.
- Le dump est écrit dans un dossier temporaire (`mktemp -d`), supprimé à la fin dans tous les cas, y compris
  après une interruption. Il doit être non vide et commencer par la signature du format `-Fc` (`PGDMP`).
- Un **manifeste** `MANIFEST.sha256` (format de `sha256sum`) donne l'empreinte SHA-256 du dump. Le dump et son
  manifeste partent dans une **archive tar**, écrite sur la sortie standard.
- **La sortie standard ne porte que l'archive** : tout autre message, y compris celui d'un outil, part sur la sortie
  d'erreur, que ssh affiche à l'écran du PC. Le script s'arrête avec un code non nul au moindre échec.

### 2. Réception sur le PC : rien n'est gardé sans vérification

- L'archive est enregistrée par une **redirection de `cmd.exe`**, qui copie les octets tels quels, jamais par un tuyau
  PowerShell, qui traite les données comme du texte et corromprait un fichier binaire. Outils de Windows appelés
  par leur chemin complet (`System32\OpenSSH\ssh.exe`, `System32\tar.exe`), comme pour l'envoi des captures.
- Contrôles, dans un dossier de travail temporaire, dans cet ordre :
  1. code de sortie de ssh nul (connexion, export et transfert réussis) ;
  2. archive composée **exactement** de deux fichiers : `MANIFEST.sha256` et un dump nommé
     `books_AAAA-MM-JJTHH-MM-SSZ.dump` (nommage de `backup.sh`) ; aucun chemin, aucun dossier, aucun lien ;
  3. manifeste d'une seule ligne, qui désigne ce dump ;
  4. dump non vide ;
  5. empreinte SHA-256 du dump reçu (`Get-FileHash`) égale à celle du manifeste.
- **Seulement alors**, le dump rejoint le dossier final, d'abord sous un nom provisoire (`….dump.partiel`), dont
  l'empreinte est vérifiée une seconde fois (le déplacement peut être une copie d'un disque à l'autre), puis renommé.
  Le manifeste l'accompagne, sous le nom `….dump.sha256` : la copie reste vérifiable plus tard
  (`sha256sum -c` dans ce dossier, ou `Get-FileHash`).
- **En cas d'échec, rien n'est ajouté au dossier final** ; un message dit à quelle étape et pourquoi.
  Une copie existante n'est jamais écrasée.
- **Codes de sortie** : 0 copie reçue et vérifiée ; 1 export, transfert ou vérification en échec (rien ajouté) ;
  2 réglage, dossier ou outil invalide (aucune connexion ouverte).
- **Bilan** : nom, taille et empreinte de la nouvelle copie, nombre de copies présentes et leur taille totale.

### 3. Réglage local

- Fichier **séparé** de celui de l'envoi : `scripts/rapatrier-sauvegarde.local.psd1` (non versionné, couvert par
  `scripts/*.local.psd1` dans `.gitignore`), modèle `rapatrier-sauvegarde.exemple.psd1`.
- Clés : `DossierSauvegardes` (obligatoire, dossier existant), `ConfigSsh` (facultative). Toute clé inconnue est refusée.
- `envoyer-captures.ps1` et son réglage ne sont pas modifiés : ce script refuse les clés inconnues et fonctionne
  en production ; lui ajouter une clé serait un risque sans bénéfice.

### 4. Conservation

- **Aucune suppression automatique** sur le PC : toutes les copies sont conservées. Une rotation ferait courir
  le risque de supprimer la dernière bonne copie à cause d'une erreur ou d'une base abîmée sans qu'on le sache.
- **Seuil de révision : 24 copies, ou 5 Go au total**, le premier atteint. À une copie par mois, 24 copies couvrent
  deux ans. Le bilan le signale quand le seuil est atteint ; la règle de conservation est alors réexaminée,
  et toute suppression reste manuelle.

### 5. Fréquence

- Une copie **par mois** au moins, lancée à la main (double-clic), et après toute opération importante sur la base
  (migration, reprise de données). Pas de tâche programmée : la connexion demande un mot de passe saisi à l'invite.

## Conséquences

- Une copie de la base existe hors d'atlas, vérifiée octet par octet à son arrivée.
- **Limites** :
  - le manifeste prouve que le fichier reçu est identique à celui produit sur atlas, **pas que la base est
    restaurable** : un test de restauration d'une copie (dans un PostgreSQL jetable) reste à mettre en place ;
  - le dump ne contient ni les rôles ni leurs droits (voir README, « Restauration d'une sauvegarde ») ;
  - les fichiers bruts (`~/books-data/raw`) ne sont pas concernés par cette étape : leur copie externe reste à décider ;
  - le dump n'est pas chiffré : le dossier choisi sur le PC ne doit pas être synchronisé vers un service en ligne
    public ou partagé ;
  - le dossier temporaire est dans `/tmp` sur atlas : sa taille disponible limite celle de la base exportable
    (largement suffisante aujourd'hui, à revoir si la base grossit).
- **Étape 2, à décider** : copie du PC vers un NAS, test de restauration, copie externe des fichiers bruts.

> Note du 8 octobre 2026 (code de l'étape 1) :
> - Fichiers : `scripts/exporter-sauvegarde.sh` (atlas), `scripts/rapatrier-sauvegarde.ps1` et son lanceur `.cmd` (PC),
>   réglage `rapatrier-sauvegarde.exemple.psd1`.
> - Sur atlas, la sortie standard est mise de côté dès le début du script (descripteur 3) et tout le reste est
>   redirigé vers la sortie d'erreur : seule l'archive peut atteindre le PC. `pg_dump` est lancé l'entrée standard
>   fermée (`< /dev/null`) ; côté PC, `ssh -n` fait de même.
> - Côté PC, le contenu de l'archive est listé (`tar -t`) **avant** toute extraction : un membre hors du dossier
>   (`../…`), un dossier ou un fichier en trop est refusé sans rien écrire.
> - Vérifié le 8 octobre 2026 :
>   - script d'export dans un conteneur Debian, avec un faux PostgreSQL : réussite (archive de deux fichiers seulement,
>     dump identique octet par octet sur les 256 valeurs d'octets, aucun message dans la sortie standard, dossier
>     temporaire supprimé), `pg_dump` en échec, dump vide, dump sans signature, dossier du projet absent ;
>     contre-épreuve : sans la mise de côté de la sortie standard ni le nettoyage, 15 vérifications échouent ;
>   - script de rapatriement contre un faux atlas en conteneur, avec les vrais outils de Windows et le vrai script
>     d'export : réussite, seconde copie (la première conservée intacte), `pg_dump` en échec, empreinte falsifiée,
>     dump vide, fichier en trop, manifeste absent ou désignant un autre nom, membre `../`, sortie non tar,
>     archive correcte suivie d'un code non nul, collision de noms, mauvais mot de passe, réglage absent ou invalide,
>     seuil de révision, double-clic sur le `.cmd` sans paramètre. Contre-épreuve : sans les deux comparaisons
>     d'empreinte, la copie falsifiée est acceptée et le test échoue ; sans la première seule, la seconde
>     (après déplacement) la refuse encore ;
>   - tests de l'envoi des captures et de la réception relancés, `faux-docker` ayant été étendu : conformes ;
>   - script d'export lancé tel quel contre le PostgreSQL de développement (vrai `pg_dump`, sans ssh) : archive
>     de deux fichiers, empreinte conforme, signature `PGDMP`, table des matières lue par `pg_restore --list`.
> - Reste à vérifier lors du premier rapatriement réel : la saisie du mot de passe au clavier, la commande `ssh`
>   sans `-F` (configuration SSH de l'utilisateur) et le `pg_dump` d'atlas. Un échec y serait sans danger :
>   rien n'est ajouté au dossier des sauvegardes.
