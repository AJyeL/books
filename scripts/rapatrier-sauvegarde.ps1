<#
.SYNOPSIS
    Rapatrie sur le PC une sauvegarde neuve de la base d'atlas, vérifiée par son empreinte (décision 009).

.DESCRIPTION
    1. Une seule connexion SSH (alias « atlas », mot de passe saisi à l'invite) : sur atlas,
       scripts/exporter-sauvegarde.sh fait un pg_dump neuf et écrit sur sa sortie standard une archive tar
       (dump + MANIFEST.sha256). L'archive est enregistrée par une redirection de cmd.exe, qui copie les octets
       tels quels (jamais par un tuyau PowerShell, qui corromprait ces données binaires).
    2. Contrôles dans un dossier de travail : code de ssh nul ; archive composée exactement du manifeste et d'un dump
       au nom attendu ; manifeste d'une ligne désignant ce dump ; dump non vide ; empreinte SHA-256 identique.
    3. Seulement alors, le dump rejoint le dossier des sauvegardes (nom provisoire .partiel, empreinte revérifiée,
       puis renommage), accompagné de son manifeste (….dump.sha256). Rien n'est jamais supprimé ni écrasé.

    Codes de sortie :
      0  copie reçue, vérifiée et rangée
      1  export, transfert ou vérification en échec : rien n'a été ajouté au dossier des sauvegardes
      2  réglage local, dossier ou outil invalide : aucune connexion ouverte

.PARAMETER Reglages
    Fichier de réglage local (non versionné). Par défaut : rapatrier-sauvegarde.local.psd1, à côté du script.
    Clés acceptées : DossierSauvegardes (obligatoire), ConfigSsh (facultative).
.PARAMETER HoteSsh
    Alias SSH d'atlas, défini dans la configuration SSH de l'utilisateur. Par défaut : atlas.
.PARAMETER ConfigSsh
    Fichier de configuration SSH particulier (tests) ; à défaut, la clé ConfigSsh du réglage local ;
    à défaut, la configuration SSH de l'utilisateur.
.PARAMETER DepotDistant
    Dossier du dépôt sur atlas, relatif au dossier personnel. Par défaut : books.
.PARAMETER DossierTravail
    Dossier où l'archive est reçue et vérifiée, puis supprimée. Par défaut : le dossier temporaire de Windows (TEMP).
#>
[CmdletBinding()]
param(
    [string]$Reglages = '',
    [string]$HoteSsh = 'atlas',
    [string]$ConfigSsh = '',
    [string]$DepotDistant = 'books',
    [string]$DossierTravail = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Valeurs par défaut calculées ici, et non dans param() : sous PowerShell 5.1, $PSScriptRoot y est vide
# quand le script est lancé par « powershell -File » (cas du lanceur .cmd).
$dossierDuScript = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Reglages) { $Reglages = Join-Path $dossierDuScript 'rapatrier-sauvegarde.local.psd1' }
if (-not $DossierTravail) { $DossierTravail = [IO.Path]::GetTempPath() }
# Les messages d'atlas (affichés par ssh) sont en UTF-8
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

# Nom d'un dump (nommage de scripts/backup.sh)
$NomDump = '^books_[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z\.dump$'
# Seuil de révision de la conservation (décision 009, section 4)
$SeuilCopies = 24
$SeuilOctets = 5GB
# Outils fournis avec Windows, appelés par leur chemin complet (et non ceux d'autres logiciels installés)
$Ssh = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$Tar = Join-Path $env:WINDIR 'System32\tar.exe'
$Utf8SansBom = New-Object System.Text.UTF8Encoding $false

function Write-Section([string]$texte) { Write-Host ''; Write-Host "== $texte" }
function Get-Empreinte([string]$chemin) { (Get-FileHash -LiteralPath $chemin -Algorithm SHA256).Hash.ToLowerInvariant() }

# --- 1. Réglage local et outils ------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Reglages -PathType Leaf)) {
    Write-Host "Réglage local introuvable : $Reglages"
    Write-Host "Copiez rapatrier-sauvegarde.exemple.psd1 en rapatrier-sauvegarde.local.psd1, puis indiquez votre dossier."
    exit 2
}
$reglage = Import-PowerShellDataFile -LiteralPath $Reglages
# Clés acceptées ; une clé inconnue (faute de frappe) arrête le script au lieu d'être ignorée
$clesInconnues = @($reglage.Keys | Where-Object { $_ -cnotin 'DossierSauvegardes', 'ConfigSsh' })
if ($clesInconnues.Count -gt 0) {
    Write-Host "Réglage inconnu dans $Reglages : $($clesInconnues -join ', ') (acceptés : DossierSauvegardes, ConfigSsh)."
    exit 2
}
# ConfigSsh (facultatif) : fichier de configuration SSH particulier ; le paramètre -ConfigSsh l'emporte
if (-not $ConfigSsh -and $reglage.ContainsKey('ConfigSsh')) { $ConfigSsh = $reglage['ConfigSsh'] }
$dossier = $reglage['DossierSauvegardes']
if (-not $dossier -or -not (Test-Path -LiteralPath $dossier -PathType Container)) {
    Write-Host "Dossier des sauvegardes introuvable : '$dossier' (réglage DossierSauvegardes de $Reglages)."
    exit 2
}
foreach ($outil in $Ssh, $Tar) {
    if (-not (Test-Path -LiteralPath $outil -PathType Leaf)) { Write-Host "Outil introuvable : $outil"; exit 2 }
}
if ($ConfigSsh -and -not (Test-Path -LiteralPath $ConfigSsh -PathType Leaf)) {
    Write-Host "Configuration SSH introuvable : $ConfigSsh"; exit 2
}

# --- 2. Réception de l'archive ---------------------------------------------------------------
$horodatage = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture)
$travail = Join-Path $DossierTravail "books-rapatriement-$horodatage"
$archive = Join-Path $travail 'sauvegarde.tar'
$extrait = Join-Path $travail 'extrait'
$lanceur = Join-Path $travail 'rapatriement.cmd'
$partiel = $null
$code = 1

New-Item -ItemType Directory -Path $extrait | Out-Null
try {
    # Redirection de cmd.exe : octets enregistrés tels quels. Seule la sortie normale (l'archive) va dans le fichier ;
    # la sortie d'erreur reste à l'écran (questions de ssh, messages d'atlas). -n : ssh ne lit pas le clavier.
    $optionConfig = if ($ConfigSsh) { "-F `"$ConfigSsh`" " } else { '' }
    $ligne = "`"$Ssh`" -n $optionConfig$HoteSsh bash $DepotDistant/scripts/exporter-sauvegarde.sh > `"$archive`""
    [IO.File]::WriteAllText($lanceur, "@echo off`r`n$ligne`r`nexit /b %ERRORLEVEL%`r`n", [Text.Encoding]::Default)

    Write-Section "Export d'une sauvegarde neuve sur $HoteSsh"
    Write-Host 'Saisissez le mot de passe d''atlas si ssh le demande.'
    & cmd.exe /d /c "`"$lanceur`""
    $codeSsh = $LASTEXITCODE
    if ($codeSsh -ne 0) { throw "export ou transfert échoué (code de ssh : $codeSsh)" }
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf) -or (Get-Item -LiteralPath $archive).Length -eq 0) {
        throw 'aucune archive reçue'
    }

    # --- 3. Contrôles --------------------------------------------------------------------------
    Write-Section 'Vérification'
    # Contenu de l'archive, lu AVANT toute extraction : exactement le manifeste et un dump au nom attendu
    $membres = @(& $Tar -t -f $archive)
    if ($LASTEXITCODE -ne 0) { throw 'archive illisible' }
    $dumps = @($membres | Where-Object { $_ -cmatch $NomDump })
    if ($membres.Count -ne 2 -or $dumps.Count -ne 1 -or ($membres -cnotcontains 'MANIFEST.sha256')) {
        throw "contenu de l'archive inattendu : $($membres -join ', ')"
    }
    $nom = $dumps[0]
    & $Tar -x -f $archive -C $extrait
    if ($LASTEXITCODE -ne 0) { throw "extraction de l'archive échouée" }
    $recu = Join-Path $extrait $nom
    $manifeste = Join-Path $extrait 'MANIFEST.sha256'
    foreach ($f in $recu, $manifeste) {
        # Fichier ordinaire seulement : ni dossier, ni lien vers un autre fichier
        if (-not (Test-Path -LiteralPath $f -PathType Leaf) -or
            ((Get-Item -LiteralPath $f).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "$(Split-Path -Leaf $f) n'est pas un fichier ordinaire"
        }
    }
    $ligneManifeste = [regex]::Match([IO.File]::ReadAllText($manifeste, $Utf8SansBom), '\A([0-9a-f]{64})  (\S+)\n?\z')
    if (-not $ligneManifeste.Success -or $ligneManifeste.Groups[2].Value -cne $nom) {
        throw 'MANIFEST.sha256 mal formé, ou ne désignant pas le dump reçu'
    }
    $attendue = $ligneManifeste.Groups[1].Value
    $taille = (Get-Item -LiteralPath $recu).Length
    if ($taille -eq 0) { throw 'sauvegarde vide' }
    $empreinte = Get-Empreinte $recu
    if ($empreinte -cne $attendue) {
        throw "empreinte SHA-256 différente de celle du manifeste (reçue $empreinte, attendue $attendue)"
    }
    Write-Host "Empreinte conforme au manifeste : $empreinte"

    # --- 4. Rangement : nom provisoire, empreinte revérifiée, puis renommage ----------------------
    $final = Join-Path $dossier $nom
    $finalManifeste = "$final.sha256"
    $partielPrevu = "$final.partiel"
    foreach ($f in $final, $finalManifeste, $partielPrevu) {
        if (Test-Path -LiteralPath $f) { throw "$(Split-Path -Leaf $f) existe déjà dans le dossier des sauvegardes : rien n'est écrasé" }
    }
    $partiel = $partielPrevu
    Move-Item -LiteralPath $recu -Destination $partiel
    if ((Get-Empreinte $partiel) -cne $attendue) { throw 'empreinte différente après le déplacement vers le dossier des sauvegardes' }
    Move-Item -LiteralPath $partiel -Destination $final
    $partiel = $null
    Move-Item -LiteralPath $manifeste -Destination $finalManifeste

    # --- 5. Bilan --------------------------------------------------------------------------------
    $copies = @(Get-ChildItem -LiteralPath $dossier -File -Filter 'books_*.dump' | Where-Object { $_.Name -cmatch $NomDump })
    $total = ($copies | Measure-Object -Property Length -Sum).Sum
    Write-Section 'Résultat'
    Write-Host "Copie reçue et vérifiée : $nom"
    Write-Host ("  Taille    : {0:N0} octets ({1:N1} Mo)" -f $taille, ($taille / 1MB))
    Write-Host "  Empreinte : $empreinte (SHA-256)"
    Write-Host "  Dossier   : $dossier"
    Write-Host ("Copies présentes : {0}, {1:N1} Mo au total. Aucune n'est supprimée." -f $copies.Count, ($total / 1MB))
    if ($copies.Count -ge $SeuilCopies -or $total -ge $SeuilOctets) {
        Write-Host "Seuil de révision atteint ($SeuilCopies copies ou 5 Go) : réexaminer la conservation (décision 009, section 4)."
    }
    $restes = @(Get-ChildItem -LiteralPath $dossier -File -Filter '*.partiel')
    foreach ($r in $restes) { Write-Host "Signalé : $($r.Name), reste d'une exécution interrompue, à examiner puis supprimer à la main." }
    $code = 0
}
catch {
    Write-Section 'Échec'
    Write-Host "Erreur : $($_.Exception.Message)"
    Write-Host 'Rien n''a été ajouté au dossier des sauvegardes.'
    $code = 1
}
finally {
    if ($partiel) { Remove-Item -LiteralPath $partiel -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $travail -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
