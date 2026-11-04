<#
.SYNOPSIS
    Envoie les rapports Amazon Ads téléchargés vers atlas et lance leur ingestion dans RAW (décision 018, lot A).

.DESCRIPTION
    Calqué sur envoyer-captures.ps1 (décision 008). Les rapports sont téléchargés à la main, par le lien de l'e-mail
    d'Amazon (décision 018, section 1) ; ce script n'ouvre ni la boîte mail ni aucun lien.

    1. Inventaire du dossier des rapports (premier niveau seulement) : partent les fichiers .csv au nom fait de
       lettres, chiffres, « _ », « . » et « - », de 20 Mo au plus. Tout autre fichier est signalé et laissé sur
       place (par exemple le « (1) » qu'ajoute Windows à un second téléchargement). Le contenu n'est pas examiné ici :
       atlas juge la nature de chaque fichier, et le dépose dans RAW avec son statut.
    2. Préparation : copie des rapports dans un dossier de travail, liste d'empreintes MANIFEST.sha256 calculée sur
       les originaux, archive tar. Aucun outil ne lit les rapports comme du texte.
    3. Une seule connexion SSH (alias « atlas », mot de passe saisi à l'invite) : l'archive est transmise par une
       redirection de cmd.exe, qui copie les octets tels quels. Sur atlas, scripts/recevoir-ads.sh déballe, vérifie,
       place le lot dans ~/books-data/ads/inbox/ et lance l'ingestion.
    4. Si le transfert a réussi, les rapports sont déplacés dans envoyes\AAAA-MM\ (mois d'envoi, en UTC), quel que
       soit le résultat de l'ingestion : envoyes\ est une archive permanente, jamais vidée.

    Codes de sortie :
      0  transfert réussi, ingestion sans anomalie (ou aucun rapport à envoyer)
      1  transfert réussi, mais ingestion avec anomalies, non effectuée ou en échec (les rapports non ingérés
         attendent dans inbox/ sur atlas)
      2  réglage local, dossier ou outil invalide sur le PC, ou nom déjà présent dans envoyes\ : rien n'a été envoyé
      3  transfert échoué : rien n'a été déplacé sur le PC

.PARAMETER Reglages
    Fichier de réglage local (non versionné). Par défaut : envoyer-ads.local.psd1, à côté du script.
    Clés acceptées : DossierRapports (obligatoire), ConfigSsh (facultative).
.PARAMETER HoteSsh
    Alias SSH d'atlas, défini dans la configuration SSH de l'utilisateur. Par défaut : atlas.
.PARAMETER ConfigSsh
    Fichier de configuration SSH particulier (tests) ; à défaut, la clé ConfigSsh du réglage local ;
    à défaut, la configuration SSH de l'utilisateur.
.PARAMETER DepotDistant
    Dossier du dépôt sur atlas, relatif au dossier personnel. Par défaut : books.
.PARAMETER DossierTravail
    Dossier où l'archive est préparée, puis supprimée. Par défaut : le dossier temporaire de Windows (TEMP).
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
if (-not $Reglages) { $Reglages = Join-Path $dossierDuScript 'envoyer-ads.local.psd1' }
if (-not $DossierTravail) { $DossierTravail = [IO.Path]::GetTempPath() }
# Le bilan venu d'atlas est en UTF-8
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

# Nom d'un rapport envoyable : même règle que scripts/recevoir-ads.sh
$NomRapport = '^[A-Za-z0-9_.-]+\.csv$'
$TailleMax = 20MB
# Outils fournis avec Windows, appelés par leur chemin complet (et non ceux d'autres logiciels installés)
$Ssh = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$Tar = Join-Path $env:WINDIR 'System32\tar.exe'
$Utf8SansBom = New-Object System.Text.UTF8Encoding $false

function Write-Section([string]$texte) { Write-Host ''; Write-Host "== $texte" }

# --- 1. Réglage local et outils ------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Reglages -PathType Leaf)) {
    Write-Host "Réglage local introuvable : $Reglages"
    Write-Host "Copiez envoyer-ads.exemple.psd1 en envoyer-ads.local.psd1, puis indiquez votre dossier."
    exit 2
}
$reglage = Import-PowerShellDataFile -LiteralPath $Reglages
# Clés acceptées ; une clé inconnue (faute de frappe) arrête le script au lieu d'être ignorée
$clesInconnues = @($reglage.Keys | Where-Object { $_ -cnotin 'DossierRapports', 'ConfigSsh' })
if ($clesInconnues.Count -gt 0) {
    Write-Host "Réglage inconnu dans $Reglages : $($clesInconnues -join ', ') (acceptés : DossierRapports, ConfigSsh)."
    exit 2
}
# ConfigSsh (facultatif) : fichier de configuration SSH particulier ; le paramètre -ConfigSsh l'emporte
if (-not $ConfigSsh -and $reglage.ContainsKey('ConfigSsh')) { $ConfigSsh = $reglage['ConfigSsh'] }
$dossier = $reglage['DossierRapports']
if (-not $dossier -or -not (Test-Path -LiteralPath $dossier -PathType Container)) {
    Write-Host "Dossier des rapports introuvable : '$dossier' (réglage DossierRapports de $Reglages)."
    exit 2
}
foreach ($outil in $Ssh, $Tar) {
    if (-not (Test-Path -LiteralPath $outil -PathType Leaf)) { Write-Host "Outil introuvable : $outil"; exit 2 }
}
if ($ConfigSsh -and -not (Test-Path -LiteralPath $ConfigSsh -PathType Leaf)) {
    Write-Host "Configuration SSH introuvable : $ConfigSsh"; exit 2
}

# --- 2. Inventaire : rapports au nom et à la taille acceptables ----------------------------
Write-Section "Rapports dans $dossier"
$rapports = New-Object System.Collections.Generic.List[object]
$signales = New-Object System.Collections.Generic.List[string]
foreach ($f in @(Get-ChildItem -LiteralPath $dossier -File | Sort-Object Name)) {
    if ($f.Name -cnotmatch $NomRapport) {
        $signales.Add("$($f.Name) : nom hors format (.csv, lettres, chiffres, « _ », « . », « - »), laissé sur place")
    } elseif ($f.Length -gt $TailleMax) {
        $signales.Add("$($f.Name) : plus de 20 Mo, laissé sur place")
    } else {
        $rapports.Add($f)
    }
}
foreach ($s in $signales) { Write-Host "  signalé : $s" }
if ($rapports.Count -eq 0) {
    Write-Host 'Aucun rapport à envoyer. Aucune connexion ouverte.'
    exit 0
}
Write-Host "  $($rapports.Count) rapport(s) à envoyer."

# --- 3. Destination dans envoyes\AAAA-MM\ (mois d'envoi) : aucun écrasement possible ------
$maintenant = (Get-Date).ToUniversalTime()
$mois = Join-Path $dossier ('envoyes\' + $maintenant.ToString('yyyy-MM', [Globalization.CultureInfo]::InvariantCulture))
$occupes = @($rapports | Where-Object { Test-Path -LiteralPath (Join-Path $mois $_.Name) } | ForEach-Object Name)
if ($occupes.Count -gt 0) {
    Write-Host "Déjà présent dans envoyes\ : $($occupes -join ', ')"
    Write-Host 'Rien n''a été envoyé : examinez ces fichiers avant de relancer.'
    exit 2
}

# --- 4. Préparation du lot ------------------------------------------------------------------
$lot = $maintenant.ToString("yyyy-MM-dd'T'HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture)
$travail = Join-Path $DossierTravail "books-envoi-ads-$lot"
$preparation = Join-Path $travail 'lot'
$archive = Join-Path $travail 'lot.tar'
$listeNoms = Join-Path $travail 'noms.txt'
$sortie = Join-Path $travail 'sortie.txt'
$lanceur = Join-Path $travail 'envoi.cmd'
$code = 3
$transfertReussi = $false

New-Item -ItemType Directory -Path $preparation | Out-Null
try {
    $manifeste = New-Object System.Collections.Generic.List[string]
    $noms = New-Object System.Collections.Generic.List[string]
    $noms.Add('MANIFEST.sha256')
    foreach ($f in $rapports) {
        # Empreinte calculée sur l'original, en binaire : une copie altérée serait détectée par atlas
        $empreinte = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifeste.Add("$empreinte  $($f.Name)")
        $noms.Add($f.Name)
        Copy-Item -LiteralPath $f.FullName -Destination $preparation
    }
    [IO.File]::WriteAllText((Join-Path $preparation 'MANIFEST.sha256'), (($manifeste -join "`n") + "`n"), $Utf8SansBom)
    [IO.File]::WriteAllText($listeNoms, (($noms -join "`n") + "`n"), $Utf8SansBom)

    Push-Location -LiteralPath $preparation
    try { & $Tar --format ustar -c -f $archive -T $listeNoms } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw "tar a échoué (code $LASTEXITCODE)" }

    # --- 5. Une seule connexion : réception, contrôle, inbox/, ingestion ---------------------
    # Redirections de cmd.exe : octets transmis tels quels. Seule la sortie normale est enregistrée ;
    # la sortie d'erreur reste à l'écran (questions de ssh : mot de passe, empreinte du serveur).
    $optionConfig = if ($ConfigSsh) { "-F `"$ConfigSsh`" " } else { '' }
    $ligne = "`"$Ssh`" $optionConfig$HoteSsh bash $DepotDistant/scripts/recevoir-ads.sh $lot < `"$archive`" > `"$sortie`""
    [IO.File]::WriteAllText($lanceur, "@echo off`r`n$ligne`r`nexit /b %ERRORLEVEL%`r`n", [Text.Encoding]::Default)

    Write-Section "Envoi du lot $lot vers $HoteSsh ($($rapports.Count) rapport(s))"
    Write-Host 'Saisissez le mot de passe d''atlas si ssh le demande.'
    & cmd.exe /d /c "`"$lanceur`""
    $codeSsh = $LASTEXITCODE
    $texte = if (Test-Path -LiteralPath $sortie) { [IO.File]::ReadAllText($sortie, $Utf8SansBom) } else { '' }

    Write-Section 'Réponse d''atlas'
    Write-Host $texte.TrimEnd()

    $transfert = [regex]::Match($texte, "(?m)^BOOKS:TRANSFERT:OK $lot ([0-9]+)\r?$")
    if (-not $transfert.Success -or [int]$transfert.Groups[1].Value -ne $rapports.Count) {
        Write-Section 'Transfert échoué'
        Write-Host "Code de ssh : $codeSsh. Rien n'a été déplacé sur le PC : relancez l'envoi."
        Write-Host "Si atlas a reçu le lot, il est resté dans ~/books-data/ads/attente/$lot pour examen."
        $code = 3
    } else {
        # --- 6. Transfert réussi : les rapports rejoignent envoyes\AAAA-MM\ -----------------------
        $transfertReussi = $true
        New-Item -ItemType Directory -Force -Path $mois | Out-Null
        foreach ($f in $rapports) {
            Move-Item -LiteralPath $f.FullName -Destination (Join-Path $mois $f.Name)
        }
        $ingestion = [regex]::Match($texte, '(?m)^BOOKS:INGESTION:CODE ([0-9]+)\r?$')
        $codeIngestion = if ($ingestion.Success) { [int]$ingestion.Groups[1].Value } else { -1 }

        Write-Section 'Résultat'
        Write-Host "Transfert réussi : $($rapports.Count) rapport(s) déposé(s) sur atlas et rangé(s) dans envoyes\."
        if ($codeIngestion -eq 0) {
            Write-Host 'Ingestion sans anomalie.'
        } elseif ($codeIngestion -eq 1) {
            Write-Host 'Ingestion avec anomalies, déjà en cours ou interrompue : voir le bilan ci-dessus.'
        } elseif ($codeIngestion -lt 0) {
            # Aucune information n'est jamais lue comme un succès
            Write-Host 'Ingestion non signalée par atlas : atlas est-il à jour (git pull, image reconstruite) ?'
        } else {
            Write-Host "Ingestion non effectuée (code $codeIngestion) : les rapports attendent dans inbox/ sur atlas,"
            Write-Host 'et seront ingérés à la prochaine ingestion.'
        }
        $code = if ($codeIngestion -eq 0) { 0 } else { 1 }
    }
}
catch {
    Write-Host "Erreur : $($_.Exception.Message)"
    if ($transfertReussi) {
        # Les rapports sont déjà sur atlas : ceux restés sur le PC repartiront et seront « déjà ingérés »
        Write-Host 'Transfert réussi, mais rangement dans envoyes\ incomplet : vérifiez le dossier des rapports.'
        $code = 1
    } else {
        Write-Host 'Transfert non effectué : rien n''a été déplacé sur le PC.'
        $code = 3
    }
}
finally {
    # Un échec du nettoyage est signalé, jamais masqué
    try { Remove-Item -LiteralPath $travail -Recurse -Force }
    catch { Write-Host "Dossier de travail non supprimé : $travail ($($_.Exception.Message))" }
}
exit $code
